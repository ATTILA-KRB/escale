import Foundation
import Testing
@testable import EscaleCore

@Suite("Multi-exécution : variables, cibles, historique, double Échap, rapports")
struct MultiExecPlanningTests {
    private func host(_ name: String, addr: String = "10.0.0.1", user: String? = "root", tags: [String] = [], folder: UUID? = nil) -> HostProfile {
        HostProfile(name: name, host: addr, user: user, tags: tags, folderID: folder)
    }

    @Test("variables substituées et échappées")
    func template() {
        let h = host("web 1", addr: "10.0.0.1", user: "bob")
        #expect(GroupExecTemplate.expand("ssh {user}@{host}; echo {name}", host: h) == "ssh bob@10.0.0.1; echo 'web 1'")
        #expect(GroupExecTemplate.expand("echo \"{host}\"", host: h) == "echo \"10.0.0.1\"")
        // Injection : le nom ne peut pas sortir de son mot.
        let evil = host("a'; rm -rf / #", user: nil)
        #expect(GroupExecTemplate.expand("echo {name} {user}", host: evil) == "echo 'a'\\''; rm -rf / #' ''")
        // Accolades inconnues intactes.
        #expect(GroupExecTemplate.expand("echo ${HOME} {1..3} {x}", host: h) == "echo ${HOME} {1..3} {x}")
        #expect(GroupExecTemplate.usesVariables("a {host}") && !GroupExecTemplate.usesVariables("a {x}"))
    }

    @Test("cibles : dossier récursif, étiquette")
    func targets() {
        let root = HostFolder(name: "prod"), sub = HostFolder(name: "db", parentID: root.id), other = HostFolder(name: "dev")
        let lib = HostLibrary(folders: [root, sub, other], hosts: [
            host("a", tags: ["Web"], folder: root.id), host("b", tags: ["#web", "db"], folder: sub.id),
            host("c", folder: other.id), host("d"),
        ])
        #expect(lib.hosts(inFolder: root.id).map(\.name) == ["a", "b"])
        #expect(lib.hosts(inFolder: root.id, recursive: false).map(\.name) == ["a"])
        #expect(lib.hosts(inFolder: other.id).map(\.name) == ["c"])
        #expect(lib.hosts(withTag: "WEB").map(\.name) == ["a", "b"] && lib.hosts(withTag: "#db").map(\.name) == ["b"])
        #expect(lib.hosts(withTag: " ").isEmpty)
        #expect(lib.tagCounts.map(\.tag) == ["db", "web"] && lib.tagCounts.last?.count == 2)
        // Cycle de dossiers : pas de boucle infinie.
        let a = HostFolder(name: "a"), b = HostFolder(name: "b", parentID: a.id)
        var cyc = HostLibrary(folders: [a, b], hosts: [])
        cyc.folders[0].parentID = b.id
        #expect(cyc.folderSubtree(a.id) == [a.id, b.id])
    }

    @Test("secrets détectés")
    func secrets() {
        for c in ["mysql -u r password=abc", "curl -H 'Authorization: Bearer xyz' u", "sshpass -p x ssh h", "tool --password hunter2", "export API_KEY=zz", "TOKEN: abc"] {
            #expect(CommandSecretCheck.warning(for: c) != nil, "\(c)")
        }
        for c in ["uptime", "df -h", "cat /etc/passwd", "grep password /etc/ssh/sshd_config", "systemctl status ssh"] {
            #expect(CommandSecretCheck.warning(for: c) == nil, "\(c)")
        }
    }

    @Test("historique : 20 max, doublon remonté, secret refusé, fichier")
    func history() throws {
        var h = GroupExecHistory()
        for i in 0..<25 { let ok = h.record("echo \(i)", hostCount: 2); #expect(ok) }
        #expect(h.entries.count == 20 && h.entries.first?.command == "echo 24" && h.entries.last?.command == "echo 5")
        _ = h.record("echo 10", hostCount: 3)
        #expect(h.entries.first?.command == "echo 10" && h.entries.count == 20 && h.entries.filter { $0.command == "echo 10" }.count == 1)
        let r1 = h.record("login password=abc", hostCount: 1), r2 = h.record("  ", hostCount: 1)
        #expect(!r1 && !r2)
        #expect(!h.entries.contains { $0.command.contains("password") })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mexh-\(UUID().uuidString)/history.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try h.save(to: url)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        #expect(GroupExecHistory.load(from: url).entries == h.entries)
        // Fichier édité à la main avec un secret : filtré au chargement ; fichier corrompu : vide.
        try Data(#"{"entries":[{"id":"\#(UUID().uuidString)","command":"x token=1","date":"2026-01-01T00:00:00Z","hostCount":1,"hadOverrides":false}]}"#.utf8).write(to: url)
        #expect(GroupExecHistory.load(from: url).entries.isEmpty)
        try Data("pas du json".utf8).write(to: url)
        #expect(GroupExecHistory.load(from: url).entries.isEmpty)
    }

    @Test("double Échap")
    func doubleEscape() {
        let esc = Data([0x1b]), x = Data("x".utf8), alt = Data([0x1b, 0x78])
        var d = DoubleEscapeDetector(window: 0.35)
        let z = d.feed(x, now: 0); #expect(z == .forward)
        let a1 = d.feed(esc, now: 1); #expect(a1 == .hold && d.hasPending)
        let a2 = d.feed(esc, now: 1.2); #expect(a2 == .exit && !d.hasPending)
        // Trop lent : deux Échap séparés, chacun retenu puis diffusé.
        let b1 = d.feed(esc, now: 5), b2 = d.feed(esc, now: 5.5)
        #expect(b1 == .hold && b2 == .hold)
        let e1 = d.expire(), e2 = d.expire()
        #expect(e1 && !e2)
        // Une autre saisie après un Échap retenu : l'Échap passe d'abord (ordre conservé).
        let c1 = d.feed(esc, now: 9), c2 = d.feed(x, now: 9.1)
        #expect(c1 == .hold && c2 == .flushThenForward && !d.hasPending)
        // Séquence Alt+x (un seul envoi de deux octets) : jamais confondue avec Échap.
        let f1 = d.feed(alt, now: 10); #expect(f1 == .forward)
        // Flèche (ESC [ A) : idem.
        let f2 = d.feed(Data([0x1b, 0x5b, 0x41]), now: 11); #expect(f2 == .forward)
    }

    @Test("rapport CSV et détaillé")
    func reports() {
        let ok = RemoteExecResult(exitCode: 0, stdout: "a,b\n\"q\"\n", duration: 0.5)
        let ko = RemoteExecResult(failure: "connexion refusée")
        let e = [GroupExecReportEntry(name: "h1", command: "echo 1", result: ok), GroupExecReportEntry(name: "=h2", command: "echo 2", result: ko)]
        let csv = GroupExecReport.csv(entries: e)
        let lines = csv.components(separatedBy: "\r\n")
        #expect(lines[0].hasPrefix("hote,commande,statut"))
        #expect(lines[1] == "h1,echo 1,succes,0,0.50,non,,\"a,b\n\"\"q\"\"\n\",")
        #expect(lines[2] == "'=h2,echo 2,echec,,0.00,non,connexion refusée,,")
        #expect(csv.hasSuffix("\r\n"))
        let t = GroupExecReport.detailedText(command: "echo 1", entries: e)
        #expect(t.contains("=== h1") && t.components(separatedBy: "$ echo 1").count == 2 && t.contains("$ echo 2"))
    }
}
