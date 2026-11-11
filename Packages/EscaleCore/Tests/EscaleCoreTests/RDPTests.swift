import Foundation
import Testing
@testable import EscaleCore

@Suite("RDP : fichier .rdp")
struct RDPFileTests {
    private func host(_ h: String = "srv.example.com", port: Int? = nil, user: String? = "alice") -> HostProfile {
        HostProfile(name: "Serveur", host: h, port: port, user: user, connectionProtocol: .rdp, rdp: RDPSettings())
    }
    private func lines(_ s: String) -> [String] { s.components(separatedBy: "\r\n").filter { !$0.isEmpty } }

    @Test func generationParDefaut() throws {
        let l = lines(try RDPFile.generate(host: host()))
        #expect(l == ["full address:s:srv.example.com:3389", "username:s:alice", "prompt for credentials:i:1",
                      "screen mode id:i:2", "use multimon:i:0", "redirectclipboard:i:1", "audiomode:i:0"])
    }

    @Test func fenetreTailleFixeEtOptions() throws {
        var s = RDPSettings(displayMode: .fixedSize, width: 1280, height: 720, multiMonitor: true, redirectClipboard: false,
                            audio: .none, sharedFolders: ["/Users/a/Docs", "/Volumes/Data"], gatewayHostname: "gw.example.com")
        s.promptForCredentials = false
        let l = lines(try RDPFile.generate(host: host(port: 3390), settings: s))
        #expect(l.contains("full address:s:srv.example.com:3390"))
        #expect(l.contains("screen mode id:i:1") && l.contains("desktopwidth:i:1280") && l.contains("desktopheight:i:720"))
        #expect(l.contains("dynamic resolution:i:0") && l.contains("use multimon:i:1") && l.contains("redirectclipboard:i:0"))
        #expect(l.contains("audiomode:i:2") && l.contains("prompt for credentials:i:0"))
        #expect(l.contains("drivestoredirect:s:/Users/a/Docs;/Volumes/Data"))
        #expect(l.contains("gatewayhostname:s:gw.example.com") && l.contains("gatewayusagemethod:i:1"))
    }

    @Test func adresseSurchargeEtIPv6() throws {
        let t = try RDPFile.generate(host: host(), address: ("127.0.0.1", 51234))
        #expect(lines(t).first == "full address:s:127.0.0.1:51234")
        #expect(lines(try RDPFile.generate(host: host("fe80::1"))).first == "full address:s:[fe80::1]:3389")
        #expect(lines(try RDPFile.generate(host: host("[fe80::1]"), address: nil)).first == "full address:s:[fe80::1]:3389")
    }

    @Test func aucunMotDePasse() throws {
        let t = try RDPFile.generate(host: host())
        #expect(!t.lowercased().contains("password"))
    }

    @Test func injectionRefusee() {
        #expect(throws: RDPFileError.self) {
            try RDPFile.generate(host: host(user: "bob\r\ndrivestoredirect:s:*"))
        }
        #expect(throws: RDPFileError.self) { try RDPFile.generate(host: host("srv\nfull address:s:evil")) }
        #expect(throws: RDPFileError.self) { try RDPFile.generate(host: host("a b")) }
        #expect(throws: RDPFileError.self) { try RDPFile.generate(host: host("a;b")) }
        let bad = RDPSettings(sharedFolders: ["/tmp/x\ndrivestoredirect:s:*"])
        #expect(throws: RDPFileError.self) { try RDPFile.generate(host: host(), settings: bad) }
        #expect(throws: RDPFileError.self) { try RDPFile.generate(host: host(), settings: RDPSettings(sharedFolders: ["/a;/b"])) }
        #expect(throws: RDPFileError.self) { try RDPFile.generate(host: host(port: 70000)) }
        // Séparateur de ligne Unicode.
        #expect(throws: RDPFileError.self) { try RDPFile.generate(host: host(user: "x\u{2028}y")) }
    }

    @Test func allerRetour() throws {
        let s = RDPSettings(displayMode: .fixedSize, width: 1024, height: 768, multiMonitor: true, redirectClipboard: false,
                            audio: .remote, sharedFolders: ["/Users/a/Docs"], gatewayHostname: "gw.example.com", promptForCredentials: false)
        let h = HostProfile(name: "x", host: "10.1.2.3", port: 4000, user: "CORP\\bob", connectionProtocol: .rdp, rdp: s)
        let back = try RDPFile.parse(try RDPFile.generate(host: h), name: "x")
        #expect(back.warnings.isEmpty)
        #expect(back.host.host == "10.1.2.3" && back.host.port == 4000 && back.host.user == "CORP\\bob")
        #expect(back.host.connectionProtocol == .rdp)
        #expect(back.host.rdp == s)
    }

    @Test func allerRetourFenetreEtPleinEcran() throws {
        for mode in [RDPSettings.DisplayMode.fullScreen, .window] {
            let h = host()
            var s = RDPSettings(); s.displayMode = mode
            let back = try RDPFile.parse(try RDPFile.generate(host: h, settings: s))
            #expect(back.host.rdp?.displayMode == mode)
        }
    }

    @Test func importFichierWindows() throws {
        let text = """
        screen mode id:i:2
        use multimon:i:1
        desktopwidth:i:1920
        desktopheight:i:1080
        session bpp:i:32
        full address:s:[2001:db8::5]:3390
        username:s:admin
        password 51:b:01000000D08C9DDF0115D1118C7A00C04FC297EB
        drivestoredirect:s:*
        audiomode:i:1
        unknown key:i:5
        """
        let r = try RDPFile.parse(text, name: "Bureau")
        #expect(r.host.name == "Bureau" && r.host.host == "2001:db8::5" && r.host.port == 3390 && r.host.user == "admin")
        #expect(r.host.rdp?.displayMode == .fullScreen && r.host.rdp?.multiMonitor == true && r.host.rdp?.audio == .remote)
        #expect(r.host.rdp?.sharedFolders == [])
        #expect(r.warnings.count == 2)
        #expect(r.warnings.contains { $0.contains("Mot de passe") })
        // Le mot de passe n'est nulle part dans le profil.
        let json = String(decoding: try JSONEncoder().encode(r.host), as: UTF8.self)
        #expect(!json.contains("D08C9DDF"))
    }

    @Test func importSansPortEtSansAdresse() throws {
        #expect(try RDPFile.parse("full address:s:srv\r\n").host.port == nil)
        #expect(try RDPFile.parse("full address:s:srv:3389\r\n").host.port == nil)
        #expect(throws: RDPFileError.missingAddress) { try RDPFile.parse("username:s:x") }
        #expect(throws: RDPFileError.self) { try RDPFile.parse("full address:s:srv:99999") }
        #expect(throws: RDPFileError.self) { try RDPFile.parse("full address:s:bad host") }
    }

    @Test func decodageUTF16EtBOM() throws {
        let text = "full address:s:srv.example.com\r\nusername:s:é\r\n"
        var u16 = Data([0xFF, 0xFE]); u16.append(text.data(using: .utf16LittleEndian)!)
        #expect(try RDPFile.parse(try RDPFile.decode(u16)).host.user == "é")
        var u8 = Data([0xEF, 0xBB, 0xBF]); u8.append(Data(text.utf8))
        #expect(try RDPFile.parse(try RDPFile.decode(u8)).host.host == "srv.example.com")
        #expect(throws: RDPFileError.tooLarge) { try RDPFile.decode(Data(count: RDPFile.maxImportSize + 1)) }
        #expect(throws: RDPFileError.notText) { try RDPFile.decode(Data([0xC3, 0x28])) }
    }

    @Test func nomDeFichierSur() {
        #expect(RDPFile.fileName(for: HostProfile(name: "../../etc/passwd", host: "x")) == "_.._etc_passwd.rdp"
                || !RDPFile.fileName(for: HostProfile(name: "../../etc/passwd", host: "x")).contains("/"))
        #expect(RDPFile.fileName(for: HostProfile(name: "///", host: "x")) == "___.rdp")
        #expect(RDPFile.fileName(for: HostProfile(name: "", host: "x")) == "hote.rdp")
        #expect(RDPFile.fileName(for: HostProfile(name: "Serveur é", host: "x")) == "Serveur é.rdp")
    }

    @Test func dossierPriveEtFichier0600() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("rdp-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let dir = try RDPFile.makePrivateDirectory(under: parent)
        let url = try RDPFile.write("x", named: "a.rdp", in: dir)
        func mode(_ u: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.posixPermissions] as? Int) ?? -1 }
        #expect(mode(dir) == 0o700 && mode(url) == 0o600)
    }
}

@Suite("RDP : réglages, client, tunnel")
struct RDPSettingsTests {
    @Test func decodageToleranteDeVide() throws {
        let s = try JSONDecoder().decode(RDPSettings.self, from: Data("{}".utf8))
        #expect(s == RDPSettings())
        #expect(s.displayMode == .fullScreen && s.redirectClipboard && s.promptForCredentials && s.viaSSHHostID == nil)
    }

    @Test func valeursInconnuesRetombentSurLeDefaut() throws {
        let s = try JSONDecoder().decode(RDPSettings.self, from: Data(#"{"displayMode":"hologramme","audio":"x","width":800}"#.utf8))
        #expect(s.displayMode == .fullScreen && s.audio == .local && s.width == 800)
    }

    @Test func allerRetourJSON() throws {
        let s = RDPSettings(displayMode: .window, multiMonitor: true, sharedFolders: ["/a"], viaSSHHostID: UUID())
        #expect(try JSONDecoder().decode(RDPSettings.self, from: JSONEncoder().encode(s)) == s)
    }

    @Test func validation() {
        #expect(RDPSettings.validationErrors(RDPSettings()).isEmpty)
        #expect(RDPSettings.validationErrors(RDPSettings(displayMode: .fixedSize, width: 10, height: 600)).count == 1)
        #expect(RDPSettings.validationErrors(RDPSettings(width: 10)).isEmpty) // taille ignorée hors « taille fixe »
        #expect(RDPSettings.validationErrors(RDPSettings(sharedFolders: ["relatif"])).count == 1)
        #expect(RDPSettings.validationErrors(RDPSettings(gatewayHostname: "bad host")).count == 1)
        #expect(RDPSettings.validationErrors(RDPSettings(gatewayHostname: "gw.example.com", viaSSHHostID: UUID())).count == 1)
    }

    @Test func clientAbsentOuPresent() {
        let recorded = Box()
        let absent = RDPClientLocator { _ in [] }
        #expect(absent.locate() == nil)
        let app = URL(fileURLWithPath: "/Applications/Windows App.app")
        let present = RDPClientLocator { id in recorded.set(id); return [app] }
        #expect(present.locate() == app && recorded.value == "com.microsoft.rdc.macos")
        #expect(RDPClientLocator.appStoreURL.absoluteString == "https://apps.apple.com/app/windows-app/id1295203466")
    }

    @Test func tunnelSpecEtPortLibre() throws {
        let port = try #require(RDPTunnel.freeLocalPort())
        #expect((1024...65535).contains(port))
        let spec = RDPTunnel.spec(localPort: port, host: "[fe80::1]", port: 3389)
        #expect(spec.kind == .local && spec.bindAddress == "127.0.0.1" && spec.bindPort == port)
        #expect(spec.destinationHost == "fe80::1" && spec.destinationPort == 3389)
        #expect(TunnelValidation.errors(spec).isEmpty)
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock(); private var v: String?
        func set(_ s: String) { lock.lock(); v = s; lock.unlock() }
        var value: String? { lock.lock(); defer { lock.unlock() }; return v }
    }
}
