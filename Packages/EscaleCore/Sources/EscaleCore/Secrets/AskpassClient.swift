import Foundation

/// Côté client d'askpass : ssh lance l'exécutable désigné par `SSH_ASKPASS` avec l'invite en argv[1] ;
/// ce code la transmet à `AskpassServer` (socket Unix) et écrit la réponse sur stdout.
/// L'exécutable `escale-askpass` et l'app (qui se désigne elle-même comme SSH_ASKPASS) appellent `runIfRequested()` en tout premier.
public enum AskpassClient {
    public static let socketVariable = "ESCALE_ASKPASS_SOCKET"
    public static let tokenVariable = "ESCALE_ASKPASS_TOKEN"

    /// Délai maximal d'attente de la réponse du serveur (l'utilisateur peut devoir saisir un code).
    public static let replyTimeout: TimeInterval = 300

    /// Ne fait rien si `ESCALE_ASKPASS_SOCKET` / `ESCALE_ASKPASS_TOKEN` sont absents.
    /// Sinon traite l'invite (argv[1…]) puis TERMINE le processus : code 0 + secret sur stdout, ou code 1 sans rien écrire.
    public static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env[socketVariable] != nil, env[tokenVariable] != nil else { return }
        let code = run(arguments: Array(CommandLine.arguments.dropFirst()), environment: env) { data in
            FileHandle.standardOutput.write(data)
        }
        exit(code)
    }

    /// Cœur testable. Renvoie le code de sortie ; `output` reçoit le secret suivi de `\n` (seulement en cas de succès).
    public static func run(arguments: [String], environment: [String: String], output: (Data) -> Void) -> Int32 {
        guard let socket = environment[socketVariable], let token = environment[tokenVariable], !socket.isEmpty, !token.isEmpty else {
            return 2
        }
        let prompt = arguments.joined(separator: " ")
        guard let secret = request(socketPath: socket, token: token, prompt: prompt) else { return 1 }
        var out = secret
        out.append(0x0a)
        output(out)
        return 0
    }

    /// Un échange complet. nil = refus, annulation, erreur ou délai (aucun détail : jamais de secret dans un message).
    public static func request(socketPath: String, token: String, prompt: String, timeout: TimeInterval = replyTimeout) -> Data? {
        guard var addr = UnixSocket.makeAddress(socketPath) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { return nil }
        guard UnixSocket.writeAll(fd, AskpassWire.encodeRequest(token: token, prompt: prompt), deadline: Date().addingTimeInterval(5)) else { return nil }
        var timedOut = false
        let deadline = Date().addingTimeInterval(timeout)
        guard let head = UnixSocket.readExactly(fd, count: 5, deadline: deadline, timedOut: &timedOut), head[0] == AskpassWire.statusSecret else { return nil }
        let len = head[1...4].reduce(0) { ($0 << 8) | Int($1) }
        guard len <= AskpassWire.maxReplyBytes else { return nil }
        if len == 0 { return Data() }
        guard let body = UnixSocket.readExactly(fd, count: len, deadline: deadline, timedOut: &timedOut) else { return nil }
        return Data(body)
    }
}
