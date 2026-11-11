import Foundation
import Testing
@testable import EscaleCore

@Suite("Telnet : négociation et saisie")
struct TelnetSessionTests {
    private func b(_ x: UInt8...) -> Data { Data(x) }

    @Test func offresInitialesDuClient() {
        var s = TelnetSession()
        #expect(s.start() == b(255, 251, 24, 255, 251, 31, 255, 253, 3, 255, 251, 3))
    }

    @Test func reponsesAuxOffresDuServeur() {
        var s = TelnetSession(columns: 100, rows: 30)
        _ = s.start()
        // Le serveur répond DO TTYPE, DO NAWS (attendus), WILL ECHO, DO SGA/WILL SGA (déjà demandés).
        let r1 = s.receive(b(255, 253, 24, 255, 253, 31, 255, 251, 1, 255, 253, 3, 255, 251, 3))
        // DO TTYPE accepte la demande en cours (aucune réponse), DO NAWS idem + sous-négociation NAWS, WILL ECHO → DO ECHO.
        #expect(r1.reply == b(255, 250, 31, 0, 100, 0, 30, 255, 240) + b(255, 253, 1))
        #expect(s.serverEchoes)
        #expect(s.nawsActive)
        // SEND → IS XTERM-256COLOR
        let r2 = s.receive(b(255, 250, 24, 1, 255, 240))
        #expect(r2.reply == b(255, 250, 24, 0) + Data("XTERM-256COLOR".utf8) + b(255, 240))
    }

    @Test func optionsInconnuesRefusees() {
        var s = TelnetSession()
        // DO LINEMODE(34) → WONT ; WILL STATUS(5) → DONT ; DO NEW-ENVIRON(39) → WONT.
        let r = s.receive(b(255, 253, 34, 255, 251, 5, 255, 253, 39))
        #expect(r.reply == b(255, 252, 34, 255, 254, 5, 255, 252, 39))
    }

    @Test func pasDeBoucleSurDemandesCroisees() {
        var s = TelnetSession()
        _ = s.start()
        // Le serveur redit DO/WILL pour ce qu'on a déjà obtenu : aucune réponse en écho (RFC 1143).
        _ = s.receive(b(255, 253, 24))
        #expect(s.receive(b(255, 253, 24)).reply.isEmpty)
        #expect(s.receive(b(255, 251, 3)).reply == Data()) // WILL SGA : réponse à notre DO SGA
        #expect(s.receive(b(255, 251, 3)).reply.isEmpty)
        // WONT d'une option jamais activée : ignoré.
        #expect(s.receive(b(255, 252, 1)).reply.isEmpty)
        // Un refus (DONT) de ce qu'on a proposé ne relance pas.
        #expect(s.receive(b(255, 254, 31)).reply.isEmpty)
        #expect(!s.nawsActive)
    }

    @Test func refusPuisRedemandeDuServeur() {
        var s = TelnetSession()
        #expect(s.receive(b(255, 251, 1)).reply == b(255, 253, 1))   // WILL ECHO → DO ECHO
        #expect(s.receive(b(255, 252, 1)).reply == b(255, 254, 1))   // WONT ECHO → DONT ECHO
        #expect(!s.serverEchoes)
    }

    @Test func resizeEnvoieNawsSeulementSiActive() {
        var s = TelnetSession(columns: 80, rows: 24)
        #expect(s.resize(columns: 90, rows: 40).isEmpty) // option pas encore négociée
        _ = s.receive(b(255, 253, 31))
        #expect(s.resize(columns: 120, rows: 40) == b(255, 250, 31, 0, 120, 0, 40, 255, 240))
        #expect(s.resize(columns: 120, rows: 40).isEmpty) // inchangé
        // 255 colonnes : l'octet 0xFF est dédoublé.
        #expect(s.resize(columns: 255, rows: 1) == b(255, 250, 31, 0, 255, 255, 0, 1, 255, 240))
    }

    @Test func saisieEchappeFF() {
        let s = TelnetSession()
        #expect(s.encodeInput(b(0x61, 0xff, 0x62)) == b(0x61, 0xff, 0xff, 0x62))
    }

    @Test func entreeSelonModeDeFinDeLigne() {
        var s = TelnetSession(lineEnding: .standard)
        #expect(s.encodeInput(b(0x0d)) == b(0x0d, 0x00))
        #expect(s.encodeInput(b(0x61, 0x0d, 0x0a)) == b(0x61, 0x0d, 0x0a)) // CR LF déjà complet
        s.lineEnding = .crlf
        #expect(s.encodeInput(b(0x0d)) == b(0x0d, 0x0a))
        s.lineEnding = .cr
        #expect(s.encodeInput(b(0x0d)) == b(0x0d))
    }

    @Test func modeBinaireSeulementDansLesDeuxSens() {
        var s = TelnetSession()
        // DO BINARY seul : on accepte (WILL) et on demande l'autre sens (DO) ; pas encore binaire.
        #expect(s.receive(b(255, 253, 0)).reply == b(255, 251, 0, 255, 253, 0))
        #expect(!s.isBinary)
        #expect(s.encodeInput(b(0x0d)) == b(0x0d, 0x00))
        // Le serveur accepte (WILL BINARY) : binaire dans les deux sens → CR sans NUL.
        #expect(s.receive(b(255, 251, 0)).reply.isEmpty)
        #expect(s.isBinary)
        #expect(s.encodeInput(b(0x0d)) == b(0x0d))
    }

    @Test func serveurQuiRefuseLAutreSensResteNonBinaire() {
        var s = TelnetSession()
        _ = s.receive(b(255, 253, 0))
        _ = s.receive(b(255, 252, 0)) // WONT BINARY : refus de l'autre sens
        #expect(!s.isBinary)
        #expect(s.encodeInput(b(0x0d)) == b(0x0d, 0x00))
    }

    @Test func affichageEtReponseMelanges() {
        var s = TelnetSession()
        let r = s.receive(b(0x68, 0x69) + b(255, 253, 99) + b(0x21))
        #expect(r.display == Data("hi!".utf8))
        #expect(r.reply == b(255, 252, 99))
    }

    @Test func reglagesDecodageTolerant() throws {
        let t = try JSONDecoder().decode(TelnetSettings.self, from: Data("{}".utf8))
        #expect(t == TelnetSettings())
        #expect(t.terminalType == "XTERM-256COLOR")
        let u = try JSONDecoder().decode(TelnetSettings.self, from: Data(#"{"lineEnding":"inconnu","terminalType":"vt100"}"#.utf8))
        #expect(u.lineEnding == .standard && u.terminalType == "vt100")
        #expect(TelnetSettings.validationErrors(TelnetSettings()).isEmpty)
        #expect(!TelnetSettings.validationErrors(TelnetSettings(terminalType: "a b")).isEmpty)
        #expect(!TelnetSettings.validationErrors(TelnetSettings(connectTimeout: 0)).isEmpty)
        // Aller-retour avec l'hôte SSH intermédiaire.
        let id = UUID()
        let back = try JSONDecoder().decode(TelnetSettings.self, from: JSONEncoder().encode(TelnetSettings(viaSSHHostID: id)))
        #expect(back.viaSSHHostID == id)
    }
}

@Suite("Telnet : tunnel via un hôte SSH")
struct TelnetTunnelTests {
    @Test func portLibreEtRedirection() throws {
        let p = try #require(TelnetTunnel.freeLocalPort())
        #expect((1024...65535).contains(p))
        // Pas de `TunnelPortCheck.isFree(p)` ici : le port éphémère rendu peut être repris aussitôt par un test
        // parallèle (échec intermittent). Le produit vérifie l'ouverture par sonde après `ssh -O forward` (invariant 4).
        let s = TelnetTunnel.spec(localPort: p, host: "[::1]", port: 23)
        #expect(s.kind == .local && s.bindAddress == "127.0.0.1" && s.bindPort == p)
        #expect(s.destinationHost == "::1" && s.destinationPort == 23)
        #expect(TunnelValidation.errors(s).isEmpty)
    }
}
