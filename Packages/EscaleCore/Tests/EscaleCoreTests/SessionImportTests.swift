import Foundation
import Testing
@testable import EscaleCore

/// Tests des importeurs de sessions (M5). Fixtures écrites à la main dans `scripts/fixtures/import/` (UTF-8) ;
/// les tests produisent eux-mêmes les encodages Windows (Windows-1252, UTF-16LE avec BOM).
@Suite struct SessionImportTests {
    private static func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/fixtures/import/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func cp1252(_ s: String) -> Data { s.data(using: .windowsCP1252)! }
    private static func utf16le(_ s: String) -> Data { Data([0xFF, 0xFE]) + s.data(using: .utf16LittleEndian)! }

    // MARK: Décodage

    @Test func decoderHandlesBOMsAndLegacyEncodings() {
        #expect(ImportTextDecoder.decode(Data([0xEF, 0xBB, 0xBF]) + Data("é€".utf8)) == "é€")
        #expect(ImportTextDecoder.decode(Self.utf16le("é€ ok")) == "é€ ok")
        #expect(ImportTextDecoder.decode(Self.cp1252("é€")) == "é€")
        #expect(ImportTextDecoder.decode(Data("été".utf8)) == "été")
        // UTF-16LE sans BOM.
        #expect(ImportTextDecoder.decode("[a]".data(using: .utf16LittleEndian)!) == "[a]")
    }

    // MARK: MobaXterm

    @Test func mobaXterm() throws {
        let r = MobaXtermImporter().parse(data: Self.cp1252(try Self.fixture("moba.mxtsessions")))
        let byName = Dictionary(uniqueKeysWithValues: r.sessions.map { ($0.name, $0) })
        #expect(r.sessions.count == 4) // le Telnet est ignoré

        let nas = try #require(byName["Maison NAS"])
        #expect(nas.host == "nas.local" && nas.port == nil && nas.user == nil && nas.folderPath.isEmpty && !nas.x11Forwarding)

        let web = try #require(byName["Web prod é €"])
        #expect(web.host == "web1.example.com" && web.user == "deploy" && web.folderPath == ["Production"])
        #expect(web.x11Forwarding)
        #expect(web.jumpHosts == ["jump@bastion.example.com:2200"])
        #expect(web.auth == .openSSHDefaults)

        let db = try #require(byName["DB réplica"])
        #expect(db.port == 2222 && db.user == "postgres" && db.folderPath == ["Production", "Base de données"])
        #expect(db.auth == .keyFile(path: "/Users/rayan/.ssh/id_ed25519"))

        // Avertissements : .ppk et Telnet ; mots de passe : champ 4 + [Passwords], jamais repris.
        #expect(r.warnings.contains { $0.contains(".ppk") && $0.contains("Web prod") })
        #expect(r.warnings.contains { $0.contains("Switch coeur") })
        #expect(r.ignoredPasswordCount == 2)
        #expect(r.passwordNotice == "2 mots de passe non importés")
        #expect(!String(describing: r).contains("s3cret") && !String(describing: r).contains("encrypted"))
    }

    @Test func mobaXtermIniIgnoresOtherSections() {
        let ini = """
        [Misc]
        Foo=bar
        [Bookmarks]
        SubRep=
        ImgNum=42
        a=#109#0%h.example.com%22%u%%-1%-1%%%%%0%0%0%%%-1#MobaFont%10#0# #-1
        [Passwords]
        [LastSession]
        x=#109#0%ignored%22%u%%
        """
        let r = MobaXtermImporter().parse(text: ini)
        #expect(r.sessions.map(\.host) == ["h.example.com"])
    }

    @Test func mobaXtermExecuteCommand() throws {
        let r = MobaXtermImporter().parse(data: Self.cp1252(try Self.fixture("moba.mxtsessions")))
        let byName = Dictionary(uniqueKeysWithValues: r.sessions.map { ($0.name, $0) })
        #expect(byName["Maison NAS"]?.startupCommand == "uptime; df -h") // __PTVIRG__ → ;
        #expect(byName["DB réplica"]?.startupCommand == "cd /var/lib/postgresql; exec bash -l")
        #expect(byName["Web prod é €"]?.startupCommand == nil)
    }

    @Test func mobaXtermIniTunnelsAndCommand() throws {
        let r = MobaXtermImporter().parse(data: Data(try Self.fixture("MobaXterm.ini").utf8))
        #expect(r.sessions.count == 1)
        let s = try #require(r.sessions.first)
        #expect(s.name == "Bastion DB" && s.host == "db.internal.example" && s.port == 2200 && s.user == "dba")
        #expect(s.startupCommand == "sudo -iu postgres; psql -c 'select 1%'") // __PTVIRG__ et __PERCENT__
        // 3 tunnels rattachés (hôte insensible à la casse, utilisateur absent accepté) ; « Orphelin » et « Cassé » signalés.
        #expect(s.tunnels.count == 3)
        #expect(s.tunnels[0].kind == .local && s.tunnels[0].bindPort == 15432 && s.tunnels[0].destinationHost == "localhost"
                && s.tunnels[0].destinationPort == 5432 && s.tunnels[0].bindAddress == "127.0.0.1")
        #expect(s.tunnels[1].kind == .dynamic && s.tunnels[1].bindPort == 1080)
        #expect(s.tunnels[2].kind == .remote && s.tunnels[2].bindPort == 8443 && s.tunnels[2].destinationPort == 443)
        #expect(r.warnings.contains { $0.contains("Orphelin") && $0.contains("inconnu.example") })
        #expect(r.warnings.contains { $0.contains("Cassé") })
        // La section [LastSession] et [Passwords] ne produisent aucune session ; mot de passe compté, jamais repris.
        #expect(r.ignoredPasswordCount == 1 && !String(describing: r).contains("ZmFrZWVuY3J5cHRlZA"))
    }

    @Test func mobaXtermTunnelFormats() {
        #expect(MobaXtermImporter.parseTunnel("#0#L%80%h%81%s%22%u")?.spec.kind == .local)
        #expect(MobaXtermImporter.parseTunnel("2%1080%%%s%22%u")?.spec.kind == .dynamic)
        #expect(MobaXtermImporter.parseTunnel("0%0%h%81%s%22%u") == nil)       // port d'écoute invalide
        #expect(MobaXtermImporter.parseTunnel("0%80%%81%s%22%u") == nil)       // destination vide (local)
        #expect(MobaXtermImporter.parseTunnel("0%80%h%81") == nil)             // trop court
    }

    // MARK: PuTTY

    @Test func puttyReg() throws {
        let r = PuTTYRegImporter().parse(data: Self.utf16le(try Self.fixture("putty.reg")))
        let byName = Dictionary(uniqueKeysWithValues: r.sessions.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["Serveur Web été", "DB", "Derriere proxy"]) // Default Settings et Telnet ignorés

        let web = try #require(byName["Serveur Web été"])
        #expect(web.host == "web.example.com" && web.port == nil && web.user == "deploy" && web.x11Forwarding)
        #expect(web.auth == .openSSHDefaults)
        #expect(r.warnings.contains { $0.contains("web.ppk") })
        #expect(web.tunnels.count == 4)
        #expect(web.tunnels[0] == TunnelSpec(id: web.tunnels[0].id, kind: .local, bindAddress: "127.0.0.1", bindPort: 8080,
                                             destinationHost: "localhost", destinationPort: 80))
        #expect(web.tunnels[1].kind == .remote && web.tunnels[1].bindPort == 2222 && web.tunnels[1].destinationHost == "127.0.0.1")
        #expect(web.tunnels[2].kind == .dynamic && web.tunnels[2].bindPort == 1080)
        #expect(web.tunnels[3].bindAddress == "127.0.0.1" && web.tunnels[3].destinationHost == "db.internal"
                && web.tunnels[3].destinationPort == 5432)

        let db = try #require(byName["DB"])
        #expect(db.host == "10.0.0.5" && db.user == "admin" && db.port == 2222 && db.folderPath == ["Prod"])
        #expect(r.warnings.contains { $0.contains("telnet") })
        #expect(r.ignoredPasswordCount == 1)
        #expect(!String(describing: r).contains("hunter2"))
    }

    @Test func puttyRegUTF8AndEscapes() {
        let reg = """
        REGEDIT4

        [HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\a]
        "HostName"="h.example.com"
        "PublicKeyFile"="/Users/me/.ssh/id_rsa"
        "PortForwardings"="L[::1]:9000=[fe80::1]:80,Zbad"
        """
        let r = PuTTYRegImporter().parse(text: reg)
        #expect(r.sessions.count == 1)
        #expect(r.sessions[0].auth == .keyFile(path: "/Users/me/.ssh/id_rsa"))
        #expect(r.sessions[0].tunnels.first?.bindAddress == "::1")
        #expect(r.sessions[0].tunnels.first?.destinationHost == "fe80::1")
        #expect(r.warnings.contains { $0.contains("Zbad") })
        #expect(PuTTYRegImporter.value(#""K"="a\\b\"c""#)?.1 == #"a\b"c"#)
        #expect(PuTTYRegImporter.value(#""P"=dword:0000ffff"#)?.1 == "65535")
    }

    // MARK: CSV

    @Test func csv() throws {
        let r = CSVSessionImporter().parse(data: Data(try Self.fixture("hosts.csv").utf8))
        #expect(r.sessions.count == 5)
        let web = r.sessions[0]
        #expect(web.name == "Web 1" && web.port == nil && web.user == "deploy")
        #expect(web.folderPath == ["Production", "Web"] && web.tags == ["web", "prod"])
        let cafe = r.sessions[1]
        #expect(cafe.name == "Café Müller" && cafe.port == 2222 && cafe.user == "zoé")
        #expect(cafe.folderPath == ["Clients", "Café"] && cafe.tags == ["client", "vip"])
        #expect(r.sessions[2].name == "bare.example.com")
        #expect(r.sessions[3].port == nil)
        #expect(r.warnings.contains { $0.contains("Ligne 6") && $0.contains("abc") })
        #expect(r.ignoredPasswordCount == 1)
    }

    @Test func csvSemicolonQuotedNewlinesAndCP1252() {
        let text = "Nom;Hôte;Port;Tags\r\n\"Ligne\nmultiple \"\"x\"\"\";h.example.com;2200;a,b|c\r\n"
        let r = CSVSessionImporter().parse(data: Self.cp1252(text))
        #expect(r.sessions.count == 1)
        #expect(r.sessions[0].name == "Ligne\nmultiple \"x\"" && r.sessions[0].port == 2200)
        #expect(r.sessions[0].tags == ["a", "b", "c"])
        #expect(CSVSessionImporter().parse(text: "a,b\n1,2").warnings.count == 1) // pas de colonne host
        #expect(CSVSessionImporter().parse(text: "").sessions.isEmpty)
    }

    // MARK: Fusion

    @Test func mergeDedupesAndMapsFolders() throws {
        var lib = HostLibrary()
        let prod = try lib.addFolder(name: "production") // existe déjà (casse différente)
        try lib.addHost(HostProfile(name: "existant", host: "WEB1.example.com", user: "deploy"))
        let r = CSVSessionImporter().parse(text: try Self.fixture("hosts.csv"))
        let existing = SessionImportMerge.existingIDs(r.sessions, comparedTo: lib)
        #expect(existing.count == 2) // « Web 1 » et « Web 1 bis »

        let target = try lib.addFolder(name: "Import")
        let rep = SessionImportMerge.merge(r.sessions, into: &lib, folderID: target.id)
        #expect(rep.added.map(\.name) == ["Café Müller", "bare.example.com", "Port cassé"])
        #expect(rep.skippedDuplicates == 2)
        // Les dossiers d'origine sont recréés SOUS le dossier cible ; celui de la racine « production » n'est pas touché.
        let cafe = try #require(rep.added.first)
        #expect(lib.folderPath(of: try #require(cafe.folderID)).map(\.name) == ["Import", "Clients", "Café"])
        #expect(lib.folders.contains { $0.id == prod.id })
        // Réimport : plus rien d'ajouté.
        let again = SessionImportMerge.merge(r.sessions, into: &lib, folderID: target.id)
        #expect(again.added.isEmpty && again.createdFolders.isEmpty)

        var flat = HostLibrary()
        SessionImportMerge.merge(r.sessions, into: &flat, keepFolders: false)
        #expect(flat.folders.isEmpty && flat.hosts.allSatisfy { $0.folderID == nil })
    }

    @Test func mergeReusesExistingFolderCaseInsensitively() throws {
        var lib = HostLibrary()
        let prod = try lib.addFolder(name: "Production")
        let s = ImportedSession(name: "x", host: "x.example.com", folderPath: ["production", "Web"])
        let rep = SessionImportMerge.merge([s], into: &lib)
        #expect(rep.createdFolders.map(\.name) == ["Web"] && rep.createdFolders[0].parentID == prod.id)
    }

    @Test func importedProfileCarriesTunnelsAndX11() {
        var lib = HostLibrary()
        let s = ImportedSession(name: "t", host: "h", port: 2200, user: "u", jumpHosts: ["j@b:22"],
                                tunnels: [TunnelSpec(kind: .dynamic, bindPort: 1080)], x11Forwarding: true)
        SessionImportMerge.merge([s], into: &lib)
        let h = lib.hosts[0]
        #expect(h.tunnels.count == 1 && h.x11Forwarding && h.jumpHosts == ["j@b:22"] && h.port == 2200)
        if case .keychainPassword = h.auth { Issue.record("aucun secret ne doit être importé") }
    }

    @Test func puttyRemoteCommandAndSSHProxy() throws {
        let r = PuTTYRegImporter().parse(data: Self.utf16le(try Self.fixture("putty.reg")))
        let byName = Dictionary(uniqueKeysWithValues: r.sessions.map { ($0.name, $0) })
        #expect(byName["Serveur Web été"]?.startupCommand == "tmux attach || tmux new -s main")
        // ProxyMethod 6 + ProxyHost = nom d'une autre session du fichier → hôte/port de celle-ci, utilisateur du proxy.
        #expect(byName["Derriere proxy"]?.jumpHosts == ["jump@10.0.0.5:2222"])
        #expect(byName["DB"]?.jumpHosts == [] && byName["DB"]?.startupCommand == nil)
    }

    @Test func puttyOtherProxiesWarn() {
        func reg(_ extra: String) -> String {
            "Windows Registry Editor Version 5.00\n\n[HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\s]\n\"HostName\"=\"h.example\"\n" + extra
        }
        let socks = PuTTYRegImporter().parse(text: reg("\"ProxyMethod\"=dword:00000002\n\"ProxyHost\"=\"p\"\n"))
        #expect(socks.sessions.first?.jumpHosts == [] && socks.warnings.contains { $0.contains("SOCKS5") })
        let exec = PuTTYRegImporter().parse(text: reg("\"ProxyMethod\"=dword:00000007\n\"ProxyHost\"=\"p\"\n"))
        #expect(exec.sessions.first?.jumpHosts == [] && exec.warnings.contains { $0.contains("sans équivalent") })
        let direct = PuTTYRegImporter().parse(text: reg("\"ProxyMethod\"=dword:00000006\n\"ProxyHost\"=\"bastion.example\"\n\"ProxyPort\"=dword:000008a0\n"))
        #expect(direct.sessions.first?.jumpHosts == ["bastion.example:2208"])
        let none = PuTTYRegImporter().parse(text: reg("\"ProxyMethod\"=dword:00000000\n"))
        #expect(none.sessions.first?.jumpHosts == [] && none.warnings.isEmpty)
    }

    @Test func startupCommandRules() {
        #expect(StartupCommand.normalized("  ls -l  ") == "ls -l")
        #expect(StartupCommand.normalized("a\nb") == nil && StartupCommand.normalized("   ") == nil && StartupCommand.normalized(nil) == nil)
        #expect(StartupCommand.input(for: "ls") == Data("ls\r".utf8))
        #expect(StartupCommand.validationMessage("a\nb") != nil && StartupCommand.validationMessage("ls") == nil)
    }

    @Test func startupCommandSurvivesProfileAndMerge() throws {
        var lib = HostLibrary()
        SessionImportMerge.merge([ImportedSession(name: "n", host: "h", startupCommand: "uptime")], into: &lib)
        #expect(lib.hosts.first?.startupCommand == "uptime")
        let data = try JSONEncoder().encode(lib.hosts[0])
        #expect(try JSONDecoder().decode(HostProfile.self, from: data).startupCommand == "uptime")
        let old = #"{"id":"6F1D1B8E-3A74-4C55-9E0B-1A2B3C4D5E6F","name":"a","host":"h"}"#
        #expect(try JSONDecoder().decode(HostProfile.self, from: Data(old.utf8)).startupCommand == nil)
    }
}
