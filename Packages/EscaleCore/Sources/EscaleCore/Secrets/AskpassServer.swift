import Foundation

/// Raisons de rejet d'une connexion au socket askpass (avant toute invite).
public enum AskpassRejection: Sendable, Equatable {
    case badPeer, badToken, malformed, tooLarge, timeout
}

/// Évènements observables d'une session askpass (aucun secret, jamais).
public enum AskpassEvent: Sendable, Equatable {
    /// Un secret a été envoyé à ssh pour cette invite.
    case answered(AskpassPromptKind)
    case hostKeyAccepted
    /// L'utilisateur (ou le responder) a refusé / annulé.
    case cancelled(AskpassPromptKind)
    case hostKeyChanged
    case timedOut(AskpassPromptKind)
    case rejected(AskpassRejection)
}

/// Verdict déduit des évènements, utilisé par le transport pour typer l'échec d'authentification.
public struct AskpassOutcome: Sendable, Equatable {
    public var hostKeyChanged = false
    public var timedOut = false
    public var cancelled = false
    public var hostKeyRejected = false
    /// Au moins un secret (mot de passe, phrase, code) a été fourni à ssh.
    public var secretProvided = false
}

/// Serveur d'invites ssh : un socket Unix par connexion maître, protégé par jeton et par uid du pair.
public actor AskpassServer {
    public struct Limits: Sendable, Equatable {
        /// Taille maximale d'une requête (octets, longueur du cadre).
        public var maxFrameBytes = 4096
        /// Délai pour recevoir une requête complète après l'accept.
        public var readTimeout: TimeInterval = 2
        /// Délai maximal de résolution d'une invite par le responder (saisie utilisateur comprise).
        public var responseTimeout: TimeInterval = 120
        /// uid attendu du pair ; nil = uid effectif du processus.
        public var expectedPeerUID: uid_t?

        public init(maxFrameBytes: Int = 4096, readTimeout: TimeInterval = 2, responseTimeout: TimeInterval = 120, expectedPeerUID: uid_t? = nil) {
            self.maxFrameBytes = maxFrameBytes; self.readTimeout = readTimeout
            self.responseTimeout = responseTimeout; self.expectedPeerUID = expectedPeerUID
        }
    }

    public struct Endpoint: Sendable, Equatable {
        public let socketPath: String
        public let token: String
    }

    public enum StartError: Error, Equatable, Sendable { case alreadyRunning, failed(String) }

    private let responder: any AskpassResponder
    private let limits: Limits
    private let socketDirectory: String?
    private let book = AskpassBook()
    private var listener: AskpassListener?
    private var endpoint: Endpoint?

    public init(responder: any AskpassResponder, limits: Limits = Limits(), socketDirectory: String? = nil) {
        self.responder = responder; self.limits = limits; self.socketDirectory = socketDirectory
    }

    /// Crée le dossier 0700, le socket 0600 (chemin < 100 octets) et un jeton neuf, puis écoute.
    public func start() throws -> Endpoint {
        guard listener == nil else { throw StartError.alreadyRunning }
        let token = AskpassWire.makeToken()
        let responder = self.responder, book = self.book, limits = self.limits
        let l: AskpassListener
        do {
            l = try AskpassListener(token: token, limits: limits, baseDirectory: socketDirectory, book: book) { prompt in
                await AskpassServer.resolve(prompt: prompt, responder: responder, book: book)
            }
        } catch let e as UnixSocket.Failure { throw StartError.failed(e.message) }
        listener = l
        let ep = Endpoint(socketPath: l.socketPath, token: token)
        endpoint = ep
        return ep
    }

    /// Arrêt propre : plus d'accept, invites en attente refusées, socket et dossier supprimés. Idempotent.
    public func stop() {
        listener?.stop()
        listener = nil
        endpoint = nil
    }

    public var isRunning: Bool { listener != nil }
    public var socketPath: String? { endpoint?.socketPath }
    public var events: [AskpassEvent] { book.events }
    public var pendingPromptCount: Int { book.pending }
    public var outcome: AskpassOutcome { book.outcome }

    /// Variables d'environnement à donner au processus ssh maître.
    public func environment(askpassExecutable: String) throws -> [String: String] {
        guard let ep = endpoint else { throw StartError.failed("serveur non démarré") }
        return [
            "SSH_ASKPASS": askpassExecutable,
            "SSH_ASKPASS_REQUIRE": "force",
            AskpassClient.socketVariable: ep.socketPath,
            AskpassClient.tokenVariable: ep.token,
        ]
    }

    // MARK: - Résolution d'une invite

    static func resolve(prompt: String, responder: any AskpassResponder, book: AskpassBook) async -> AskpassWireReply {
        let kind = AskpassPromptClassifier.classify(prompt)
        if kind == .hostKeyChanged {
            book.record(.hostKeyChanged)
            return .refused
        }
        let request = AskpassRequest(kind: kind, text: prompt, attempt: book.nextAttempt(for: prompt))
        book.beginPending()
        defer { book.endPending() }
        let decision = await responder.respond(to: request)
        if Task.isCancelled { return .refused }   // délai dépassé ou arrêt : réponse tardive ignorée
        switch decision {
        case .secret(let s, _):
            if case .hostKeyConfirmation = kind { book.record(.cancelled(kind)); return .refused }
            book.record(.answered(kind))
            return .answer(s.data)
        case .accept:
            guard case .hostKeyConfirmation = kind else { book.record(.cancelled(kind)); return .refused }
            book.record(.hostKeyAccepted)
            return .answer(Data("yes".utf8))
        case .cancel:
            book.record(.cancelled(kind))
            return .refused
        }
    }
}

enum AskpassWireReply: Sendable, Equatable {
    case answer(Data)
    case refused
}

/// Journal partagé (verrou) entre les threads de connexion et l'acteur.
final class AskpassBook: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [AskpassEvent] = []
    private var _pending = 0
    private var seen: [String: Int] = [:]

    var events: [AskpassEvent] { lock.withLock { _events } }
    var pending: Int { lock.withLock { _pending } }

    func record(_ e: AskpassEvent) { lock.withLock { _events.append(e) } }
    func beginPending() { lock.withLock { _pending += 1 } }
    func endPending() { lock.withLock { _pending -= 1 } }

    func nextAttempt(for prompt: String) -> Int {
        let key = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return lock.withLock { seen[key, default: 0] += 1; return seen[key]! }
    }

    var outcome: AskpassOutcome {
        var o = AskpassOutcome()
        for e in events {
            switch e {
            case .hostKeyChanged: o.hostKeyChanged = true
            case .timedOut: o.timedOut = true
            case .cancelled(let k):
                if case .hostKeyConfirmation = k { o.hostKeyRejected = true } else { o.cancelled = true }
            case .answered: o.secretProvided = true
            case .hostKeyAccepted, .rejected: break
            }
        }
        return o
    }
}

/// Socket d'écoute et threads de connexion. Tout le POSIX bloquant vit ici, hors du pool coopératif.
final class AskpassListener: @unchecked Sendable {
    let socketPath: String
    private let directory: String
    private let token: [UInt8]
    private let limits: AskpassServer.Limits
    private let book: AskpassBook
    private let handler: @Sendable (String) async -> AskpassWireReply
    private let listenFD: Int32
    private let lock = NSLock()
    private var stopped = false
    private var active = 0
    private let acceptDone = DispatchSemaphore(value: 0)

    init(
        token: String, limits: AskpassServer.Limits, baseDirectory: String?, book: AskpassBook,
        handler: @escaping @Sendable (String) async -> AskpassWireReply
    ) throws {
        self.token = Array(token.utf8); self.limits = limits; self.book = book; self.handler = handler
        let fm = FileManager.default
        var base = baseDirectory ?? NSTemporaryDirectory()
        while base.count > 1 && base.hasSuffix("/") { base.removeLast() }
        let suffix = UUID().uuidString.prefix(8).lowercased()
        var dir = "\(base)/escale-ap-\(suffix)"
        if "\(dir)/s".utf8.count >= 100 { dir = "/tmp/escale-ap-\(suffix)" }
        do { try fm.createDirectory(atPath: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { throw UnixSocket.Failure(message: "création du dossier askpass impossible : \(error)") }
        chmod(dir, 0o700)   // indépendant de l'umask
        directory = dir
        socketPath = "\(dir)/s"

        func fail(_ m: String) -> UnixSocket.Failure { try? fm.removeItem(atPath: dir); return UnixSocket.Failure(message: m) }
        guard var addr = UnixSocket.makeAddress(socketPath), socketPath.utf8.count < 100 else { throw fail("chemin de socket trop long") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw fail("socket errno \(errno)") }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { let e = errno; close(fd); throw fail("bind errno \(e)") }
        chmod(socketPath, 0o600)
        guard listen(fd, 16) == 0 else { let e = errno; close(fd); throw fail("listen errno \(e)") }
        listenFD = fd

        let t = Thread { [self] in acceptLoop() }
        t.name = "escale-askpass-accept"
        t.start()
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    func stop() {
        let already = lock.withLock { let s = stopped; stopped = true; return s }
        if already { return }
        acceptDone.wait()
        close(listenFD)
        // Laisse les threads de connexion se terminer (ils voient `stopped` dans leurs boucles d'attente).
        let end = Date().addingTimeInterval(2)
        while lock.withLock({ active }) > 0 && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        unlink(socketPath)
        try? FileManager.default.removeItem(atPath: directory)
    }

    private func acceptLoop() {
        while !isStopped {
            var p = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            let r = poll(&p, 1, 100)
            if r <= 0 { continue }
            let c = accept(listenFD, nil, nil)
            if c < 0 { continue }
            lock.withLock { active += 1 }
            let t = Thread { [self] in
                handle(c)
                close(c)
                lock.withLock { active -= 1 }
            }
            t.name = "escale-askpass-conn"
            t.start()
        }
        acceptDone.signal()
    }

    private func reject(_ r: AskpassRejection) { book.record(.rejected(r)) }

    private func handle(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == (limits.expectedPeerUID ?? geteuid()) else { return reject(.badPeer) }

        var timedOut = false
        let deadline = Date().addingTimeInterval(limits.readTimeout)
        guard let head = UnixSocket.readExactly(fd, count: 4, deadline: deadline, timedOut: &timedOut, cancelled: { self.isStopped }) else {
            return reject(timedOut ? .timeout : .malformed)
        }
        let len = head.reduce(0) { ($0 << 8) | Int($1) }
        guard len > 0, len <= limits.maxFrameBytes else { return reject(.tooLarge) }
        guard let payload = UnixSocket.readExactly(fd, count: len, deadline: deadline, timedOut: &timedOut, cancelled: { self.isStopped }) else {
            return reject(timedOut ? .timeout : .malformed)
        }
        // `ESCALE-ASKPASS/1\n<jeton>\n<invite>`
        let parts = payload.split(separator: 0x0a, maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, String(decoding: parts[0], as: UTF8.self) == AskpassWire.header else { return reject(.malformed) }
        guard AskpassWire.constantTimeEqual(Array(parts[1]), token) else { return reject(.badToken) }
        guard let prompt = String(data: Data(parts[2]), encoding: .utf8) else { return reject(.malformed) }

        let reply = bridge(prompt)
        let data: Data
        switch reply {
        case .answer(let d): data = AskpassWire.encodeReply(d)
        case .refused: data = AskpassWire.encodeReply(nil)
        }
        _ = UnixSocket.writeAll(fd, data, deadline: Date().addingTimeInterval(5))
    }

    /// Exécute le résolveur asynchrone depuis ce thread dédié ; applique le délai de réponse.
    private func bridge(_ prompt: String) -> AskpassWireReply {
        let box = ReplyBox()
        let h = handler
        let task = Task { let r = await h(prompt); box.set(r) }
        let deadline = Date().addingTimeInterval(limits.responseTimeout)
        while true {
            if let r = box.get() { return r }
            if isStopped { task.cancel(); return .refused }
            if Date() >= deadline {
                task.cancel()
                book.record(.timedOut(AskpassPromptClassifier.classify(prompt)))
                return .refused
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}

private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AskpassWireReply?
    func set(_ r: AskpassWireReply) { lock.withLock { value = r } }
    func get() -> AskpassWireReply? { lock.withLock { value } }
}
