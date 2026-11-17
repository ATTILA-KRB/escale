import Foundation

/// Emplacement du socket MCP : `~/Library/Application Support/Escale/agent/mcp.sock` (dossier 0700, socket 0600).
/// `ESCALE_MCP_SOCKET` le remplace (recettes) ; le relais et l'app lisent la même variable.
public enum MCPEndpoint {
    public static let environmentVariable = "ESCALE_MCP_SOCKET"

    public static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let p = environment[environmentVariable], !p.isEmpty { return p }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Escale/agent/mcp.sock").path
    }
}

/// Serveur MCP sur un socket Unix local : aucune écoute TCP, pair limité à l'uid de l'utilisateur, une `MCPSession`
/// par connexion. Tout le POSIX bloquant vit sur des threads dédiés (comme `AskpassListener`).
public final class MCPSocketServer: @unchecked Sendable {
    public struct Limits: Sendable {
        public var maxLineBytes = 16 * 1024 * 1024
        public var maxConnections = 8
        public var maxInFlightPerConnection = 16
        public init() {}
    }

    public enum StartError: Error, Equatable, Sendable, CustomStringConvertible {
        case pathTooLong, inUse, unsafeDirectory(String), failed(String)
        public var description: String {
            switch self {
            case .pathTooLong: "chemin du socket MCP trop long"
            case .inUse: "socket MCP déjà utilisé par une autre instance d'Escale"
            case .unsafeDirectory(let m): "dossier du socket MCP refusé : \(m)"
            case .failed(let m): m
            }
        }
    }

    /// Évènements de connexion (journal de l'app). Jamais de contenu de message.
    public enum Event: Sendable, Equatable {
        case connected(UUID)
        case disconnected(UUID)
        case rejectedPeer
    }

    public let socketPath: String
    private let limits: Limits
    private let makeSession: @Sendable (UUID) -> MCPSession
    private let onEvent: @Sendable (Event) -> Void
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var stopped = false
    private var connections: [UUID: Connection] = [:]
    private let acceptDone = DispatchSemaphore(value: 0)

    public init(socketPath: String, limits: Limits = Limits(),
                onEvent: @escaping @Sendable (Event) -> Void = { _ in },
                makeSession: @escaping @Sendable (UUID) -> MCPSession) {
        self.socketPath = socketPath; self.limits = limits; self.onEvent = onEvent; self.makeSession = makeSession
    }

    public var connectionCount: Int { lock.withLock { connections.count } }

    /// Crée le dossier (0700, à nous, pas un lien), remplace un socket mort, écoute.
    public func start() throws {
        guard socketPath.utf8.count < 100, var addr = UnixSocket.makeAddress(socketPath) else { throw StartError.pathTooLong }
        let dir = (socketPath as NSString).deletingLastPathComponent
        try Self.preparePrivateDirectory(dir)
        var st = stat()
        if lstat(socketPath, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFSOCK else { throw StartError.unsafeDirectory("\(socketPath) n'est pas un socket") }
            if Self.canConnect(socketPath) { throw StartError.inUse }
            unlink(socketPath)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.failed("socket errno \(errno)") }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { let e = errno; close(fd); throw StartError.failed("bind errno \(e)") }
        chmod(socketPath, 0o600)
        guard listen(fd, 16) == 0 else { let e = errno; close(fd); unlink(socketPath); throw StartError.failed("listen errno \(e)") }
        lock.withLock { listenFD = fd; stopped = false }
        let t = Thread { [self] in acceptLoop() }
        t.name = "escale-mcp-accept"
        t.start()
    }

    /// Arrêt : plus d'accept, connexions fermées (appels en cours annulés), socket supprimé. Idempotent.
    public func stop() {
        let (already, fd, conns) = lock.withLock { () -> (Bool, Int32, [Connection]) in
            let s = stopped || listenFD < 0; stopped = true
            return (s, listenFD, Array(connections.values))
        }
        if already { return }
        acceptDone.wait()
        close(fd)
        for c in conns { c.close() }
        let end = Date().addingTimeInterval(2)
        while connectionCount > 0 && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        unlink(socketPath)
        lock.withLock { listenFD = -1 }
    }

    static func preparePrivateDirectory(_ dir: String) throws {
        let fm = FileManager.default
        var st = stat()
        if lstat(dir, &st) != 0 {
            do { try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { throw StartError.failed("création de \(dir) impossible : \(error.localizedDescription)") }
            chmod(dir, 0o700)
            guard lstat(dir, &st) == 0 else { throw StartError.failed("\(dir) introuvable") }
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw StartError.unsafeDirectory("\(dir) n'est pas un dossier") }
        guard st.st_uid == geteuid() else { throw StartError.unsafeDirectory("\(dir) n'appartient pas à l'utilisateur") }
        if st.st_mode & 0o077 != 0 { chmod(dir, 0o700) }
    }

    static func canConnect(_ path: String) -> Bool {
        let fd = MCPRelay.connect(path)
        if fd >= 0 { close(fd); return true }
        return false
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func acceptLoop() {
        let fd = lock.withLock { listenFD }
        while !isStopped {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&p, 1, 100) <= 0 { continue }
            let c = accept(fd, nil, nil)
            if c < 0 { continue }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(c, &uid, &gid) == 0, uid == geteuid() else { close(c); onEvent(.rejectedPeer); continue }
            let full = lock.withLock { connections.count >= limits.maxConnections }
            if full { close(c); continue }
            let id = UUID()
            let conn = Connection(fd: c, id: id, session: makeSession(id), limits: limits)
            lock.withLock { connections[id] = conn }
            onEvent(.connected(id))
            let t = Thread { [self] in
                conn.run()
                lock.withLock { connections[id] = nil }
                onEvent(.disconnected(id))
            }
            t.name = "escale-mcp-conn"
            t.start()
        }
        acceptDone.signal()
    }

    /// Une connexion : lecture par lignes sur ce thread, une tâche par requête, écritures sérialisées.
    final class Connection: @unchecked Sendable {
        let fd: Int32
        let id: UUID
        let session: MCPSession
        let limits: Limits
        private let lock = NSLock()
        private let writeLock = NSLock()
        private var closed = false
        private var tasks: [UUID: Task<Void, Never>] = [:]

        init(fd: Int32, id: UUID, session: MCPSession, limits: Limits) {
            self.fd = fd; self.id = id; self.session = session; self.limits = limits
        }

        var isClosed: Bool { lock.withLock { closed } }

        func close() {
            lock.withLock { closed = true }
            shutdown(fd, SHUT_RDWR)
        }

        func send(_ line: Data) {
            guard !isClosed else { return }
            var d = line; d.append(0x0a)
            writeLock.withLock { _ = UnixSocket.writeAll(fd, d, deadline: Date().addingTimeInterval(30)) }
        }

        func run() {
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 65_536)
            loop: while !isClosed {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let r = poll(&p, 1, 100)
                if r < 0 { if errno == EINTR { continue }; break }
                if r == 0 { continue }
                let n = recv(fd, &chunk, chunk.count, 0)
                if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; break }
                if n == 0 { break }
                buffer.append(contentsOf: chunk[0..<n])
                while let nl = buffer.firstIndex(of: 0x0a) {
                    var line = buffer[buffer.startIndex..<nl]
                    buffer = Data(buffer[(nl + 1)...])
                    if line.last == 0x0d { line = line.dropLast() }
                    if line.isEmpty { continue }
                    dispatch(Data(line))
                }
                if buffer.count > limits.maxLineBytes {
                    send(MCPSession.error(id: .null, code: MCPSession.RPCError.invalidRequest, message: "message too large"))
                    break loop
                }
            }
            let pending = lock.withLock { closed = true; return Array(tasks.values) }
            for t in pending { t.cancel() }
            // Laisse les tâches annulées se terminer (une confirmation retirée rend aussitôt) avant de fermer le fd.
            let end = Date().addingTimeInterval(2)
            while lock.withLock({ !tasks.isEmpty }) && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
            Darwin.close(fd)
        }

        private func dispatch(_ line: Data) {
            let key = UUID()
            let session = self.session
            // Insertion sous le verrou : la tâche (jamais synchrone) ne peut se retirer qu'après.
            let accepted = lock.withLock { () -> Bool in
                guard tasks.count < limits.maxInFlightPerConnection else { return false }
                tasks[key] = Task { [weak self] in
                    let reply = await session.handle(line)
                    guard let self else { return }
                    if let reply, !Task.isCancelled { self.send(reply) }
                    self.lock.withLock { self.tasks[key] = nil }
                }
                return true
            }
            if !accepted {
                let id = (try? MCPJSON.decode(line))?["id"] ?? .null
                send(MCPSession.error(id: id, code: -32000, message: "too many concurrent requests"))
            }
        }
    }
}
