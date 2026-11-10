import CryptoKit
import Foundation
import Testing
@testable import EscaleCore

// MARK: - Canal de test : /usr/libexec/sftp-server via des Pipe

/// `ByteChannel` branché directement sur `sftp-server` (sans sshd). Un thread lit stdout en continu dans un tampon.
final class ProcessByteChannel: ByteChannel, @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe(), stdout = Pipe()
    private let writeQueue = DispatchQueue(label: "sftp.test.write")
    private let lock = NSLock()
    private var buffer = Data()
    private var eof = false
    private var waiter: (count: Int, cont: CheckedContinuation<Data, any Error>)?

    init() throws {
        signal(SIGPIPE, SIG_IGN)
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/sftp-server")
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let fd = stdout.fileHandleForReading.fileDescriptor
        Thread.detachNewThread { [self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = Darwin.read(fd, &buf, buf.count)
                if n > 0 { feed(Data(buf[0..<n])) } else if n < 0 && errno == EINTR { continue } else { break }
            }
            finish()
        }
    }

    private func feed(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(d)
        serve()
    }
    private func finish() {
        lock.lock(); defer { lock.unlock() }
        eof = true
        serve()
    }
    /// Verrou déjà pris.
    private func serve() {
        guard let w = waiter else { return }
        if buffer.count >= w.count {
            waiter = nil
            let out = Data(buffer.prefix(w.count))
            buffer.removeFirst(w.count)
            w.cont.resume(returning: out)
        } else if eof {
            waiter = nil
            w.cont.resume(throwing: ByteChannelError.closed(reason: "sftp-server terminé"))
        }
    }

    func read(exactly count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            lock.lock(); defer { lock.unlock() }
            waiter = (count, cont)
            serve()
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            writeQueue.async { [stdin] in
                do { try stdin.fileHandleForWriting.write(contentsOf: data); c.resume() }
                catch { c.resume(throwing: ByteChannelError.closed(reason: "écriture impossible : \(error)")) }
            }
        }
    }

    func close() async {
        try? stdin.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    var pid: Int32 { process.processIdentifier }
    func suspend() { kill(pid, SIGSTOP) }
    func kill9() { kill(pid, SIGKILL) }
}

/// Serveur muet : n'envoie jamais rien ; `read` ne rend la main qu'à la fermeture.
final class SilentChannel: ByteChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var conts: [CheckedContinuation<Data, any Error>] = []
    private var closed = false
    func read(exactly count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { c in
            lock.lock(); defer { lock.unlock() }
            if closed { c.resume(throwing: ByteChannelError.closed(reason: "fermé")) } else { conts.append(c) }
        }
    }
    func write(_ data: Data) async throws {}
    private func markClosed() -> [CheckedContinuation<Data, any Error>] {
        lock.lock(); defer { lock.unlock() }
        closed = true; let cs = conts; conts = []; return cs
    }
    func close() async {
        let cs = markClosed()
        for c in cs { c.resume(throwing: ByteChannelError.closed(reason: "fermé")) }
    }
}

// MARK: - Outils

final class Sandbox: @unchecked Sendable {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("sftp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit {
        // Rétablit les droits avant suppression (tests permissionDenied).
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let u as URL in e { chmod(u.path, 0o755) }
        }
        try? FileManager.default.removeItem(at: url)
    }
    var path: String { url.path }
    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}

func makeClient(_ configuration: SFTPClientConfiguration = .init()) async throws -> (SFTPClient, ProcessByteChannel) {
    let ch = try ProcessByteChannel()
    return (try await SFTPClient.connect(channel: ch, configuration: configuration), ch)
}

/// Écrit `megabytes` Mio aléatoires.
func writeRandomFile(_ url: URL, megabytes: Int) throws {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let h = try FileHandle(forWritingTo: url)
    defer { try? h.close() }
    var block = [UInt8](repeating: 0, count: 1 << 20)
    for _ in 0..<megabytes {
        _ = SecRandomCopyBytes(kSecRandomDefault, block.count, &block)
        try h.write(contentsOf: Data(block))
    }
}

func sha256(of url: URL) throws -> String {
    let h = try FileHandle(forReadingFrom: url)
    defer { try? h.close() }
    var hasher = SHA256()
    while let d = try h.read(upToCount: 1 << 20), !d.isEmpty { hasher.update(data: d) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
}

// MARK: - Tests

@Suite("SFTP", .serialized)
struct SFTPClientTests {

    @Test func negotiation() async throws {
        let (c, _) = try await makeClient()
        let ext = await c.serverExtensions
        print("extensions annoncées :", ext.keys.sorted())
        let real = try await c.realpath("/tmp")
        #expect(real == "/private/tmp")
        await c.close()
    }

    @Test func silentServerTimesOut() async throws {
        let ch = SilentChannel()
        var cfg = SFTPClientConfiguration(); cfg.negotiationTimeout = .milliseconds(300)
        let start = ContinuousClock.now
        await #expect(throws: SFTPError.negotiationTimeout) {
            _ = try await SFTPClient.connect(channel: ch, configuration: cfg)
        }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func listsFiveThousandEntries() async throws {
        let sb = try Sandbox()
        for i in 0..<5000 { FileManager.default.createFile(atPath: sb.file("f\(i)").path, contents: Data("x".utf8)) }
        try FileManager.default.createDirectory(at: sb.file("sub"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: sb.file("lnk"), withDestinationURL: sb.file("f0"))
        let (c, _) = try await makeClient()
        let entries = try await c.listDirectory(sb.path)
        #expect(entries.count == 5002)
        #expect(Set(entries.map(\.name)).count == 5002)
        #expect(entries.first { $0.name == "sub" }?.type == .directory)
        #expect(entries.first { $0.name == "lnk" }?.type == .symlink)
        let f = try #require(entries.first { $0.name == "f7" })
        #expect(f.type == .regular && f.attributes.size == 1 && f.attributes.modificationTime != nil && f.attributes.uid == getuid())
        let target = try await c.readlink(sb.file("lnk").path)
        #expect(target == sb.file("f0").path)
        await c.close()
    }

    @Test func unicodeAndInvalidUTF8Names() async throws {
        let sb = try Sandbox()
        let names = ["café été", "a b  c", "🎉 emoji 😀", "ñandú.txt", "日本語"]
        for n in names { FileManager.default.createFile(atPath: sb.file(n).path, contents: Data(n.utf8)) }
        let (c, _) = try await makeClient()
        let entries = try await c.listDirectory(sb.path)
        for n in names {
            let e = try #require(entries.first { $0.name.precomposedStringWithCanonicalMapping == n.precomposedStringWithCanonicalMapping })
            #expect(e.nameIsValidUTF8)
        }
        // Chemin donné en octets bruts (Data) : même résultat que via String.
        let viaData = try await c.stat(Data(sb.file("café été").path.utf8))
        #expect(viaData.size == UInt64("café été".utf8.count))
        await c.close()

        // APFS refuse les noms non UTF-8 : on décode donc une trame NAME fabriquée à la main.
        let rawName = Data([0x62, 0x61, 0x64, 0xFF, 0xFE])
        var w = SFTPWriter()
        w.u32(1); w.bytes(rawName); w.bytes(Data("longname".utf8)); w.attrs(permissions: 0o100644, accessTime: nil, modificationTime: nil)
        let parser = SFTPClient(channel: SilentChannel(), configuration: .init())
        let parsed = try await parser.expectNames(SFTPResponse(type: SFTPPacket.name, payload: w.data))
        let bad = try #require(parsed.first)
        #expect(!bad.nameIsValidUTF8)
        #expect(bad.nameBytes == rawName)          // octets conservés à l'identique
        #expect(bad.name.contains("\u{FFFD}"))      // nom lisible marqué
        #expect(bad.type == .regular)
    }

    @Test func roundTrip64MiBWithSHA256() async throws {
        let sb = try Sandbox()
        let src = sb.file("src.bin"), dst = sb.file("dst.bin"), back = sb.file("back.bin")
        try writeRandomFile(src, megabytes: 64)
        let (c, _) = try await makeClient()
        let upProgress = Box<UInt64>(0)
        let t0 = ContinuousClock.now
        try await c.upload(localURL: src, to: dst.path) { upProgress.value = $0.bytesTransferred }
        let t1 = ContinuousClock.now
        try await c.download(remotePath: dst.path, to: back) { _ in }
        let t2 = ContinuousClock.now
        func mbps(_ d: Duration) -> Double { 64.0 / (Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) }
        print(String(format: "DÉBIT upload %.0f Mio/s, download %.0f Mio/s (64 Mio, loopback, sftp-server local)", mbps(t1 - t0), mbps(t2 - t1)))
        #expect(upProgress.value == 64 << 20)
        let h = try sha256(of: src)
        #expect(try sha256(of: dst) == h)
        #expect(try sha256(of: back) == h)
        await c.close()
    }

    @Test func emptyFile() async throws {
        let sb = try Sandbox()
        let src = sb.file("empty"), dst = sb.file("remote-empty"), back = sb.file("back")
        FileManager.default.createFile(atPath: src.path, contents: nil)
        let (c, _) = try await makeClient()
        #expect(try await c.upload(localURL: src, to: dst.path) == 0)
        #expect(try await c.stat(dst.path).size == 0)
        FileManager.default.createFile(atPath: back.path, contents: Data("reste".utf8))
        #expect(try await c.download(remotePath: dst.path, to: back) == 0)
        #expect(try Data(contentsOf: back).isEmpty)
        await c.close()
    }

    @Test func resumeFromOffset() async throws {
        let sb = try Sandbox()
        let src = sb.file("src.bin"), remote = sb.file("remote.bin"), local = sb.file("local.bin")
        try writeRandomFile(src, megabytes: 3)
        let full = try Data(contentsOf: src)
        let cut = 1_000_003 // volontairement non aligné sur la taille des blocs
        let (c, _) = try await makeClient()
        // Téléchargement : début local valide + reste de déchet qui doit être écrasé.
        try (full.prefix(cut) + Data(repeating: 0xAA, count: 5000)).write(to: local)
        try full.write(to: remote)
        try await c.download(remotePath: remote.path, to: local, resumeFrom: UInt64(cut))
        #expect(try Data(contentsOf: local) == full)
        await #expect(throws: SFTPError.self) {
            try await c.download(remotePath: remote.path, to: sb.file("nouveau"), resumeFrom: 10)
        }
        // Envoi : fichier distant partiel puis reprise.
        let remote2 = sb.file("remote2.bin")
        try full.prefix(cut).write(to: remote2)
        try await c.upload(localURL: src, to: remote2.path, resumeFrom: UInt64(cut))
        #expect(try Data(contentsOf: remote2) == full)
        await c.close()
    }

    @Test func statusErrors() async throws {
        let sb = try Sandbox()
        let (c, _) = try await makeClient()
        do { _ = try await c.stat(sb.file("absent").path); Issue.record("aurait dû échouer") }
        catch let SFTPError.status(code, message) { #expect(code == .noSuchFile); #expect(!message.isEmpty) }

        let locked = sb.file("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        chmod(locked.path, 0o000)
        do { _ = try await c.listDirectory(locked.path); Issue.record("aurait dû échouer") }
        catch let SFTPError.status(code, _) { #expect(code == .permissionDenied) }
        do { try await c.download(remotePath: sb.file("absent").path, to: sb.file("x")); Issue.record("aurait dû échouer") }
        catch let SFTPError.status(code, _) { #expect(code == .noSuchFile) }
        // Le client reste utilisable après des erreurs.
        #expect(try await c.realpath(sb.path).hasSuffix(sb.url.lastPathComponent))
        await c.close()
    }

    @Test func fileOperations() async throws {
        let sb = try Sandbox()
        let (c, _) = try await makeClient()
        let dir = sb.file("d").path
        try await c.mkdir(dir, permissions: 0o700)
        #expect(try await c.stat(dir).permissionBits == 0o700)
        try await c.setstat(dir, permissions: 0o750)
        #expect(try await c.stat(dir).permissionBits == 0o750)
        let f = sb.file("d/f").path
        FileManager.default.createFile(atPath: f, contents: Data("1".utf8))
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try await c.setstat(f, modificationTime: date)
        #expect(try await c.stat(f).modificationTime == date)
        #expect(try await c.lstat(f).type == .regular)
        try await c.remove(f)
        try await c.rmdir(dir)
        await #expect(throws: SFTPError.self) { try await c.rmdir(dir) }
        await c.close()
    }

    @Test func renameOverExistingFile() async throws {
        let sb = try Sandbox()
        try Data("nouveau".utf8).write(to: sb.file("a"))
        try Data("ancien".utf8).write(to: sb.file("b"))
        let (c, _) = try await makeClient()
        #expect(await c.supportsExtension("posix-rename@openssh.com"))
        try await c.rename(sb.file("a").path, to: sb.file("b").path)
        #expect(try String(contentsOf: sb.file("b"), encoding: .utf8) == "nouveau")
        #expect(!FileManager.default.fileExists(atPath: sb.file("a").path))
        await c.close()
    }

    @Test func cancellationMidTransfer() async throws {
        let sb = try Sandbox()
        let src = sb.file("big.bin")
        try writeRandomFile(src, megabytes: 64)
        let (c, _) = try await makeClient()
        // Envoi annulé après ~1 Mio.
        let taskBox = Box<Task<UInt64, any Error>?>(nil)
        let up = Task {
            try await c.upload(localURL: src, to: sb.file("remote.bin").path) { p in
                if p.bytesTransferred >= 1 << 20 { taskBox.value?.cancel() }
            }
        }
        taskBox.value = up
        do { _ = try await up.value; Issue.record("aurait dû être annulé") }
        catch let SFTPError.cancelled(_, bytes) { #expect(bytes < 64 << 20) }
        // Téléchargement annulé : le fichier partiel est signalé.
        let local = sb.file("partial.bin")
        let box2 = Box<Task<UInt64, any Error>?>(nil)
        let down = Task {
            try await c.download(remotePath: src.path, to: local) { p in
                if p.bytesTransferred >= 1 << 20 { box2.value?.cancel() }
            }
        }
        box2.value = down
        do { _ = try await down.value; Issue.record("aurait dû être annulé") }
        catch let SFTPError.cancelled(partial, bytes) {
            #expect(partial == local); #expect(bytes < 64 << 20)
            #expect(FileManager.default.fileExists(atPath: local.path))
        }
        // Le client est toujours sain, les handles ont été fermés.
        #expect(try await c.stat(src.path).size == 64 << 20)
        await c.close()
    }

    @Test func serverDeathFailsAllInFlightRequestsQuickly() async throws {
        let sb = try Sandbox()
        let (c, ch) = try await makeClient()
        ch.suspend() // le serveur ne répond plus : les requêtes restent en vol
        let results = Box<[Bool]>([])
        let start = ContinuousClock.now
        let finished = Box<ContinuousClock.Instant?>(nil)
        let tasks = (0..<20).map { i in
            Task {
                do { _ = try await c.stat(sb.file("x\(i)").path); results.value.append(false) }
                catch SFTPError.channelClosed { results.value.append(true) }
                catch { results.value.append(false) }
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(results.value.isEmpty)
        ch.kill9()
        for t in tasks { await t.value }
        finished.value = .now
        let elapsed = finished.value! - start
        print("mort du serveur : 20 requêtes échouées en", elapsed)
        #expect(results.value.count == 20 && results.value.allSatisfy { $0 })
        #expect(elapsed < .seconds(2) + .milliseconds(300)) // 300 ms d'attente volontaire avant le kill
        // Une nouvelle requête échoue aussi immédiatement.
        await #expect(throws: SFTPError.self) { _ = try await c.stat("/") }
    }
}
