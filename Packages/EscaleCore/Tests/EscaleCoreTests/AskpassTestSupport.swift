import Foundation
@testable import EscaleCore

/// Responder de test : enregistre les requêtes, répond selon un script, compte les notifications du transport.
actor ScriptedResponder: AskpassResponder {
    typealias Script = @Sendable (AskpassRequest) -> AskpassDecision
    private(set) var requests: [AskpassRequest] = []
    private(set) var succeeded = 0
    private(set) var failed = 0
    private let script: Script
    private let delay: Duration?

    init(delay: Duration? = nil, _ script: @escaping Script) { self.script = script; self.delay = delay }

    func respond(to request: AskpassRequest) async -> AskpassDecision {
        requests.append(request)
        if let delay { try? await Task.sleep(for: delay) }
        return script(request)
    }
    func authenticationSucceeded() async { succeeded += 1 }
    func authenticationFailed() async { failed += 1 }
}

/// Chemin de l'exécutable `escale-askpass` construit à côté du bundle de tests.
func askpassExecutablePath() -> String {
    var dirs: [String] = []
    if let o = ProcessInfo.processInfo.environment["ESCALE_ASKPASS_EXECUTABLE"] { return o }
    // Le .xctest (ou son binaire Mach-O) est chargé par dyld : le produit escale-askpass est à côté.
    for i in 0..<_dyld_image_count() {
        guard let c = _dyld_get_image_name(i) else { continue }
        let path = String(cString: c)
        if let r = path.range(of: ".xctest") {
            dirs.append((String(path[..<r.upperBound]) as NSString).deletingLastPathComponent)
        }
    }
    dirs += Bundle.allBundles.filter { $0.bundlePath.hasSuffix(".xctest") }.map { ($0.bundlePath as NSString).deletingLastPathComponent }
    dirs.append((CommandLine.arguments[0] as NSString).deletingLastPathComponent)
    let candidates = dirs.map { ($0 as NSString).appendingPathComponent("escale-askpass") }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates.first ?? "escale-askpass"
}

/// `AskpassClient.request` bloque : on le lance hors du pool coopératif.
func askpassRequest(socket: String, token: String, prompt: String, timeout: TimeInterval = 10) async -> Data? {
    await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
        DispatchQueue.global().async { c.resume(returning: AskpassClient.request(socketPath: socket, token: token, prompt: prompt, timeout: timeout)) }
    }
}

/// Client brut : envoie des octets arbitraires, lit jusqu'à EOF (ou délai). nil si connexion impossible.
func rawAskpassExchange(socket: String, send bytes: [UInt8], hold: TimeInterval = 0, readFor: TimeInterval = 3) async -> [UInt8]? {
    await withCheckedContinuation { (c: CheckedContinuation<[UInt8]?, Never>) in
        DispatchQueue.global().async {
            guard var addr = UnixSocket.makeAddress(socket) else { return c.resume(returning: nil) }
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(fd) }
            let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard rc == 0 else { return c.resume(returning: nil) }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            if !bytes.isEmpty { _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, bytes.count, 0) } }
            if hold > 0 { Thread.sleep(forTimeInterval: hold) }
            var out: [UInt8] = []
            var buf = [UInt8](repeating: 0, count: 256)
            let end = Date().addingTimeInterval(readFor)
            while Date() < end {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if poll(&p, 1, 50) <= 0 { continue }
                let n = recv(fd, &buf, buf.count, 0)
                if n <= 0 { break }
                out += buf[0..<n]
            }
            c.resume(returning: out)
        }
    }
}

func askpassEventually(_ seconds: Double = 3, _ cond: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if await cond() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
    return await cond()
}

/// Processus encore vivants dont la ligne de commande contient `pattern`.
func askpassPgrep(_ pattern: String) -> [String] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-fl", pattern]
    let o = Pipe(); p.standardOutput = o; p.standardError = FileHandle.nullDevice
    try? p.run()
    let data = o.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
}
