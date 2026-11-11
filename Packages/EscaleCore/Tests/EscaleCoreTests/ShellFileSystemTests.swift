import Foundation
import Testing
@testable import EscaleCore

/// Exécuteur local : les commandes « distantes » tournent dans `/bin/sh` de cette machine (pas de sshd).
struct LocalShellExecutor: ShellExecutor {
    func runShell(_ command: String, timeout: TimeInterval, maxOutputBytes: Int) async throws -> RemoteExecResult {
        let s = try await openShellStream(command)
        let out = try await s.readAll()
        let (code, err) = await s.finish(timeout: timeout)
        return RemoteExecResult(exitCode: code, stdout: String(decoding: out, as: UTF8.self), stderr: err)
    }
    func openShellStream(_ command: String) async throws -> RemoteExecStream {
        try RemoteExecStream(executable: "/bin/sh", arguments: ["-c", command], environment: [:])
    }
}

private func tempDir() throws -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shellfs-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func bytes(_ u: URL) -> Data { Data(u.path.utf8) }
private func bytes(_ s: String) -> Data { Data(s.utf8) }

@Suite("ShellFileSystem (repli sans SFTP)")
struct ShellFileSystemTests {
    static let nastyNames = [
        "simple.txt", "avec espace.txt", "it's.txt", "$(touch PWNED).txt", "`touch PWNED2`.txt",
        "a;b&c|d.txt", "étoilé *.txt", "-tiret.txt", "retour\nligne.txt", "\"guillemets\".txt", "backslash\\n.txt",
    ]

    @Test("quoting : apostrophes et caractères spéciaux restent littéraux")
    func quoting() {
        #expect(ShellQuote.word("a'b") == "'a'\\''b'")
        #expect(ShellQuote.word("$(x)") == "'$(x)'")
    }

    @Test("injection : noms hostiles listés, lus, renommés, supprimés sans exécution", arguments: [ShellListingTier.statLoop, .ls, nil])
    func injection(tier: ShellListingTier?) async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let fs = ShellFileSystem(executor: LocalShellExecutor(), forcedTier: tier)
        for (i, n) in Self.nastyNames.enumerated() {
            try Data("contenu \(i)".utf8).write(to: dir.appendingPathComponent(n))
        }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("dossier $(x)"), withIntermediateDirectories: false)
        let entries = try await fs.listEntries(in: bytes(dir))
        let names = Set(entries.map { String(decoding: $0.nameBytes, as: UTF8.self) })
        var expected = Set(Self.nastyNames); expected.insert("dossier $(x)")
        if tier == .ls { expected.remove("retour\nligne.txt") } // limite documentée du repli ls
        #expect(expected.isSubset(of: names), "manquants : \(expected.subtracting(names))")
        #expect(entries.first { String(decoding: $0.nameBytes, as: UTF8.self) == "dossier $(x)" }?.type == .directory)
        let file = entries.first { String(decoding: $0.nameBytes, as: UTF8.self) == "it's.txt" }
        #expect(file?.type == .regular)
        #expect(file?.attributes.size == 9)

        let p = bytes(dir).remoteJoined(bytes("$(touch PWNED).txt"))
        #expect(try await fs.readBlock(p, offset: 2, length: 4) == Data("nten".utf8))
        try await fs.renameItem(p, to: bytes(dir).remoteJoined(bytes("renommé ' \"x\".txt")))
        try await fs.removeFile(bytes(dir).remoteJoined(bytes("`touch PWNED2`.txt")))
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!files.contains { $0.hasPrefix("PWNED") })
        #expect(files.contains("renommé ' \"x\".txt"))
        #expect(!FileManager.default.fileExists(atPath: "PWNED") && !FileManager.default.fileExists(atPath: "PWNED2"))
    }

    @Test("stat, canonicalPath, mkdir, rmdir, copie récursive, erreurs typées")
    func basics() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let fs = ShellFileSystem(executor: LocalShellExecutor())
        let root = bytes(dir)
        try await fs.makeDirectory(root.remoteJoined(bytes("d 1")))
        try Data("abc".utf8).write(to: dir.appendingPathComponent("d 1/f.txt"))
        let a = try await fs.attributes(of: root.remoteJoined(bytes("d 1/f.txt")))
        #expect(a.size == 3 && a.type == .regular)
        #expect(try await fs.attributes(of: root.remoteJoined(bytes("d 1"))).type == .directory)
        try await fs.copyItem(from: root.remoteJoined(bytes("d 1")), to: root.remoteJoined(bytes("copie")))
        #expect(try String(contentsOf: dir.appendingPathComponent("copie/f.txt"), encoding: .utf8) == "abc")
        let canon = try await fs.canonicalPath(root.remoteJoined(bytes("d 1/../d 1")))
        #expect(canon.hasSuffix("/d 1"))
        do { _ = try await fs.attributes(of: root.remoteJoined(bytes("absent"))); Issue.record("devait échouer") }
        catch SFTPError.status(let c, _) { #expect(c == .noSuchFile) }
        do { _ = try await fs.listEntries(in: root.remoteJoined(bytes("absent"))); Issue.record("devait échouer") }
        catch SFTPError.status(let c, _) { #expect(c == .noSuchFile) }
        try await fs.removeTree(root.remoteJoined(bytes("copie")))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("copie").path))
    }

    @Test("écriture par blocs : tronque puis écrit à un offset")
    func writeBlocks() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let fs = ShellFileSystem(executor: LocalShellExecutor())
        let p = bytes(dir).remoteJoined(bytes("w 'x'.bin"))
        try await fs.writeBlock(p, offset: 0, data: Data("0123456789".utf8), truncate: true)
        try await fs.writeBlock(p, offset: 4, data: Data("XY".utf8), truncate: false)
        #expect(try Data(contentsOf: URL(fileURLWithPath: String(decoding: p, as: UTF8.self))) == Data("0123XY6789".utf8))
    }

    @Test("téléchargement et envoi, puis reprise vérifiée")
    func transfersAndResume() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let fs = ShellFileSystem(executor: LocalShellExecutor())
        var big = Data(count: 300_000 + 17)
        for i in 0..<big.count { big[i] = UInt8(truncatingIfNeeded: i &* 31 &+ i >> 8) }
        let remote = dir.appendingPathComponent("grand fichier 'x'.bin")
        try big.write(to: remote)

        // Téléchargement complet
        let local = dir.appendingPathComponent("down.bin")
        let o1 = try await fs.download(bytes(remote), to: local)
        #expect(o1.totalBytes == UInt64(big.count) && o1.resumedFrom == 0)
        #expect(try Data(contentsOf: local) == big)

        // Reprise : fichier local tronqué à 150 000 o → reprise alignée sur 64 Kio (131 072)
        let part = dir.appendingPathComponent("part.bin")
        try big.prefix(150_000).write(to: part)
        let o2 = try await fs.startDownload(remotePath: bytes(remote), to: part, resume: true, verification: .default).outcome
        #expect(o2.resumedFrom == 131_072, "reprise à \(o2.resumedFrom)")
        #expect(try Data(contentsOf: part) == big)

        // Reprise refusée si le début diffère
        var bad = Data(big.prefix(150_000)); bad[10] ^= 0xFF
        try bad.write(to: part)
        let o3 = try await fs.startDownload(remotePath: bytes(remote), to: part, resume: true, verification: .default).outcome
        #expect(o3.resumedFrom == 0 && o3.restartReason != nil)
        #expect(try Data(contentsOf: part) == big)

        // Envoi complet : atomique (.part puis mv), droits conservés
        let up = dir.appendingPathComponent("envoyé $(x).bin")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: local.path)
        let o4 = try await fs.upload(local, to: bytes(up))
        #expect(o4.totalBytes == UInt64(big.count))
        #expect(try Data(contentsOf: up) == big)
        #expect(!FileManager.default.fileExists(atPath: up.path + ".part"))
        #expect((try FileManager.default.attributesOfItem(atPath: up.path)[.posixPermissions] as? Int) == 0o640)

        // Reprise d'envoi : un .part de 100 000 o
        let up2 = dir.appendingPathComponent("up2.bin")
        try big.prefix(100_000).write(to: URL(fileURLWithPath: up2.path + ".part"))
        let o5 = try await fs.startUpload(localURL: local, to: bytes(up2), resume: true, verification: .default).outcome
        #expect(o5.resumedFrom == 100_000)
        #expect(try Data(contentsOf: up2) == big)
    }

    @Test("envoi vers un dossier absent : erreur « introuvable », pas une perte de lien")
    func uploadMissingDirectory() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let fs = ShellFileSystem(executor: LocalShellExecutor())
        let local = dir.appendingPathComponent("l.bin")
        try Data(count: 5_000_000).write(to: local)
        do { _ = try await fs.upload(local, to: bytes(dir.appendingPathComponent("absent/x.bin"))); Issue.record("devait échouer") }
        catch SFTPError.status(let c, _) { #expect(c == .noSuchFile) }
        catch { Issue.record("erreur inattendue : \(error)") }
    }

    @Test("annulation : le flux est coupé et l'erreur est typée")
    func cancel() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let fs = ShellFileSystem(executor: LocalShellExecutor())
        let local = dir.appendingPathComponent("gros.bin")
        FileManager.default.createFile(atPath: local.path, contents: nil)
        let h = try FileHandle(forWritingTo: local); try h.truncate(atOffset: 2_000_000_000); try h.close()
        let t = fs.startUpload(localURL: local, to: bytes(dir.appendingPathComponent("dest.bin")), resume: false, verification: .default)
        try await Task.sleep(for: .milliseconds(50))
        t.cancel()
        do { _ = try await t.outcome; Issue.record("devait être annulé") }
        catch SFTPError.cancelled { } catch { Issue.record("erreur inattendue : \(error)") }
    }

    @Test("analyse de `ls -lan` (avec et sans --time-style)")
    func lsParsing() {
        let sample = """
        total 8
        drwxr-xr-x  2 501 20   64 1700000000 dossier avec espace
        -rw-r--r--  1 501 20 1234 1700000001 f.txt
        lrwxr-xr-x  1 501 20    5 1700000002 lien -> f.txt
        -rw-r-----  1 1000 1000 99 Nov  3 12:34 gnu sans style.txt
        -rw-r--r--  1 1000 1000 7 Jan  2  2020 vieux.txt
        """
        let r = ShellParsers.ls(sample)
        #expect(r.count == 5)
        #expect(r[0].type == "d" && String(decoding: r[0].name, as: UTF8.self) == "dossier avec espace")
        #expect(r[1].size == 1234 && r[1].mtime == 1_700_000_001 && r[1].permissions == 0o644)
        #expect(r[2].type == "l" && r[2].link == "f.txt" && String(decoding: r[2].name, as: UTF8.self) == "lien")
        #expect(r[3].permissions == 0o640 && String(decoding: r[3].name, as: UTF8.self) == "gnu sans style.txt")
        #expect(r[4].size == 7)
    }

    @Test("analyse de `find -printf` (GNU)")
    func gnuFindParsing() throws {
        let out = "f\u{0}12\u{0}1700000000.5000000000\u{0}644\u{0}\u{0}a b\u{0}l\u{0}5\u{0}1700000001.0\u{0}777\u{0}cible\u{0}lien\u{0}"
        let r = try ShellParsers.gnuFind(out)
        #expect(r.count == 2 && r[0].size == 12 && r[0].permissions == 0o644 && r[1].link == "cible")
    }
}

@Suite("Taille des paquets SFTP")
struct SFTPChunkSizeTests {
    @Test("sans limite annoncée : 32 Kio ; avec limits : 64 Kio borné par la limite")
    func computation() {
        #expect(SFTPClient.chunkSize(configured: 32768, preferred: 65536, announcedLimit: 0) == 65536)
        #expect(SFTPClient.chunkSize(configured: 32768, preferred: 65536, announcedLimit: 262_144) == 65536)
        #expect(SFTPClient.chunkSize(configured: 32768, preferred: 65536, announcedLimit: 16384) == 16384)
        #expect(SFTPClient.chunkSize(configured: 131072, preferred: 65536, announcedLimit: 0) == 131072)
    }

    @Test("sftp-server publie limits@openssh.com : paquets de 64 Kio")
    func realServer() async throws {
        let client = try await SFTPClient.connect(channel: try ProcessByteChannel())
        let (r, w) = await (client.readChunk, client.writeChunk)
        let hasLimits = await client.serverExtensions["limits@openssh.com"] != nil
        if hasLimits { #expect(r == 65536 && w == 65536, "r=\(r) w=\(w)") } else { #expect(r == 32768 && w == 32768) }
        await client.close()
    }
}
