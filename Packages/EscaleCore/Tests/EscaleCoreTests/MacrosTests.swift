import Foundation
import Testing
@testable import EscaleCore

private final class Log: @unchecked Sendable {
    private let lock = NSLock(); private var v: [String] = []
    func add(_ s: String) { lock.withLock { v.append(s) } }
    var lines: [String] { lock.withLock { v } }
}

@Suite("Macros : modèle, encodage, enregistrement")
struct MacrosModelTests {
    @Test func jsonAllerRetourToutesLesEtapesEtPortees() throws {
        let host = UUID()
        let m = Macro(name: "déploiement", steps: [.text("cd /srv\n"), .wait(milliseconds: 250), .key(.ctrlC), .text("ls\n")],
                      shortcut: 3, scope: .host(host))
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(Macro.self, from: data)
        #expect(back == m)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"type\":\"wait\""))
        #expect(json.contains("\"kind\":\"host\""))
    }

    @Test func porteeInconnueRetombeSurGlobale() throws {
        let json = #"{"id":"6F1C5B1E-0000-4000-8000-000000000001","name":"x","steps":[],"scope":{"kind":"?"}}"#
        let m = try JSONDecoder().decode(Macro.self, from: Data(json.utf8))
        #expect(m.scope == .global && m.shortcut == nil)
    }

    @Test func encodageDesEtapes() {
        let m = Macro(name: "m", steps: [.text("ls -l\npwd\r\n"), .wait(milliseconds: 100), .key(.up), .key(.ctrlC), .wait(milliseconds: 0), .text("")])
        #expect(MacroPlayback.actions(for: m) == [
            .send(Data("ls -l\rpwd\r".utf8)), .wait(milliseconds: 100), .send(Data([0x1b, 0x5b, 0x41])), .send(Data([0x03])),
        ])
    }

    @Test func attenteBornee() {
        let m = Macro(name: "m", steps: [.wait(milliseconds: 99_999_999), .wait(milliseconds: -5)])
        #expect(MacroPlayback.actions(for: m) == [.wait(milliseconds: Macro.maxWaitMilliseconds)])
    }

    @Test func lectureEnvoieEtAttendDansLOrdre() async {
        let m = Macro(name: "m", steps: [.text("a\n"), .wait(milliseconds: 40), .key(.tab)])
        let log = Log()
        let n = await MacroPlayback.play(m, send: { d in log.add("send \(Array(d))") }, sleep: { ms in log.add("wait \(ms)") })
        #expect(n == 3)
        #expect(log.lines == ["send [97, 13]", "wait 40", "send [9]"])
    }

    @Test func lectureAnnuleeNeContinuePas() async {
        let m = Macro(name: "m", steps: [.text("a"), .wait(milliseconds: 10), .text("b")])
        let log = Log()
        let task = Task { @MainActor in
            await MacroPlayback.play(m, send: { log.add("send \(Array($0))") }, sleep: { _ in withUnsafeCurrentTask { $0?.cancel() }; log.add("wait") })
        }
        let n = await task.value
        #expect(n == 2)
        #expect(log.lines == ["send [97]", "wait"])
    }

    @Test func porteeHote() {
        let a = UUID(), b = UUID()
        let lib = MacroLibrary(macros: [Macro(name: "g", scope: .global), Macro(name: "a", scope: .host(a)), Macro(name: "b", scope: .host(b))])
        #expect(lib.macros(forHost: a).map(\.name) == ["g", "a"])
        #expect(lib.macros(forHost: nil).map(\.name) == ["g"])
    }

    @Test func raccourcisEtConflits() {
        let a = UUID(), b = UUID()
        let m1 = Macro(name: "un", steps: [.text("x")], shortcut: 1, scope: .host(a))
        var lib = MacroLibrary(macros: [m1])
        // Même raccourci sur un autre hôte : sans conflit ; en global : conflit avec la macro de l'hôte a.
        #expect(lib.validate(Macro(name: "deux", steps: [.text("x")], shortcut: 1, scope: .host(b))).isEmpty)
        let conflict = lib.validate(Macro(name: "trois", steps: [.text("x")], shortcut: 1, scope: .global))
        #expect(conflict.contains { $0.severity == .error && $0.message.contains("⌃⌥1") })
        // Une macro ne rentre pas en conflit avec elle-même.
        #expect(lib.validate(m1).isEmpty)
        #expect(lib.validate(Macro(name: "dix", steps: [.text("x")], shortcut: 10)).contains { $0.severity == .error })
        lib.upsert(Macro(name: "g", steps: [.text("y")], shortcut: 2))
        #expect(lib.macro(forShortcut: 2, host: a)?.name == "g")
        lib.upsert(Macro(name: "h", steps: [.text("y")], shortcut: 2, scope: .host(a)))
        #expect(lib.macro(forShortcut: 2, host: a)?.name == "h", "la macro de l'hôte l'emporte")
    }

    @Test func nomEtEtapesObligatoires() {
        let issues = MacroLibrary().validate(Macro(name: "  ", steps: []))
        #expect(issues.filter { $0.severity == .error }.count == 2)
    }

    @Test func avertissementMotDePasse() {
        func warns(_ s: String) -> Bool { !MacroSecretHeuristics.findings(in: Macro(name: "m", steps: [.text(s)])).isEmpty }
        #expect(warns("mysql -u root -pHunter2xx\n"))
        #expect(warns("export PASSWORD=abc123\n"))
        #expect(warns("sshpass -p x ssh h\n"))
        #expect(warns("curl https://u:pw@host/x\n"))
        #expect(warns("-----BEGIN OPENSSH PRIVATE KEY-----\n"))
        #expect(!warns("cd /var/log && tail -f syslog\n"))
        let aveugle = Macro(name: "m", steps: [.text("ls\n"), .wait(milliseconds: 800), .text("Tr0ub4dor9\n")])
        #expect(!MacroSecretHeuristics.findings(in: aveugle).isEmpty)
        // Avertissement seulement : la validation ne bloque pas.
        #expect(MacroLibrary().validate(aveugle).allSatisfy { $0.severity == .warning })
    }

    @Test func enregistrementTexteEntreeEtTouches() {
        var r = MacroRecorder()
        let t = Date(timeIntervalSince1970: 1_000)
        r.feed(Data("l".utf8), at: t)
        r.feed(Data("s".utf8), at: t.addingTimeInterval(0.1))
        r.feed(Data("\r".utf8), at: t.addingTimeInterval(0.2))
        r.feed(Data([0x1b, 0x5b, 0x41]), at: t.addingTimeInterval(0.3))
        r.feed(Data([0x03]), at: t.addingTimeInterval(0.4))
        r.feed(Data([0x7f]), at: t.addingTimeInterval(0.5))
        r.feed(Data([0x1b]), at: t.addingTimeInterval(0.6))
        #expect(r.result == [.text("ls\n"), .key(.up), .key(.ctrlC), .key(.backspace), .key(.escape)])
    }

    @Test func enregistrementPausesEtCollage() {
        var r = MacroRecorder()
        let t = Date(timeIntervalSince1970: 1_000)
        r.feed(Data("ls /\r".utf8), at: t)
        r.feed(Data("é ünï\r\n".utf8), at: t.addingTimeInterval(2.34))
        r.feed(Data("x".utf8), at: t.addingTimeInterval(500))
        #expect(r.result == [.text("ls /\n"), .wait(milliseconds: 2300), .text("é ünï\n"), .wait(milliseconds: 60_000), .text("x")])
        // Rejoué : exactement ce qui a été saisi (CR comme Entrée).
        #expect(MacroPlayback.actions(for: Macro(name: "m", steps: r.result)).first == .send(Data("ls /\r".utf8)))
    }

    @Test func enregistrementUtf8CoupeEntreDeuxLivraisons() {
        var r = MacroRecorder()
        let bytes = Array("é".utf8)
        r.feed(Data([bytes[0]]), at: Date(timeIntervalSince1970: 5))
        r.feed(Data([bytes[1]]), at: Date(timeIntervalSince1970: 5.01))
        #expect(r.result == [.text("é")])
    }
}

@Suite("Macros : dépôt fichier")
struct MacroRepositoryTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("escale-macros-\(UUID().uuidString.prefix(8))")
            .appendingPathComponent("macros.json")
    }

    @Test func absentEgalVide() async throws {
        #expect(try await FileMacroRepository(url: tempURL()).load().macros.isEmpty)
    }

    @Test func allerRetourPermissionsEtAtomicite() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repo = FileMacroRepository(url: url)
        let lib = MacroLibrary(macros: [Macro(name: "a", steps: [.text("ls\n"), .wait(milliseconds: 5)], shortcut: 1)])
        try await repo.save(lib)
        #expect(try await repo.load() == lib)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(names == ["macros.json"])
    }

    @Test func fichierCorrompuMisDeCoteAvantEcriture() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("pas du json".utf8).write(to: url)
        let repo = FileMacroRepository(url: url)
        await #expect(throws: MacroRepositoryError.self) { try await repo.load() }
        try await repo.save(MacroLibrary(macros: [Macro(name: "a", steps: [.text("x")])]))
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(names.contains { $0.hasPrefix("macros.json.corrupt-") } && names.contains("macros.json"))
    }

    @Test func versionFutureRefusee() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version": 99, "macros": []}"#.utf8).write(to: url)
        await #expect(throws: MacroRepositoryError.unsupportedVersion(found: 99, supported: 1)) { try await FileMacroRepository(url: url).load() }
    }

    @Test func emplacementACoteDeLaBibliotheque() {
        let u = FileMacroRepository.url(besideLibrary: URL(fileURLWithPath: "/x/Escale/library.json"))
        #expect(u.path == "/x/Escale/macros.json")
    }
}

@Suite("Macros : variables {host}/{user}/{name}")
struct MacroVariablesTests {
    private let host = HostProfile(name: "web 1", host: "10.0.0.1", user: "bob")

    @Test func substitutionParHote() {
        let m = Macro(name: "m", steps: [.text("ssh {user}@{host}\necho {name}\n"), .wait(milliseconds: 5), .key(.tab)])
        let a = MacroPlayback.actions(for: m, values: MacroPlayback.values(for: host))
        #expect(a == [.send(Data("ssh bob@10.0.0.1\recho 'web 1'\r".utf8)), .wait(milliseconds: 5), .send(Data([0x09]))])
    }

    @Test func terminalLocal() {
        let v = MacroPlayback.localValues(user: "rayan")
        #expect(v == ["host": "localhost", "user": "rayan", "name": "Terminal local"])
        #expect(MacroPlayback.values(for: nil)["host"] == "localhost")
        let m = Macro(name: "m", steps: [.text("echo {name} {host} {user}")])
        #expect(MacroPlayback.actions(for: m, values: v) == [.send(Data("echo 'Terminal local' localhost rayan".utf8))])
    }

    @Test func macroSansVariableIdentique() {
        let none = Macro(name: "n", steps: [.text("echo ${HOME} {1..3} {x} a } { b\n")])
        #expect(MacroPlayback.actions(for: none, values: MacroPlayback.values(for: host)) == MacroPlayback.actions(for: none))
        // Pas d'échappement `{{` : l'accolade initiale reste, `{host}` est remplacé.
        let m = Macro(name: "m", steps: [.text("{{host}")])
        #expect(MacroPlayback.actions(for: m, values: MacroPlayback.values(for: host)) == [.send(Data("{10.0.0.1".utf8))])
    }

    @Test func injectionEtUnSeulPassage() {
        let evil = HostProfile(name: "{user}'; touch x #", host: "h", user: "u")
        let expected = "'{user}'\\''; touch x #'"
        #expect(GroupExecTemplate.expand("{name}", host: evil) == expected)
        let m = Macro(name: "m", steps: [.text("{name}")])
        #expect(MacroPlayback.actions(for: m, values: MacroPlayback.values(for: evil)) == [.send(Data(expected.utf8))])
    }

    @Test func lectureAvecValeurs() async {
        let log = Log()
        let m = Macro(name: "m", steps: [.text("echo {host}\n")])
        let n = await MacroPlayback.play(m, values: MacroPlayback.values(for: host), send: { log.add(String(decoding: $0, as: UTF8.self)) }, sleep: { _ in })
        #expect(n == 1 && log.lines == ["echo 10.0.0.1\r"])
    }
}
