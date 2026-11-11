import Foundation
import Network

/// Flux d'octets bidirectionnel du client RFB (TCP par Network.framework en production, tube mémoire en test).
public protocol RFBTransport: Sendable {
    /// Au moins un octet ; lève `RFBError.connectionClosed` à la fin du flux.
    func receive() async throws -> [UInt8]
    func send(_ bytes: [UInt8]) async throws
    func close()
}

/// Connexion TCP (Network.framework). Aucune écoute : client seulement.
public final class RFBNetworkTransport: RFBTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "escale.vnc.transport")

    private init(host: String, port: UInt16) {
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true; tcp.enableKeepalive = true
        }
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 5900, using: params)
    }

    /// Ouvre la connexion TCP (échec rapide : refus, hôte inconnu, délai).
    public static func connect(host: String, port: Int, timeout: TimeInterval = 15) async throws -> RFBNetworkTransport {
        guard (1...65535).contains(port), !host.isEmpty else { throw RFBError.transport("Hôte ou port invalide.") }
        let t = RFBNetworkTransport(host: host, port: UInt16(port))
        try await t.start(timeout: timeout)
        return t
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func run(_ f: () -> Void) { lock.lock(); let first = !done; done = true; lock.unlock(); if first { f() } }
    }

    private func start(timeout: TimeInterval) async throws {
        let once = Once()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .ready: once.run { cont.resume() }
                case .failed(let e), .waiting(let e):
                    once.run { connection.cancel(); cont.resume(throwing: RFBError.transport(Self.describe(e))) }
                case .cancelled: once.run { cont.resume(throwing: RFBError.connectionClosed) }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [connection] in
                once.run { connection.cancel(); cont.resume(throwing: RFBError.timeout) }
            }
        }
    }

    static func describe(_ e: NWError) -> String {
        if case .posix(let code) = e {
            switch code {
            case .ECONNREFUSED: return "Connexion refusée : aucun serveur VNC n'écoute sur ce port."
            case .ETIMEDOUT: return "Le serveur ne répond pas (délai dépassé)."
            case .EHOSTUNREACH, .ENETUNREACH: return "Hôte injoignable."
            default: break
            }
        }
        if case .dns = e { return "Nom d'hôte introuvable." }
        return "Erreur réseau : \(e)"
    }

    public func receive() async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[UInt8], Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, complete, error in
                if let data, !data.isEmpty { cont.resume(returning: [UInt8](data)) }
                else if let error { cont.resume(throwing: RFBError.transport(Self.describe(error))) }
                else if complete { cont.resume(throwing: RFBError.connectionClosed) }
                else { cont.resume(returning: []) }
            }
        }
    }

    public func send(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error { cont.resume(throwing: RFBError.transport(Self.describe(error))) } else { cont.resume() }
            })
        }
    }

    public func close() { connection.cancel() }
}
