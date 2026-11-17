import Foundation

/// Relais stdio ↔ socket MCP de l'app : `Escale.app/Contents/MacOS/Escale --mcp`, lancé par le client MCP
/// (Claude Code, Hermes, Cursor…). Comme askpass, il s'exécute avant toute initialisation AppKit et quitte
/// (ni fenêtre, ni icône de Dock). Il ne lance jamais l'app : sans Escale ouvert (ou accès des agents coupé),
/// il échoue avec un message sur stderr.
public enum MCPRelay {
    public static let flag = "--mcp"

    /// Point d'entrée : sans `--mcp` en premier argument, ne fait rien.
    public static func runIfRequested(arguments: [String] = CommandLine.arguments) {
        guard arguments.count >= 2, arguments[1] == flag else { return }
        exit(main())
    }

    static func main() -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        let path = MCPEndpoint.socketPath()
        let fd = connect(path)
        guard fd >= 0 else {
            FileHandle.standardError.write(Data("""
                escale --mcp : Escale n'est pas joignable (\(path)). Ouvrez Escale et activez « Accès des agents (MCP) ».
                escale --mcp: Escale is not reachable. Open Escale and enable "Agent access (MCP)".\n
                """.utf8))
            return 1
        }
        defer { close(fd) }
        pump(input: STDIN_FILENO, output: STDOUT_FILENO, socket: fd)
        return 0
    }

    /// Connexion au socket (pair = l'app, même utilisateur : vérifié aussi de ce côté). -1 en cas d'échec.
    static func connect(_ path: String) -> Int32 {
        guard var addr = UnixSocket.makeAddress(path) else { return -1 }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        var uid: uid_t = 0, gid: gid_t = 0
        guard rc == 0, getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { close(fd); return -1 }
        return fd
    }

    /// Copie dans les deux sens jusqu'à la fin du flux du socket. Fin de `input` : demi-fermeture du socket
    /// (l'app annule alors les appels en cours) puis attente de sa fermeture.
    static func pump(input: Int32, output: Int32, socket: Int32) {
        var inputOpen = true
        var buf = [UInt8](repeating: 0, count: 65_536)
        while true {
            var fds = [pollfd(fd: socket, events: Int16(POLLIN), revents: 0)]
            if inputOpen { fds.append(pollfd(fd: input, events: Int16(POLLIN), revents: 0)) }
            let r = poll(&fds, nfds_t(fds.count), -1)
            if r < 0 { if errno == EINTR { continue }; return }
            if fds[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                let n = recv(socket, &buf, buf.count, 0)
                if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; return }
                if n == 0 { return }
                guard writeAll(output, buf, n) else { return }
            }
            if inputOpen, fds.count > 1, fds[1].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                let n = read(input, &buf, buf.count)
                if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; return }
                if n == 0 { inputOpen = false; shutdown(socket, SHUT_WR); continue }
                guard writeAll(socket, buf, n) else { return }
            }
        }
    }

    private static func writeAll(_ fd: Int32, _ buf: [UInt8], _ count: Int) -> Bool {
        var sent = 0
        while sent < count {
            let n = buf.withUnsafeBytes { write(fd, $0.baseAddress! + sent, count - sent) }
            if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; return false }
            sent += n
        }
        return true
    }
}
