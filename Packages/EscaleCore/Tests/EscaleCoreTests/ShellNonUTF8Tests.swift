import Foundation
import Testing
@testable import EscaleCore

/// Exécuteur dont les commandes tournent dans `/bin/sh` local avec un PATH où `mv`, `rm`, `cp`, `mkdir` sont remplacés par des
/// sondes qui journalisent leurs arguments en hexadécimal. APFS refuse de créer un nom non UTF-8 : c'est le seul moyen
/// de vérifier, dans un vrai shell, que les octets d'origine arrivent bien aux commandes.
private struct ProbeExecutor: ShellExecutor {
    let binDir: URL
    var canned: Data? = nil
    func runShell(_ command: String, timeout: TimeInterval, maxOutputBytes: Int) async throws -> RemoteExecResult {
        let s = try await openShellStream(command)
        let out = try await s.readAll()
        let (code, err) = await s.finish(timeout: timeout)
        return RemoteExecResult(exitCode: code, stdout: String(decoding: out, as: UTF8.self), stderr: err)
    }
    func openShellStream(_ command: String) async throws -> RemoteExecStream {
        if let canned {
            // Sortie de listage préparée (octets exacts), indépendante de la commande reçue.
            let hex = canned.map { String(format: "\\%03o", $0) }.joined()
            return try RemoteExecStream(executable: "/bin/sh", arguments: ["-c", "printf '\(hex)'"], environment: [:])
        }
        return try RemoteExecStream(executable: "/bin/sh", arguments: ["-c", command],
                                    environment: ["PATH": "\(binDir.path):/usr/bin:/bin"])
    }
}

private func probeDir() throws -> (bin: URL, log: URL) {
    let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nonutf8-\(UUID().uuidString)", isDirectory: true)
    let bin = d.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let log = d.appendingPathComponent("log")
    for tool in ["mv", "rm", "cp", "mkdir"] {
        let script = "#!/bin/sh\nprintf '%s' \"$0\" | sed 's|.*/||' >> '\(log.path)'\nfor a; do printf ' '; printf '%s' \"$a\" | od -An -v -tx1 | tr -d ' \\n'; done >> '\(log.path)'\nprintf '\\n' >> '\(log.path)'\n"
        let url = bin.appendingPathComponent(tool)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    return (bin, log)
}

private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

@Suite("Mode shell : noms non UTF-8")
struct ShellNonUTF8Tests {
    /// « f\xE9.txt » (Latin-1) : invalide en UTF-8.
    static let latin1 = Data([0x66, 0xE9, 0x2E, 0x74, 0x78, 0x74])

    @Test("encodage des arguments : UTF-8 inchangé, octets invalides en octal, NUL refusé")
    func quoting() throws {
        #expect(try ShellQuote.path(Data("/tmp/é.txt".utf8)) == "/tmp/é.txt")
        let raw = try ShellQuote.path(Data("/d/".utf8) + Self.latin1)
        #expect(raw == ShellQuote.rawMarker + "/d/f\\351.txt")
        // Un nom UTF-8 qui contiendrait le marqueur est lui aussi encodé (jamais pris pour du texte).
        #expect(try ShellQuote.path(Data((ShellQuote.rawMarker + "x").utf8)).hasPrefix(ShellQuote.rawMarker + "\\001"))
        #expect(throws: SFTPError.self) { try ShellQuote.path(Data([0x61, 0x00, 0x62])) }
        // Sans argument en octets : commande inchangée (pas de prélude).
        #expect(!ShellQuote.command(script: "echo $1\n", args: ["a"]).contains("printf"))
        #expect(ShellQuote.command(script: "echo $1\n", args: [raw]).contains("printf"))
    }

    @Test("décodage dans de vrais shells : octets exacts, retours à la ligne finaux, %, \\, tiret, vide",
          arguments: ["/bin/sh", "/bin/dash", "/bin/bash"])
    func decodeInRealShells(shell: String) async throws {
        guard FileManager.default.isExecutableFile(atPath: shell) else { return }
        let samples: [Data] = [
            Self.latin1,
            Data([0x61, 0x0A, 0xFF, 0x0A, 0x0A]),                       // retours à la ligne, y compris finaux
            Data("%s \\n 100% 'q' \"d\" $(x) `y` ;&|*?".utf8) + Data([0xC3]), // métacaractères + UTF-8 tronqué
            Data("-n".utf8) + Data([0x80]),                               // tiret initial
            Data(0x80...0xFF),
        ]
        for sample in samples {
            let arg = try ShellQuote.path(sample)
            var cmd = ShellQuote.command(script: "printf '%s' \"$1\" | od -An -v -tx1\nprintf '%s' \"$2\" | od -An -v -tx1\n", args: [arg, "texte ' simple"])
            cmd = cmd.replacingOccurrences(of: "/bin/sh", with: shell)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", cmd]
            let pipe = Pipe(); p.standardOutput = pipe
            try p.run()
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let lines = String(decoding: out, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            let tokens = String(decoding: out, as: UTF8.self).split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
            let expected = hex(sample) + hex(Data("texte ' simple".utf8))
            #expect(tokens.joined() == expected, "\(shell) : \(tokens.joined()) ≠ \(expected) (\(lines.count) lignes)")
        }
    }

    @Test("listage : le nom garde ses octets, l'affichage est substitué, quel que soit le format")
    func listing() async throws {
        let (bin, _) = try probeDir(); defer { try? FileManager.default.removeItem(at: bin.deletingLastPathComponent()) }
        // find -printf : type NUL taille NUL mtime NUL mode NUL cible NUL nom NUL
        var find = Data("f\u{0}12\u{0}1700000000.0\u{0}644\u{0}\u{0}".utf8); find += Self.latin1; find += Data([0])
        find += Data("d\u{0}0\u{0}1700000001.0\u{0}755\u{0}\u{0}".utf8) + Data("dos".utf8) + Data([0xFF, 0xFE, 0]) 
        let fsFind = ShellFileSystem(executor: ProbeExecutor(binDir: bin, canned: find), forcedTier: .gnuFind)
        let e1 = try await fsFind.listEntries(in: Data("/d".utf8))
        #expect(e1.count == 2)
        #expect(e1[0].nameBytes == Self.latin1 && !e1[0].nameIsValidUTF8)
        #expect(e1[0].name == "f\u{FFFD}.txt")
        #expect(e1[1].nameBytes == Data("dos".utf8) + Data([0xFF, 0xFE]) && e1[1].type == .directory)

        // stat en boucle : type NUL « mode taille mtime » NUL cible NUL nom NUL
        var stat = Data("f\u{0}644 5 1700000000\u{0}\u{0}".utf8); stat += Self.latin1; stat += Data([0])
        let fsStat = ShellFileSystem(executor: ProbeExecutor(binDir: bin, canned: stat), forcedTier: .statLoop)
        let e2 = try await fsStat.listEntries(in: Data("/d".utf8))
        #expect(e2.count == 1 && e2[0].nameBytes == Self.latin1 && e2[0].attributes.size == 5)

        // ls -lan : dernier recours, octets conservés (lecture sans perte)
        var ls = Data("total 4\n-rw-r--r--  1 501 20 7 1700000002 ".utf8); ls += Self.latin1; ls += Data("\n".utf8)
        ls += Data("drwxr-xr-x  2 501 20 64 1700000003 ".utf8) + Data([0xE9, 0xE9]) + Data(" é\n".utf8)
        let r = ShellParsers.ls(ls)
        #expect(r.count == 2 && r[0].name == Self.latin1 && r[0].size == 7)
        #expect(r[1].name == Data([0xE9, 0xE9]) + Data(" é".utf8) && r[1].type == "d")
        // Régression : un listage UTF-8 ordinaire (texte) est inchangé.
        let t = ShellParsers.ls("-rw-r--r--  1 501 20 7 1700000002 é accentué.txt\n")
        #expect(t.count == 1 && t[0].name == Data("é accentué.txt".utf8))
    }

    @Test("renommer, supprimer, copier, créer : les commandes reçoivent les octets d'origine")
    func operationsUseOriginalBytes() async throws {
        let (bin, log) = try probeDir(); defer { try? FileManager.default.removeItem(at: bin.deletingLastPathComponent()) }
        let fs = ShellFileSystem(executor: ProbeExecutor(binDir: bin))
        let a = Data("/srv/".utf8) + Self.latin1
        let b = Data("/srv/nouveau ".utf8) + Data([0xFF, 0x0A])      // nom d'arrivée avec octet invalide et retour à la ligne final
        try await fs.renameItem(a, to: b)
        try await fs.removeFile(a)
        try await fs.copyItem(from: a, to: b)
        try await fs.makeDirectory(a)
        let lines = String(decoding: try Data(contentsOf: log), as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(lines.count == 4, "\(lines)")
        func args(_ l: String) -> [String] { l.split(separator: " ").map(String.init) }
        #expect(args(lines[0]) == ["mv", hex(Data("-f".utf8)), hex(Data("--".utf8)), hex(a), hex(b)])
        #expect(args(lines[1]) == ["rm", hex(Data("--".utf8)), hex(a)])
        #expect(args(lines[2]) == ["cp", hex(Data("-a".utf8)), hex(Data("--".utf8)), hex(a), hex(b)])
        #expect(args(lines[3]) == ["mkdir", hex(Data("--".utf8)), hex(a)])
        // Lecture / métadonnées : la commande est valide de bout en bout (fichier absent = erreur typée, pas « non pris en charge »).
        do { _ = try await fs.attributes(of: a); Issue.record("devait échouer") }
        catch SFTPError.status(let c, _) { #expect(c == .noSuchFile) }
        do { _ = try await fs.readBlock(a, offset: 0, length: 10); Issue.record("devait échouer") }
        catch SFTPError.status(let c, _) { #expect(c == .noSuchFile) }
    }
}

@Suite("Mode shell : écriture par blocs alignés")
struct ShellAlignedWriteTests {
    @Test("écriture à un offset aligné (blocs de 1 Mio) ou non : contenu exact, sans lenteur")
    func alignedWrites() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shellw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fs = ShellFileSystem(executor: LocalShellExecutor())
        let target = Data(dir.appendingPathComponent("f.bin").path.utf8)
        var content = Data(count: 3 * 1024 * 1024 + 123)
        content.withUnsafeMutableBytes { b in for i in 0..<b.count { b[i] = UInt8(truncatingIfNeeded: i &* 31 &+ i >> 8) } }
        let block = 1 << 20
        var offset = 0
        let started = Date()
        while offset < content.count {
            let end = min(offset + block, content.count)
            try await fs.writeBlock(target, offset: UInt64(offset), data: content[offset..<end], truncate: offset == 0)
            offset = end
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: String(decoding: target, as: UTF8.self))) == content)
        #expect(Date().timeIntervalSince(started) < 20)
        // Offset non aligné : repli octet par octet, toujours exact.
        try await fs.writeBlock(target, offset: 4099, data: Data("ZZZ".utf8), truncate: false)
        let after = try Data(contentsOf: URL(fileURLWithPath: String(decoding: target, as: UTF8.self)))
        #expect(after.count == content.count && after[4099..<4102] == Data("ZZZ".utf8) && after[4102...] == content[4102...])
    }
}

@Suite("RemoteExecStream : place rendue")
struct RemoteExecStreamReleaseTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    @Test("un flux libéré en cours de route rend sa place une seule fois")
    func droppedStreamCallsOnEnd() async throws {
        let c = Counter()
        do {
            let s = try RemoteExecStream(executable: "/bin/sh", arguments: ["-c", "sleep 30"], environment: [:], onEnd: { c.bump() })
            _ = s
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(c.value == 1)
        // Flux mené à terme : toujours une seule fois.
        let c2 = Counter()
        do {
            let s = try RemoteExecStream(executable: "/bin/sh", arguments: ["-c", "echo ok"], environment: [:], onEnd: { c2.bump() })
            _ = try await s.readAll()
            _ = await s.finish()
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(c2.value == 1)
    }
}
