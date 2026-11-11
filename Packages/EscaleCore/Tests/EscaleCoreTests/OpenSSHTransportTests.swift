import Foundation
import Testing
@testable import EscaleCore

// MARK: - Aides

private func transport(_ d: LocalSSHD, profile: HostProfile? = nil, ssh: OpenSSHOptions? = nil, maxSessions: Int = 10) -> OpenSSHTransport {
    OpenSSHTransport(
        profile: profile ?? d.profile(),
        configuration: .init(ssh: ssh ?? d.sshOptions(), masterReadyTimeout: 15, maxSessions: maxSessions, forwardProbeTimeout: 0.5))
}

/// Exécute `body` avec un transport et garantit `disconnect()` même en cas d'échec.
private func withTransport<T>(
    _ d: LocalSSHD, profile: HostProfile? = nil, maxSessions: Int = 10,
    _ body: (OpenSSHTransport) async throws -> T
) async throws -> T {
    let t = transport(d, profile: profile, maxSessions: maxSessions)
    do { let r = try await body(t); await t.disconnect(); return r }
    catch { await t.disconnect(); throw error }
}

private func pgrep(_ pattern: String) -> [String] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-fl", pattern]
    let o = Pipe(); p.standardOutput = o; p.standardError = FileHandle.nullDevice
    try? p.run()
    let data = o.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
}

private func eventually(_ seconds: Double = 2, _ cond: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if await cond() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
    return await cond()
}

private func sftpInit() -> Data { Data([0, 0, 0, 5, 1, 0, 0, 0, 3]) }

/// Lit une réponse SFTP complète (longueur + corps) et renvoie le corps.
private func readPacket(_ c: any ByteChannel) async throws -> Data {
    let h = try await c.read(exactly: 4)
    let len = h.reduce(0) { ($0 << 8) | Int($1) }
    return try await c.read(exactly: len)
}

/// Serveur TCP d'écho minimal (127.0.0.1, port libre).
private final class EchoServer: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var v = false
        var isSet: Bool { lock.withLock { v } }
        func set() -> Bool { lock.withLock { let was = v; v = true; return was } }
    }
    private let stopFlag = Flag()

    init() throws {
        let sfd = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(sfd, SOL_SOCKET, SO_REUSEADDR, &one, 4)
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1"); a.sin_port = 0
        let b = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sfd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard b == 0, listen(sfd, 16) == 0 else { close(sfd); throw LocalSSHD.StartError(description: "echo bind/listen errno \(errno)") }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sfd, $0, &len) } }
        fd = sfd
        port = Int(UInt16(bigEndian: a.sin_port))
        let lfd = fd
        let flag = stopFlag
        Thread.detachNewThread {
            while true {
                var pfd = pollfd(fd: lfd, events: Int16(POLLIN), revents: 0)
                if poll(&pfd, 1, 100) > 0 {
                    let c = accept(lfd, nil, nil)
                    if c >= 0 { Thread.detachNewThread { EchoServer.echo(c) } }
                }
                if flag.isSet { return }
            }
        }
    }

    private static func echo(_ c: Int32) {
        defer { close(c) }
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            var pfd = pollfd(fd: c, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, 5000) <= 0 { return }
            let n = recv(c, &buf, buf.count, 0)
            if n <= 0 { return }
            _ = send(c, buf, n, 0)
        }
    }

    func stop() {
        if !stopFlag.set() { Thread.sleep(forTimeInterval: 0.15); close(fd) }
    }
}

/// Client TCP bloquant avec délai (127.0.0.1).
private func tcpExchange(port: Int, send payload: [UInt8], expect count: Int, via socks: Bool = false) -> [UInt8]? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var tv = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1"); a.sin_port = in_port_t(port).bigEndian
    let c = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard c == 0 else { return nil }
    _ = payload.withUnsafeBytes { send(fd, $0.baseAddress, payload.count, 0) }
    var out: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 256)
    while out.count < count {
        let n = recv(fd, &buf, min(buf.count, count - out.count), 0)
        if n <= 0 { break }
        out += buf[0..<n]
    }
    return out
}

/// Échange SOCKS5 complet vers 127.0.0.1:`destPort`, puis écho d'un message.
private func socksEcho(proxyPort: Int, destPort: Int, message: [UInt8]) -> [UInt8]? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var tv = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1"); a.sin_port = in_port_t(proxyPort).bigEndian
    guard withUnsafePointer(to: &a, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else { return nil }
    func sendAll(_ b: [UInt8]) { _ = b.withUnsafeBytes { send(fd, $0.baseAddress, b.count, 0) } }
    func recvExact(_ n: Int) -> [UInt8]? {
        var out: [UInt8] = []; var buf = [UInt8](repeating: 0, count: n)
        while out.count < n { let r = recv(fd, &buf, n - out.count, 0); if r <= 0 { return nil }; out += buf[0..<r] }
        return out
    }
    sendAll([5, 1, 0])
    guard recvExact(2) == [5, 0] else { return nil }
    sendAll([5, 1, 0, 1, 127, 0, 0, 1, UInt8(destPort >> 8), UInt8(destPort & 0xff)])
    guard let rep = recvExact(10), rep[1] == 0 else { return nil }
    sendAll(message)
    return recvExact(message.count)
}

/// Crée un socket Unix orphelin (fichier présent, personne n'écoute).
private func makeOrphanSocket(at path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: a.sun_path) else { return false }
    withUnsafeMutableBytes(of: &a.sun_path) { raw in for (i, b) in bytes.enumerated() { raw[i] = UInt8(bitPattern: b) } }
    let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    return r == 0
}

private func masterFailedMessage(_ body: () async throws -> Void) async -> String? {
    do { try await body(); return nil }
    catch SSHTransportError.masterFailed(let m) { return m }
    catch { return "autre erreur : \(error)" }
}

// MARK: - Tests d'intégration (sshd local)

@Suite("OpenSSHTransport (sshd local)", .enabled(if: LocalSSHD.isAvailable, "sshd local non privilégié indisponible sur cet hôte"), .serialized)
struct OpenSSHTransportIntegrationTests {
    @Test func connectIsAliveDisconnectSansResidu() async throws {
        try await LocalSSHD.with { d in
            let t = transport(d)
            #expect(await t.isAlive() == false)
            try await t.connect()
            #expect(await t.isAlive())
            let socket = try #require(await t.controlSocketPath)
            #expect(socket.utf8.count < 100)
            #expect(FileManager.default.fileExists(atPath: socket))
            let attrs = try FileManager.default.attributesOfItem(atPath: (socket as NSString).deletingLastPathComponent)
            #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            #expect(d.acceptedAuthenticationCount() == 1)
            await t.disconnect()
            #expect(await t.isAlive() == false)
            #expect(!FileManager.default.fileExists(atPath: socket))
            #expect(!FileManager.default.fileExists(atPath: (socket as NSString).deletingLastPathComponent))
            #expect(pgrep("ssh -M -S \(socket)").isEmpty)
            #expect(pgrep(socket).isEmpty)
        }
    }

    @Test func connectEstIdempotentMemeEnConcurrence() async throws {
        try await LocalSSHD.with { d in
            try await withTransport(d) { t in
                try await t.connect()
                let pid = await t.masterProcessIdentifier
                try await t.connect()
                async let a: Void = t.connect()
                async let b: Void = t.connect()
                _ = try await (a, b)
                #expect(await t.masterProcessIdentifier == pid)
                #expect(d.acceptedAuthenticationCount() == 1)
            }
        }
    }

    @Test func connectConcurrentDepuisEtatFroid() async throws {
        try await LocalSSHD.with { d in
            try await withTransport(d) { t in
                async let a: Void = t.connect()
                async let b: Void = t.connect()
                async let c: Void = t.connect()
                _ = try await (a, b, c)
                #expect(await t.isAlive())
                #expect(d.acceptedAuthenticationCount() == 1)
            }
        }
    }

    @Test func socketOrphelinPreexistantEstSupprime() async throws {
        try await LocalSSHD.with { d in
            let path = "\(d.directory)/c"
            #expect(makeOrphanSocket(at: path))
            #expect(FileManager.default.fileExists(atPath: path))
            let t = OpenSSHTransport(profile: d.profile(), configuration: .init(ssh: d.sshOptions(), controlPath: path))
            do {
                let started = Date()
                try await t.connect()
                #expect(await t.isAlive())
                #expect(Date().timeIntervalSince(started) < 5)
                await t.disconnect()
            } catch { await t.disconnect(); throw error }
            #expect(!FileManager.default.fileExists(atPath: path))
        }
    }

    @Test func mauvaiseCleDonneMasterFailedRapide() async throws {
        try await LocalSSHD.with { d in
            let t = transport(d, profile: d.profile(auth: .keyFile(path: d.wrongKey)))
            let started = Date()
            let msg = await masterFailedMessage { try await t.connect() }
            let elapsed = Date().timeIntervalSince(started)
            let m = try #require(msg)
            #expect(m.contains("Permission denied"), "message : \(m)")
            #expect(elapsed < 5, "durée : \(elapsed)")
            #expect(await t.isAlive() == false)
            #expect(await t.masterProcessIdentifier == nil)
            await t.disconnect()
        }
    }

    @Test func hoteInjoignableEchoueVite() async throws {
        let port = try LocalSSHD.freePort()   // aucun sshd derrière
        let ssh = OpenSSHOptions(configFile: "/dev/null", connectTimeout: 3, extraOptions: ["IdentityAgent=none"])
        let t = OpenSSHTransport(
            profile: HostProfile(name: "x", host: "127.0.0.1", port: port, user: "nobody", auth: .keyFile(path: "/nonexistent")),
            configuration: .init(ssh: ssh))
        let started = Date()
        let msg = await masterFailedMessage { try await t.connect() }
        let elapsed = Date().timeIntervalSince(started)
        let m = try #require(msg)
        #expect(m.lowercased().contains("refused"), "message : \(m)")
        #expect(elapsed < 4, "durée : \(elapsed)")
        await t.disconnect()
    }

    @Test func nonConnecteLesOperationsLevent() async throws {
        try await LocalSSHD.with { d in
            let t = transport(d)
            await #expect(throws: SSHTransportError.notConnected) { try await t.openSFTPChannel() }
            await #expect(throws: SSHTransportError.notConnected) { try await t.shellCommand() }
            await #expect(throws: SSHTransportError.notConnected) { try await t.addTunnel(TunnelSpec(kind: .dynamic, bindPort: 1)) }
        }
    }

    @Test func canalSFTPEchangeInitVersion() async throws {
        try await LocalSSHD.with { d in
            try await withTransport(d) { t in
                try await t.connect()
                let ch = try await t.openSFTPChannel()
                #expect(await t.sessionCount == 1)
                try await ch.write(sftpInit())
                let pkt = try await readPacket(ch)
                #expect(pkt.first == 2, "type VERSION attendu")
                let version = pkt.dropFirst().prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                #expect(version == 3)
                #expect(d.acceptedAuthenticationCount() == 1)
                await ch.close()
                #expect(await eventually { await t.sessionCount == 0 })
                await #expect(throws: ByteChannelError.self) { try await ch.read(exactly: 1) }
                // Un second canal fonctionne toujours sur le même maître.
                let ch2 = try await t.openSFTPChannel()
                try await ch2.write(sftpInit())
                #expect(try await readPacket(ch2).first == 2)
                await ch2.close()
                #expect(d.acceptedAuthenticationCount() == 1)
            }
        }
    }

    @Test func shellCommandReutiliseLeMaitre() async throws {
        try await LocalSSHD.with { d in
            try await withTransport(d) { t in
                try await t.connect()
                let sc = try await t.shellCommand(remoteCommand: "echo escale-$((6*7))")
                #expect(sc.executable == "/usr/bin/ssh")
                #expect(sc.arguments.contains("-tt") && sc.arguments.contains("ControlMaster=no"))
                #expect(sc.arguments.contains("ProxyCommand=/usr/bin/false"))
                let r = await OpenSSHProcessRunner.run(executable: sc.executable, arguments: sc.arguments, environment: sc.environment, timeout: 10)
                #expect(r.status == 0, "stderr : \(r.stderr)")
                #expect(r.stdout.contains("escale-42"), "stdout : \(r.stdout)")
                #expect(await t.sessionCount == 1)
                sc.lease?.release()
                #expect(await eventually { await t.sessionCount == 0 })
                #expect(d.acceptedAuthenticationCount() == 1, "sshd : \(d.log())")
            }
        }
    }

    @Test func tunnelLocalAllerRetourPuisRetire() async throws {
        let echo = try EchoServer()
        defer { echo.stop() }
        try await LocalSSHD.with { d in
            try await withTransport(d) { t in
                try await t.connect()
                let port = try LocalSSHD.freePort()
                let spec = TunnelSpec(kind: .local, bindPort: port, destinationHost: "127.0.0.1", destinationPort: echo.port)
                try await t.addTunnel(spec)
                #expect(await t.activeTunnels == [spec])
                let msg = Array("bonjour-escale".utf8)
                #expect(tcpExchange(port: port, send: msg, expect: msg.count) == msg)
                try await t.removeTunnel(spec)
                #expect(await t.activeTunnels.isEmpty)
                #expect(LocalSSHD.portAccepts(port) == false)
                #expect(d.acceptedAuthenticationCount() == 1)
            }
        }
    }

    @Test func tunnelDynamicSocks() async throws {
        let echo = try EchoServer()
        defer { echo.stop() }
        try await LocalSSHD.with { d in
            try await withTransport(d) { t in
                try await t.connect()
                let port = try LocalSSHD.freePort()
                let spec = TunnelSpec(kind: .dynamic, bindPort: port)
                try await t.addTunnel(spec)
                let msg = Array("via-socks".utf8)
                #expect(socksEcho(proxyPort: port, destPort: echo.port, message: msg) == msg)
                try await t.removeTunnel(spec)
                #expect(LocalSSHD.portAccepts(port) == false)
            }
        }
    }

    @Test func forwardingInterditLeveForwardRefused() async throws {
        let echo = try EchoServer()
        defer { echo.stop() }
        try await LocalSSHD.with(.init(allowTcpForwarding: false)) { d in
            try await withTransport(d) { t in
                try await t.connect()
                let port = try LocalSSHD.freePort()
                let spec = TunnelSpec(kind: .local, bindPort: port, destinationHost: "127.0.0.1", destinationPort: echo.port)
                do {
                    try await t.addTunnel(spec)
                    Issue.record("addTunnel aurait dû être refusé")
                } catch SSHTransportError.forwardRefused(let m) {
                    #expect(!m.isEmpty)
                    #expect(m.contains("prohibited") || m.contains("open failed") || m.contains("rejeté"), "message : \(m)")
                }
                #expect(await t.activeTunnels.isEmpty)
                #expect(await eventually { LocalSSHD.portAccepts(port) == false }, "le tunnel refusé doit être annulé")
            }
        }
    }

    @Test func maxSessionsDeuxTroisiemeSessionRefuseeSansNouvelleAuth() async throws {
        try await LocalSSHD.with(.init(maxSessions: 2)) { d in
            try await withTransport(d) { t in
                try await t.connect()
                let c1 = try await t.openSFTPChannel()
                let c2 = try await t.openSFTPChannel()
                #expect(d.acceptedAuthenticationCount() == 1)
                do {
                    let c3 = try await t.openSFTPChannel()
                    await c3.close()
                    Issue.record("la 3e session aurait dû être refusée")
                } catch SSHTransportError.sessionRefused(let m) {
                    #expect(m.contains("refused"), "message : \(m)")
                }
                #expect(await t.sessionCount == 2)
                // Laisse sshd journaliser, puis vérifie qu'aucune connexion n'a été rouverte en silence.
                try await Task.sleep(for: .milliseconds(300))
                #expect(d.acceptedAuthenticationCount() == 1, "sshd : \(d.log())")
                // Libérer une session permet d'en rouvrir une.
                await c1.close()
                #expect(await eventually { await t.sessionCount == 1 })
                let c4 = try await t.openSFTPChannel()
                #expect(d.acceptedAuthenticationCount() == 1)
                await c2.close(); await c4.close()
            }
        }
    }

    @Test func plafondLocalDeSessions() async throws {
        try await LocalSSHD.with { d in
            try await withTransport(d, maxSessions: 1) { t in
                try await t.connect()
                let c = try await t.openSFTPChannel()
                await #expect(throws: SSHTransportError.self) { try await t.openSFTPChannel() }
                await c.close()
            }
        }
    }

    @Test func maitreTueCanalEtIsAliveEchouentVite() async throws {
        try await LocalSSHD.with { d in
            let t = transport(d)
            do {
                try await t.connect()
                let ch = try await t.openSFTPChannel()
                try await ch.write(sftpInit())
                _ = try await readPacket(ch)
                let pid = try #require(await t.masterProcessIdentifier)
                let socket = try #require(await t.controlSocketPath)
                #expect(kill(pid, SIGKILL) == 0)
                let started = Date()
                do {
                    _ = try await ch.read(exactly: 4)
                    Issue.record("la lecture aurait dû échouer")
                } catch let ByteChannelError.closed(reason) {
                    #expect(!reason.isEmpty)
                }
                #expect(Date().timeIntervalSince(started) < 2)
                #expect(await eventually { await t.isAlive() == false })
                #expect(!FileManager.default.fileExists(atPath: socket), "socket orphelin non nettoyé")
                await ch.close()
                // Reconnexion après la mort du maître.
                try await t.connect()
                #expect(await t.isAlive())
                #expect(d.acceptedAuthenticationCount() == 2)
                await t.disconnect()
            } catch { await t.disconnect(); throw error }
            #expect(pgrep("ssh -M").filter { $0.contains(d.directory) || $0.contains("\(d.port)") }.isEmpty)
        }
    }

    @Test func bailLibereUneSeuleFoisEtSuitLeProcessPTY() async throws {
        try await LocalSSHD.with { d in
            try await withTransport(d) { t in
                try await t.connect()
                // Fin normale du pty : place rendue.
                let a = try await t.shellCommand(remoteCommand: "exit 0")
                #expect(await t.sessionCount == 1)
                let pa = try PTYProcess(executable: a.executable, arguments: a.arguments,
                                        environment: ["PATH": "/usr/bin:/bin"], columns: 80, rows: 24, lease: a.lease)
                _ = await pa.waitForExit()
                #expect(await eventually { await t.sessionCount == 0 })
                // Kill : place rendue, et un second release() manuel ne décrémente pas une autre session.
                let b = try await t.shellCommand()
                let c = try await t.shellCommand(remoteCommand: "sleep 30")
                #expect(await t.sessionCount == 2)
                let pb = try PTYProcess(executable: b.executable, arguments: b.arguments,
                                        environment: ["PATH": "/usr/bin:/bin"], columns: 80, rows: 24, lease: b.lease)
                pb.kill(); _ = await pb.waitForExit()
                #expect(await eventually { await t.sessionCount == 1 })
                b.lease?.release(); b.lease?.release()
                try? await Task.sleep(for: .milliseconds(200))
                #expect(await t.sessionCount == 1)
                // Échec de lancement : place rendue sans processus.
                #expect(throws: PTYError.self) {
                    _ = try PTYProcess(executable: "/nonexistent/ssh", arguments: [], environment: [:], columns: 80, rows: 24, lease: c.lease)
                }
                #expect(await eventually { await t.sessionCount == 0 })
            }
        }
    }

    @Test func bailPerimeApresDisconnectNeTouchepasLeNouveauMaitre() async throws {
        try await LocalSSHD.with { d in
            try await withTransport(d) { t in
                try await t.connect()
                let old = try await t.shellCommand()
                await t.disconnect()
                #expect(await t.sessionCount == 0)
                try await t.connect()
                let fresh = try await t.shellCommand()
                #expect(await t.sessionCount == 1)
                old.lease?.release()
                try? await Task.sleep(for: .milliseconds(200))
                #expect(await t.sessionCount == 1, "le bail de l'ancien maître ne doit pas décrémenter")
                fresh.lease?.release()
                #expect(await eventually { await t.sessionCount == 0 })
            }
        }
    }
}
