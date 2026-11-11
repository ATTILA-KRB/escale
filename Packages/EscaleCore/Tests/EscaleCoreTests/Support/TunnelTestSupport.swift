import Foundation

/// Serveur HTTP minimal sur 127.0.0.1 (port libre) : répond `body` à toute requête. Pour vérifier un tunnel par curl.
final class TestHTTPServer: @unchecked Sendable {
    let port: Int
    let body: String
    private let fd: Int32
    private let lock = NSLock()
    private var stopped = false

    init(body: String = "escale-tunnel-ok") throws {
        self.body = body
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { throw LocalSSHD.StartError(description: "socket") }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1"); a.sin_port = 0
        let b = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard b == 0, listen(s, 16) == 0 else { close(s); throw LocalSSHD.StartError(description: "bind/listen") }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        port = Int(UInt16(bigEndian: a.sin_port)); fd = s
        let payload = body
        Thread.detachNewThread { [fd] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { return }
                Thread.detachNewThread {
                    var buf = [UInt8](repeating: 0, count: 4096)
                    _ = read(c, &buf, buf.count)
                    let resp = "HTTP/1.0 200 OK\r\nContent-Length: \(payload.utf8.count)\r\nConnection: close\r\n\r\n\(payload)"
                    _ = resp.withCString { write(c, $0, strlen($0)) }
                    close(c)
                }
            }
        }
    }

    /// Ferme l'écoute (le thread d'acceptation s'arrête sur l'erreur d'`accept`).
    func stop() {
        lock.lock(); defer { lock.unlock() }
        if !stopped { stopped = true; close(fd) }
    }
}

/// Résultat d'un `curl` (code de sortie + corps).
struct CurlResult { var status: Int32; var output: String }

/// `/usr/bin/curl -s --max-time 5 <args>` ; les proxys d'environnement sont neutralisés.
func curl(_ args: [String]) -> CurlResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    p.arguments = ["-s", "--noproxy", "*", "--max-time", "5"] + args
    let o = Pipe(); p.standardOutput = o; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return CurlResult(status: -1, output: "") }
    let d = o.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return CurlResult(status: p.terminationStatus, output: String(decoding: d, as: UTF8.self))
}
