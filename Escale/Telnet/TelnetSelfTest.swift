import AppKit
import Foundation
import EscaleCore

/// Scénario `--selftest-telnet <dossier>` : écrit `<dossier>/result.json` (ok, checks, failed, details).
///
/// Contre `scripts/fixtures/telnet/server.py` (lancé par `scripts/selftest-telnet.sh`, qui fournit ESCALE_TELNETTEST_PORT,
/// ESCALE_TELNETTEST_LOG et, pour le trajet via SSH, un hôte « Relais SSH » dans la bibliothèque). Piloté par l'API interne
/// uniquement (pas d'événement clavier global, pas d'activation de l'app).
@MainActor
final class TelnetSelfTest {
    let directory: String
    let model: AppModel
    private var checks: [(String, Bool, String)] = []
    private var shots: [String] = []

    init(directory: String, model: AppModel) { self.directory = directory; self.model = model }

    // MARK: Aides

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        checks.append((name, ok, detail))
        FileHandle.standardError.write(Data("[selftest-telnet] \(ok ? "OK " : "KO ") \(name) \(detail)\n".utf8))
    }
    private func wait(_ timeout: Double = 10, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }
        return cond()
    }
    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
    private func text(_ p: Pane) -> String { p.session.engine.text(includingScrollback: true) }
    private func tail(_ s: String, _ n: Int = 300) -> String { String(s.suffix(n)) }
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    /// Journal du serveur de test, ligne par ligne.
    private var serverLog: [String] {
        guard let p = env["ESCALE_TELNETTEST_LOG"], let s = try? String(contentsOfFile: p, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").map(String.init)
    }
    /// Octets reçus par le serveur (tous les « DATA » mis bout à bout, en hexadécimal).
    private var receivedHex: String { serverLog.filter { $0.hasPrefix("DATA ") }.map { String($0.dropFirst(5)) }.joined() }
    private func nawsLines() -> [String] { serverLog.filter { $0.hasPrefix("NAWS ") }.map { String($0.dropFirst(5)) } }
    private func sizeText(_ p: Pane) -> String { let s = p.session.engine.size; return "\(s.columns)x\(s.rows)" }

    private func screenshot(_ name: String, window: NSWindow, pane: Pane) async {
        window.orderFrontRegardless()
        await sleep(0.5)
        for _ in 0..<3 {
            pane.session.engine.refreshDisplay()
            window.contentView?.needsDisplay = true
            window.displayIfNeeded()
            await sleep(0.4)
        }
        let path = "\(directory)/\(name).png"
        let pr = Process()
        pr.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        pr.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", path]
        try? pr.run(); pr.waitUntilExit()
        if FileManager.default.fileExists(atPath: path) { shots.append("\(name).png") }
    }

    private func telnetHost(_ name: String, port: Int, host: String = "127.0.0.1", settings: TelnetSettings = TelnetSettings()) -> HostProfile {
        HostProfile(name: name, host: host, port: port, connectionProtocol: .telnet, telnet: settings)
    }

    private func freeClosedPort() -> Int { TelnetTunnel.freeLocalPort() ?? 1 }

    // MARK: Scénario

    func run() async -> Bool {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        guard let portText = env["ESCALE_TELNETTEST_PORT"], let port = Int(portText), env["ESCALE_TELNETTEST_LOG"] != nil else {
            check("environnement_serveur_de_test", false, "ESCALE_TELNETTEST_PORT / ESCALE_TELNETTEST_LOG absents"); return finish()
        }
        guard await wait(15, { model.mainWindow != nil }), let win = model.mainWindow else {
            check("fenetre_principale", false); return finish()
        }
        win.orderFrontRegardless()
        model.connections.graceDelay = 0.5
        _ = await wait(10) { model.library.isLoaded }
        check("fenetre_principale", true)
        check("lanceur_telnet_enregistre", model.terminalLaunchers[.telnet] != nil)
        check("port_par_defaut_23", ConnectionProtocol.telnet.defaultPort == 23)

        // 1. Connexion directe : bannière, négociation, saisie.
        let tab1 = model.newTab(telnetHost("Telnet recette", port: port))
        let p1 = tab1.panes[0]
        check("a_connecte", await wait(15) { p1.status == .running }, "\(p1.status)")
        check("a_banniere_visible", await wait(10) { text(p1).contains("Escale Telnet test") && text(p1).contains("login:") }, tail(text(p1)))
        await screenshot("banniere", window: win, pane: p1)
        check("a_ttype_recu_par_le_serveur", await wait(10) { serverLog.contains("TTYPE XTERM-256COLOR") }, "\(serverLog)")
        check("a_naws_egal_taille_panneau", await wait(10) { nawsLines().last == sizeText(p1) && sizeText(p1) != "0x0" },
              "serveur \(nawsLines()) panneau \(sizeText(p1))")

        // Redimensionnement de la fenêtre -> NAWS mis à jour.
        let before = sizeText(p1)
        let f0 = win.frame
        win.setFrame(NSRect(x: f0.minX, y: f0.minY - 40, width: f0.width - 170, height: f0.height + 40), display: true)
        check("a_taille_change", await wait(10) { sizeText(p1) != before }, "\(before) -> \(sizeText(p1))")
        check("a_naws_mis_a_jour", await wait(10) { nawsLines().last == sizeText(p1) }, "serveur \(nawsLines()) panneau \(sizeText(p1))")
        win.setFrame(f0, display: true)
        check("a_naws_retour_taille_initiale", await wait(10) { nawsLines().last == sizeText(p1) && sizeText(p1) == before },
              "serveur \(nawsLines()) panneau \(sizeText(p1))")

        // Saisie : écho du serveur, CR NUL, 0xFF échappé.
        p1.session.engine.sendInput(Data("root\r".utf8))
        check("a_saisie_renvoyee_par_le_serveur", await wait(10) { text(p1).contains("Recu: root") }, tail(text(p1)))
        check("a_entree_en_cr_nul", receivedHex.contains("726f6f740d00"), receivedHex)
        p1.session.engine.sendInput(Data([0x61, 0xff, 0x62]))
        check("a_octet_ff_echappe_puis_deseechappe", await wait(10) { receivedHex.contains("61ff62") }, receivedHex)

        // Valide la ligne en cours (« ab » : le serveur ignore l'octet 0xff), puis fermeture côté serveur -> session terminée.
        p1.session.engine.sendInput(Data("\r".utf8))
        check("a_ligne_avec_ff_recue", await wait(10) { text(p1).contains("Recu: ab") }, tail(text(p1)))
        p1.session.engine.sendInput(Data("bye\r".utf8))
        check("a_fermeture_serveur_ended", await wait(10) { p1.status == .ended(.exited(0)) }, "\(p1.status)")
        check("a_message_de_fin_recu", text(p1).contains("Au revoir"), tail(text(p1)))
        check("a_serveur_a_ferme", serverLog.contains("CLOSE"), "\(serverLog.suffix(3))")
        model.close(tab1)

        // 2. Mode CR LF.
        let tab2 = model.newTab(telnetHost("Telnet CRLF", port: port, settings: TelnetSettings(lineEnding: .crlf)))
        let p2 = tab2.panes[0]
        check("b_connecte", await wait(15) { p2.status == .running && text(p2).contains("login:") }, "\(p2.status)")
        let mark = receivedHex.count
        p2.session.engine.sendInput(Data("x\r".utf8))
        check("b_entree_en_cr_lf", await wait(10) { String(receivedHex.dropFirst(mark)).contains("780d0a") }, receivedHex)
        model.close(tab2)

        // 3. Hôte injoignable : échec avec message en français.
        let dead = freeClosedPort()
        let tab3 = model.newTab(telnetHost("Telnet mort", port: dead))
        let p3 = tab3.panes[0]
        let failed3 = await wait(15) { if case .failed = p3.status { true } else { false } }
        var msg3 = ""
        if case .failed(let m) = p3.status { msg3 = m }
        check("c_refus_connexion_failed", failed3 && msg3.contains("refusée"), msg3)
        model.close(tab3)
        let tab4 = model.newTab(telnetHost("Telnet inconnu", port: 23, host: "hote-inexistant.invalid", settings: TelnetSettings(connectTimeout: 5)))
        let p4 = tab4.panes[0]
        let failed4 = await wait(20) { if case .failed = p4.status { true } else { false } }
        var msg4 = ""
        if case .failed(let m) = p4.status { msg4 = m }
        check("c_hote_inconnu_failed", failed4 && !msg4.isEmpty, msg4)
        model.close(tab4)

        // 4. Via un hôte SSH : tunnel -L sur le maître, bannière, puis tunnel fermé et lien rendu à la fin.
        if let relay = model.library.library.hosts.first(where: { $0.name == "Relais SSH" }) {
            let tab5 = model.newTab(telnetHost("Telnet via SSH", port: port, settings: TelnetSettings(viaSSHHostID: relay.id)))
            let p5 = tab5.panes[0]
            let conn = model.connections.connection(for: relay)
            check("d_via_ssh_connecte", await wait(30) { p5.status == .running }, "\(p5.status)")
            check("d_via_ssh_banniere", await wait(10) { text(p5).contains("Escale Telnet test") }, tail(text(p5)))
            let ports = model.telnet.activeTunnelPorts
            check("d_tunnel_ouvert_port_occupe", ports.count == 1 && ports.allSatisfy { !TunnelPortCheck.isFree(address: "127.0.0.1", port: $0) }, "\(ports)")
            check("d_maitre_ssh_connecte", conn.state == .connected, "\(conn.state)")
            p5.session.engine.sendInput(Data("via\r".utf8))
            check("d_via_ssh_saisie", await wait(10) { text(p5).contains("Recu: via") }, tail(text(p5)))
            p5.session.engine.sendInput(Data("bye\r".utf8))
            check("d_via_ssh_ended", await wait(10) { p5.status == .ended(.exited(0)) }, "\(p5.status)")
            check("d_tunnel_ferme_a_la_fin", await wait(15) { model.telnet.activeTunnelPorts.isEmpty && ports.allSatisfy { TunnelPortCheck.isFree(address: "127.0.0.1", port: $0) } },
                  "\(model.telnet.activeTunnelPorts)")
            check("d_lien_rendu", await wait(10) { conn.tabCount == 0 }, "\(conn.tabCount)")
            model.close(tab5)
            // Hôte SSH supprimé : échec explicite, aucun tunnel.
            let tab6 = model.newTab(telnetHost("Telnet via inconnu", port: port, settings: TelnetSettings(viaSSHHostID: UUID())))
            let p6 = tab6.panes[0]
            var msg6 = ""
            let failed6 = await wait(10) { if case .failed(let m) = p6.status { msg6 = m; return true } else { return false } }
            check("d_hote_ssh_absent_failed", failed6 && msg6.contains("intermédiaire"), msg6)
            model.close(tab6)
        } else {
            check("d_hote_relais_present", false, "bibliothèque sans « Relais SSH »")
        }

        return finish()
    }

    private func finish() -> Bool {
        let ok = !checks.isEmpty && checks.allSatisfy { $0.1 }
        let json: [String: Any] = [
            "ok": ok,
            "checks": Dictionary(checks.map { ($0.0, $0.1) }, uniquingKeysWith: { $1 }),
            "failed": checks.filter { !$0.1 }.map(\.0),
            "details": Dictionary(checks.map { ($0.0, $0.2) }, uniquingKeysWith: { $1 }),
            "screenshots": shots,
            "serverLog": serverLog,
        ]
        if let d = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? d.write(to: URL(fileURLWithPath: directory).appendingPathComponent("result.json"))
        }
        return ok
    }
}
