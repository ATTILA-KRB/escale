import Foundation
import Network

/// Échec d'ouverture ou de maintien d'une connexion Telnet ; la description (en français) est affichée dans le panneau.
public enum TelnetError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidEndpoint(String)
    case timeout(host: String, seconds: Int)
    case refused(host: String, port: Int)
    case hostNotFound(String)
    case unreachable(host: String)
    case network(String)

    public var description: String {
        switch self {
        case .invalidEndpoint(let m): "Adresse Telnet invalide : \(m)"
        case .timeout(let h, let s): "Délai dépassé (\(s) s) en se connectant à \(h)."
        case .refused(let h, let p): "Connexion refusée par \(h):\(p) (aucun service Telnet à l'écoute ?)."
        case .hostNotFound(let h): "Hôte introuvable : \(h)."
        case .unreachable(let h): "Hôte injoignable : \(h)."
        case .network(let m): "Erreur réseau : \(m)"
        }
    }

    static func from(_ error: NWError, host: String, port: Int) -> TelnetError {
        switch error {
        case .dns: return .hostNotFound(host)
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return .refused(host: host, port: port)
            case .ETIMEDOUT: return .timeout(host: host, seconds: 0)
            case .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN, .ENETDOWN: return .unreachable(host: host)
            default: return .network(error.localizedDescription)
            }
        default: return .network(error.localizedDescription)
        }
    }
}

/// Connexion Telnet (TCP via Network.framework) branchée comme une source d'octets de terminal.
/// Toute la logique du protocole est dans `TelnetSession` ; ici : TCP, délais, fin de session.
public final class TelnetConnection: TerminalByteStream, @unchecked Sendable {
    public let output: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "escale.telnet")

    private let lock = NSLock()
    private var session: TelnetSession
    private var status: PTYExitStatus?
    private var waiters: [CheckedContinuation<PTYExitStatus, Never>] = []

    private init(connection: NWConnection, session: TelnetSession) {
        self.connection = connection; self.session = session
        (output, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
    }

    /// Ouvre la connexion TCP (IPv4 ou IPv6, noms résolus par Network.framework) puis démarre la négociation.
    /// Lève `TelnetError` (délai, refus, hôte introuvable…). Annulable.
    public static func open(host: String, port: Int, settings: TelnetSettings = TelnetSettings(),
                            columns: Int = 80, rows: Int = 24) async throws -> TelnetConnection {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        let name = trimmed.hasPrefix("[") && trimmed.hasSuffix("]") ? String(trimmed.dropFirst().dropLast()) : trimmed
        guard !name.isEmpty else { throw TelnetError.invalidEndpoint("hôte vide") }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), (1...65535).contains(port) else {
            throw TelnetError.invalidEndpoint("port \(port)")
        }
        let timeout = max(1, settings.connectTimeout)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.connectionTimeout = timeout
        let conn = NWConnection(host: NWEndpoint.Host(name), port: nwPort, using: NWParameters(tls: nil, tcp: tcp))
        let telnet = TelnetConnection(
            connection: conn,
            session: TelnetSession(terminalType: settings.terminalType, lineEnding: settings.lineEnding,
                                   columns: columns, rows: rows))

        let gate = OneShot()
        do { try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                gate.install(c)
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready: gate.finish(nil)
                    case .failed(let e):
                        var err = TelnetError.from(e, host: name, port: port)
                        if case .timeout = err { err = .timeout(host: name, seconds: timeout) }
                        gate.finish(err)
                    case .waiting(let e):
                        // Réseau momentanément indisponible : on laisse le délai courir, sauf refus/hôte inconnu immédiats.
                        let err = TelnetError.from(e, host: name, port: port)
                        switch err { case .refused, .hostNotFound: gate.finish(err); default: break }
                    case .cancelled: gate.finish(CancellationError())
                    default: break
                    }
                }
                conn.start(queue: telnet.queue)
                // Filet : le délai TCP système peut être plus long (ou ne pas s'appliquer en `waiting`).
                telnet.queue.asyncAfter(deadline: .now() + .seconds(timeout + 1)) {
                    gate.finish(TelnetError.timeout(host: name, seconds: timeout))
                }
            }
        } onCancel: {
            conn.cancel()
        } } catch {
            conn.stateUpdateHandler = nil
            conn.cancel()
            telnet.continuation.finish()
            throw error
        }
        telnet.begin()
        return telnet
    }

    private func begin() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let e): self.finish(.exited(1), message: "Connexion perdue : \(TelnetError.from(e, host: "", port: 0).description)")
            case .cancelled: self.finish(.exited(0), message: nil)
            default: break
            }
        }
        let hello = lock.withLock { session.start() }
        send(hello)
        receiveLoop()
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let (display, reply) = self.lock.withLock { self.session.receive(data) }
                if !display.isEmpty { self.continuation.yield(display) }
                self.send(reply)
            }
            if let error {
                if case .posix(.ECANCELED) = error { self.finish(.exited(0), message: nil); return }
                var text = TelnetError.from(error, host: "", port: 0).description
                if case .posix(.ECONNRESET) = error { text = "Connexion réinitialisée par l'hôte distant." }
                self.finish(.exited(1), message: "Connexion perdue : \(text)")
                return
            }
            if isComplete { self.finish(.exited(0), message: nil); return }
            self.receiveLoop()
        }
    }

    private func send(_ data: Data) {
        guard !data.isEmpty else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(.exited(1), message: "Connexion perdue : \(TelnetError.from(error, host: "", port: 0).description)") }
        })
    }

    private func finish(_ result: PTYExitStatus, message: String?) {
        let (first, ws): (Bool, [CheckedContinuation<PTYExitStatus, Never>]) = lock.withLock {
            guard status == nil else { return (false, []) }
            status = result
            let w = waiters; waiters = []; return (true, w)
        }
        guard first else { return } // déjà terminée (idempotent)
        if let message { continuation.yield(Data("\r\n\u{1b}[31m\(message)\u{1b}[0m\r\n".utf8)) }
        continuation.finish()
        connection.cancel()
        for w in ws { w.resume(returning: result) }
    }

    // MARK: TerminalByteStream

    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        let encoded = lock.withLock { status == nil ? session.encodeInput(data) : Data() }
        send(encoded)
    }

    public func resize(columns: Int, rows: Int) {
        let naws = lock.withLock { session.resize(columns: columns, rows: rows) }
        send(naws)
    }

    public func kill() { finish(.exited(0), message: nil) }

    public func waitForExit() async -> PTYExitStatus {
        await withCheckedContinuation { (c: CheckedContinuation<PTYExitStatus, Never>) in
            let done: PTYExitStatus? = lock.withLock {
                if let s = status { return s }
                waiters.append(c); return nil
            }
            if let done { c.resume(returning: done) }
        }
    }

    /// État courant de la négociation (tests et diagnostic).
    public var snapshot: (serverEchoes: Bool, isBinary: Bool, columns: Int, rows: Int) {
        lock.withLock { (session.serverEchoes, session.isBinary, session.columns, session.rows) }
    }
}

/// Reprise unique d'une continuation (état prêt, échec, délai et annulation peuvent arriver ensemble).
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var early: Error??

    func install(_ c: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let e = early { lock.unlock(); if let err = e { c.resume(throwing: err) } else { c.resume() }; return }
        continuation = c
        lock.unlock()
    }

    func finish(_ error: Error?) {
        lock.lock()
        guard let c = continuation else { if early == nil { early = .some(error) }; lock.unlock(); return }
        continuation = nil
        early = .some(error)
        lock.unlock()
        if let error { c.resume(throwing: error) } else { c.resume() }
    }
}
