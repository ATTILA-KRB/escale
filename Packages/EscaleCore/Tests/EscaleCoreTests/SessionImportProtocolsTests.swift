import Foundation
import Testing
@testable import EscaleCore

/// Import MobaXterm / PuTTY / Termius vers Telnet, série, VNC et RDP (fixtures `scripts/fixtures/import/`).
@Suite struct SessionImportProtocolsTests {
    private static func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/fixtures/import/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func byName(_ r: SessionImportResult) -> [String: ImportedSession] {
        Dictionary(uniqueKeysWithValues: r.sessions.map { ($0.name, $0) })
    }

    // MARK: MobaXterm

    @Test func mobaXtermProtocols() throws {
        let data = try Self.fixture("moba-protocols.mxtsessions").data(using: .windowsCP1252)!
        let r = MobaXtermImporter().parse(data: data)
        let s = Self.byName(r)
        #expect(r.sessions.count == 7)

        let t1 = try #require(s["Routeur Telnet"])
        #expect(t1.connectionProtocol == .telnet && t1.host == "10.1.1.1" && t1.port == nil && t1.user == nil)
        let t2 = try #require(s["Telnet port custom"])
        #expect(t2.host == "10.1.1.2" && t2.port == 2323 && t2.user == "ops")

        let rdp = try #require(s["Bureau Windows"])
        #expect(rdp.connectionProtocol == .rdp && rdp.host == "win.example.com" && rdp.port == 3390 && rdp.user == "administrateur")
        let rdp2 = try #require(s["Bureau defaut"])
        #expect(rdp2.port == nil && rdp2.user == nil) // 3389 = défaut, <default> = utilisateur de l'app

        let vnc = try #require(s["Ecran VNC"])
        #expect(vnc.connectionProtocol == .vnc && vnc.host == "vnc.example.com" && vnc.port == 5901 && vnc.user == nil)
        #expect(r.warnings.contains { $0.contains("Ecran VNC") && $0.contains("gw.example.com") })

        // Série : COMx → pas de périphérique + avertissement ; /dev/… repris ; débit = code − 1 000 000.
        let com = try #require(s["Console COM"])
        #expect(com.connectionProtocol == .serial && com.host == "" && com.serial?.devicePath == "" && com.serial?.baudRate == 115_200)
        #expect(r.warnings.contains { $0.contains("Console COM") && $0.contains("COM9 (USB Serial Port (COM9))") && $0.contains("choisir le port") })
        let dev = try #require(s["Console 9600"])
        #expect(dev.host == "/dev/ttyUSB0" && dev.serial?.devicePath == "/dev/ttyUSB0" && dev.serial?.baudRate == 9_600)

        // FTP et Mosh restent ignorés, avec avertissement.
        #expect(s["Partage FTP"] == nil && s["Mosh"] == nil)
        #expect(r.warnings.contains { $0.contains("Partage FTP") && $0.contains("ignoré") })
        #expect(r.warnings.contains { $0.contains("Mosh") && $0.contains("ignoré") })
    }

    @Test func mobaXtermProtocolsBecomeProfiles() throws {
        let r = MobaXtermImporter().parse(data: try Self.fixture("moba-protocols.mxtsessions").data(using: .windowsCP1252)!)
        var lib = HostLibrary()
        let rep = SessionImportMerge.merge(r.sessions, into: &lib)
        #expect(rep.added.count == 7)
        let p = Dictionary(uniqueKeysWithValues: rep.added.map { ($0.name, $0) })
        #expect(p["Routeur Telnet"]?.telnet != nil && p["Routeur Telnet"]?.serial == nil)
        #expect(p["Bureau Windows"]?.rdp != nil && p["Ecran VNC"]?.vnc != nil)
        #expect(p["Console 9600"]?.serial?.baudRate == 9_600 && p["Console 9600"]?.connectionProtocol == .serial)
        // Deux séries sans périphérique ne se confondent pas ; un réimport ne duplique rien.
        #expect(SessionImportMerge.merge(r.sessions, into: &lib).added.isEmpty)
        let a = ImportedSession(name: "A", host: "", connectionProtocol: .serial, serial: SerialSettings())
        let b = ImportedSession(name: "B", host: "", connectionProtocol: .serial, serial: SerialSettings())
        #expect(a.identityKey != b.identityKey)
        // Un Telnet et un SSH du même hôte restent distincts.
        let ssh = ImportedSession(name: "s", host: "h.example.com")
        let tel = ImportedSession(name: "t", host: "h.example.com", connectionProtocol: .telnet)
        #expect(ssh.identityKey != tel.identityKey)
    }

    // MARK: PuTTY

    @Test func puttyProtocols() throws {
        let data = Data([0xFF, 0xFE]) + (try Self.fixture("putty-protocols.reg")).data(using: .utf16LittleEndian)!
        let r = PuTTYRegImporter().parse(data: data)
        let s = Self.byName(r)
        #expect(Set(s.keys) == ["Routeur Telnet", "Telnet autre port", "Console Windows", "Console Mac"])

        let t1 = try #require(s["Routeur Telnet"])
        #expect(t1.connectionProtocol == .telnet && t1.host == "192.168.1.1" && t1.port == nil && t1.user == "admin" && t1.folderPath == ["Labo"])
        #expect(s["Telnet autre port"]?.port == 2586 && s["Telnet autre port"]?.user == nil)

        let win = try #require(s["Console Windows"])
        #expect(win.connectionProtocol == .serial && win.host == "")
        #expect(win.serial == SerialSettings(devicePath: "", baudRate: 115_200, dataBits: 7, parity: .even, stopBits: 2, flowControl: .hardware))
        #expect(r.warnings.contains { $0.contains("Console Windows") && $0.contains("COM3") && $0.contains("choisir le port") })

        let mac = try #require(s["Console Mac"])
        #expect(mac.host == "/dev/cu.usbserial-1410" && mac.folderPath == ["Labo"])
        #expect(mac.serial == SerialSettings(devicePath: "/dev/cu.usbserial-1410", baudRate: 9_600, dataBits: 8, parity: .none, stopBits: 1, flowControl: .hardware))
        #expect(r.warnings.contains { $0.contains("Console Mac") && $0.contains("1,5 bit") })
        #expect(r.warnings.contains { $0.contains("Console Mac") && $0.contains("marque/espace") })
        #expect(r.warnings.contains { $0.contains("Console Mac") && $0.contains("DSR/DTR") })

        // raw et rlogin : toujours ignorés.
        #expect(r.warnings.contains { $0.contains("Flux brut") && $0.contains("raw") && $0.contains("ignoré") })
        #expect(r.warnings.contains { $0.contains("Ancien rlogin") && $0.contains("rlogin") && $0.contains("ignoré") })
    }

    @Test func puttySerialDefaultsWhenValuesAbsent() {
        let reg = """
        Windows Registry Editor Version 5.00

        [HKEY_CURRENT_USER\\Software\\SimonTatham\\PuTTY\\Sessions\\Vide]
        "Protocol"="serial"
        """
        let r = PuTTYRegImporter().parse(text: reg)
        #expect(r.sessions.first?.serial == SerialSettings())
    }

    // MARK: Termius

    @Test func termiusCSV() throws {
        let r = TermiusImporter().parse(text: try Self.fixture("termius.csv"))
        let s = Self.byName(r)
        #expect(r.sessions.count == 5)

        let web1 = try #require(s["web-01"])
        #expect(web1.host == "203.0.113.11" && web1.port == nil && web1.user == "deploy" && web1.connectionProtocol == .ssh)
        #expect(web1.folderPath == ["Production", "Web"] && web1.tags == ["prod", "nginx"])
        #expect(s["web-02"]?.port == 2222)

        let lab = try #require(s["Routeur labo"])
        #expect(lab.connectionProtocol == .telnet && lab.port == nil && lab.user == "admin" && lab.tags == ["lab", "reseau"])

        let mosh = try #require(s["Pi mosh"])
        #expect(mosh.connectionProtocol == .ssh && mosh.host == "raspberrypi.local")
        #expect(r.warnings.contains { $0.contains("Pi mosh") && $0.contains("Mosh") })

        let bare = try #require(s["sans-groupe"])
        #expect(bare.folderPath.isEmpty && bare.tags.isEmpty && bare.user == nil)

        // FTP ignoré, ligne sans hôte ignorée, ligne vide silencieuse ; le mot de passe est compté, jamais repris.
        #expect(s["Serveur FTP"] == nil)
        #expect(r.warnings.contains { $0.contains("Serveur FTP") && $0.contains("ftp") })
        #expect(r.warnings.contains { $0.contains("hôte vide") })
        #expect(r.ignoredPasswordCount == 1 && r.passwordNotice == "1 mot de passe non importé")
        #expect(!String(describing: r).contains("t3rm1us"))
    }

    @Test func termiusHeaderMissingAndAliases() {
        let none = TermiusImporter().parse(text: "Label,Port\nx,22\n")
        #expect(none.sessions.isEmpty && none.warnings.first?.contains("Hostname/IP") == true)
        let r = TermiusImporter().parse(text: "label;hostname/ip;protocol\nroute;10.0.0.1;TELNET\n")
        #expect(r.sessions.first?.connectionProtocol == .telnet && r.sessions.first?.name == "route")
    }
}
