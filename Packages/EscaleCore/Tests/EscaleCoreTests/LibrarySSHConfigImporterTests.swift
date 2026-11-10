import Foundation
import Testing
@testable import EscaleCore

@Suite struct LibrarySSHConfigImporterTests {
    private func write(_ text: String, _ name: String, in dir: URL) throws -> URL {
        let u = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    @Test func tokenizer() {
        #expect(SSHConfigImporter.tokenize("  HostName=foo.example.com")! == ("hostname", ["foo.example.com"]))
        #expect(SSHConfigImporter.tokenize("User = bob # note")! == ("user", ["bob"]))
        #expect(SSHConfigImporter.tokenize("Host \"my host\" other")! == ("host", ["my host", "other"]))
        #expect(SSHConfigImporter.tokenize("# commentaire") == nil)
        #expect(SSHConfigImporter.tokenize("   ") == nil)
    }

    @Test func realisticConfig() throws {
        let dir = try libraryTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let text = """
        # Réglages globaux
        Host *
            ServerAliveInterval 30
            User ignored

        Host web
            HostName web.example.com
            User deploy
            Port 2222
            IdentityFile ~/.ssh/id_web
            IdentityFile ~/.ssh/id_web2

        host=db  db-replica   # plusieurs alias
            HOSTNAME 10.0.0.5
            user=postgres
            ProxyJump bastion

        Host *.internal staging-?  !secret
            User nobody

        Host !negated
            Port 1

        Host "quoted alias"
            HostName=q.example.com

        Host mixed web
            Port 9999

        Match host foo exec "test -f /x"
            User fromMatch

        Host afterMatch
            HostName after.example.com
        """
        let r = SSHConfigImporter(baseDirectory: dir).parse(text: text)
        #expect(r.entries.map(\.alias) == ["web", "db", "db-replica", "quoted alias", "mixed", "afterMatch"])
        let web = r.entries[0]
        #expect(web.hostName == "web.example.com" && web.user == "deploy" && web.port == 2222)
        #expect(web.identityFiles == ["~/.ssh/id_web", "~/.ssh/id_web2"])
        #expect(web.candidate.host == "web" && web.candidate.name == "web")
        #expect(web.candidate.auth == .openSSHDefaults)
        #expect(web.candidate.port == nil && web.candidate.user == nil)
        let db = r.entries[1]
        #expect(db.hostName == "10.0.0.5" && db.user == "postgres" && db.proxyJump == "bastion")
        #expect(r.entries[2].proxyJump == "bastion")
        #expect(r.entries[3].hostName == "q.example.com")
        #expect(web.port == 2222)  // première valeur gagne (Host mixed web → 9999 ignoré pour web)
        #expect(r.entries[4].port == 9999)
        #expect(r.entries[5].user == nil)  // le User du Match n'a pas fui
        #expect(r.entries[5].hostName == "after.example.com")
    }

    @Test func includeRelativeGlobAndCycle() throws {
        let dir = try libraryTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let main = try write("""
        Include config.d/*.conf
        Include missing/*.conf
        Host top
            HostName top.test
        """, "config", in: dir)
        _ = try write("Host b1\n  HostName b1.test\n", "config.d/20-b.conf", in: dir)
        _ = try write("Host a1\n  HostName a1.test\nInclude config\n", "config.d/10-a.conf", in: dir)  // cycle
        _ = try write("Host ignored\n", "config.d/readme.txt", in: dir)

        let r = try SSHConfigImporter(baseDirectory: dir).parse(fileAt: main)
        #expect(r.entries.map(\.alias) == ["a1", "b1", "top"])  // ordre lexical du glob
        #expect(r.warnings.contains { $0.contains("circulaire") })
    }

    @Test func includeDepthBounded() throws {
        let dir = try libraryTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<30 { _ = try write("Host h\(i)\nInclude c\(i + 1)\n", "c\(i)", in: dir) }
        let r = try SSHConfigImporter(baseDirectory: dir).parse(fileAt: dir.appendingPathComponent("c0"))
        #expect(r.entries.count == SSHConfigImporter.maxIncludeDepth + 1)
        #expect(r.warnings.contains { $0.contains("profondeur") })
    }

    @Test func includeInsideMatchIgnoredAndNeverWrites() throws {
        let dir = try libraryTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let other = try write("Host hidden\n", "other", in: dir)
        let main = try write("Match all\n  Include other\nHost seen\n", "config", in: dir)
        let before = try Data(contentsOf: main)
        let r = try SSHConfigImporter(baseDirectory: dir).parse(fileAt: main)
        #expect(r.entries.map(\.alias) == ["seen"])
        #expect(try Data(contentsOf: main) == before)
        _ = other
    }

    @Test func mergeAvoidsDuplicates() {
        let importer = SSHConfigImporter(baseDirectory: URL(fileURLWithPath: "/nonexistent"))
        let r = importer.parse(text: "Host web db\nHost web\n")
        #expect(r.entries.map(\.alias) == ["web", "db"])  // doublon interne éliminé
        var lib = HostLibrary(hosts: [
            HostProfile(name: "Mon web", host: "web", auth: .openSSHDefaults),
            HostProfile(name: "db explicite", host: "db", auth: .keyFile(path: "/k")),  // auth différente : pas un doublon
        ])
        let folder = UUID()
        lib.folders.append(HostFolder(id: folder, name: "Import"))
        let added = SSHConfigImporter.merge(r, into: &lib, folderID: folder)
        #expect(added.map(\.host) == ["db"])
        #expect(added[0].folderID == folder)
        #expect(lib.hosts.count == 3)
        #expect(SSHConfigImporter.merge(r, into: &lib).isEmpty)  // idempotent
        #expect(lib.hosts.count == 3)
    }
}
