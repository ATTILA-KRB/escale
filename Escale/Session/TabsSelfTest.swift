import AppKit
import QuartzCore
import Foundation
import EscaleCore

/// Scénario automatique `--selftest-tabs <dossier>` : onglets détachables contre un sshd local.
/// Piloté uniquement par l'API interne (modèles, actions de menu, vues) : aucun événement clavier/souris global.
/// Vérifie qu'un onglet (ici scindé) détaché puis rattaché garde le même shell (pid), le même moteur, son
/// historique et le même nombre de sessions sur le maître. Écrit result.json + PNG dans le dossier.
@MainActor
final class TabsSelfTest {
    let dir: String
    let model: AppModel
    private var checks: [(String, Bool, String)] = []
    private var shots: [String] = []
    private var notes: [String: String] = [:]

    init(directory: String, model: AppModel) { dir = directory; self.model = model }

    // MARK: Aides

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        checks.append((name, ok, detail))
        FileHandle.standardError.write(Data("[selftest-tabs] \(ok ? "OK " : "KO ") \(name) \(detail)\n".utf8))
    }
    private func wait(_ timeout: Double = 10, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return cond()
    }
    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
    private func text(_ p: Pane) -> String { p.session.engine.text(includingScrollback: true) }
    private func type(_ p: Pane, _ s: String) { p.session.engine.sendInput(Data(s.utf8)) }
    private func waitText(_ p: Pane, _ s: String, _ timeout: Double = 15) async -> Bool { await wait(timeout) { text(p).contains(s) } }

    private func findHost(_ v: NSView) -> PaneHostView? {
        if let h = v as? PaneHostView { return h }
        for s in v.subviews { if let h = findHost(s) { return h } }
        return nil
    }

    private func capture(_ win: NSWindow, _ name: String, panes: [Pane]) async {
        win.orderFrontRegardless()
        await sleep(0.5)
        for _ in 0..<3 {
            for p in panes { p.session.engine.refreshDisplay() }
            win.contentView?.needsDisplay = true
            win.displayIfNeeded()
            CATransaction.flush()
            await sleep(0.4)
        }
        let path = "\(dir)/\(name).png"
        let pr = Process()
        pr.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        pr.arguments = ["-x", "-o", "-l", "\(win.windowNumber)", path]
        try? pr.run(); pr.waitUntilExit()
        if FileManager.default.fileExists(atPath: path) { shots.append("\(name).png") }
    }

    private func children() -> [Int32: String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let me = getpid()
        var out: [Int32: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, let pid = Int32(f[0]), Int32(f[1]) == me else { continue }
            let name = (String(f[2]) as NSString).lastPathComponent
            if name != "ps" { out[pid] = name }
        }
        return out
    }

    /// Action d'un menu de la barre de menus réelle, par titres (validation AppKit comprise).
    @discardableResult
    private func menu(_ menuTitle: String, _ item: String) -> Bool {
        guard let m = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == menuTitle })?.submenu,
              let i = m.items.firstIndex(where: { $0.title == item }) else { return false }
        m.delegate?.menuNeedsUpdate?(m)
        m.update()
        guard m.items[i].isEnabled else { return false }
        m.performActionForItem(at: i)
        return true
    }
    private func menuEnabled(_ menuTitle: String, _ item: String) -> Bool? {
        guard let m = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == menuTitle })?.submenu,
              let i = m.items.first(where: { $0.title == item }) else { return nil }
        m.delegate?.menuNeedsUpdate?(m)
        m.update()
        return i.isEnabled
    }

    /// Pid du shell du panneau (`$$`), relevé en tapant dans le terminal.
    private func shellPID(_ p: Pane, tag: String) async -> Int? {
        type(p, "echo PID\(tag)-$$-E\r")
        guard await wait(15, { pid(in: text(p), tag: tag) != nil }) else { return nil }
        return pid(in: text(p), tag: tag)
    }
    private func pid(in s: String, tag: String) -> Int? {
        guard let r = s.range(of: "PID\(tag)-[0-9]+-E", options: .regularExpression) else { return nil }
        // La ligne de commande tapée ne contient pas de chiffres après « PID<tag>- » (c'est « $$ »).
        return Int(s[r].dropFirst("PID\(tag)-".count).dropLast(2))
    }

    // MARK: Scénario

    func run() async -> Bool {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard await wait(15, { model.mainWindow != nil }), let main = model.mainWindow else {
            check("fenetre_principale", false); return finish()
        }
        main.orderFrontRegardless()
        check("fenetre_principale", true)
        model.connections.graceDelay = 0.5
        _ = await wait(10) { model.library.isLoaded }
        guard let h1 = model.library.library.hosts.sorted(by: { $0.name < $1.name }).first else { check("hotes_disponibles", false); return finish() }

        // 1. Onglet SSH scindé en deux panneaux, plus un onglet local qui reste dans la fenêtre principale
        let tab = model.newTab(h1)
        let conn = model.connections.connection(for: h1)
        let p1 = tab.panes[0]
        check("onglet_ssh_connecte", await wait(25) { p1.status == .running && conn.state == .connected }, "\(conn.state)")
        model.splitActivePane(.horizontal)
        check("deux_panneaux_running", await wait(25) { tab.panes.count == 2 && tab.panes.allSatisfy { $0.status == .running } })
        let p2 = tab.panes[1]
        let local = model.openLocalTab(command: ["/bin/zsh", "-f", "-i"])
        check("onglet_local_running", await wait(10) { local.panes[0].status == .running })
        model.workspace.select(tab.id)
        let link = conn.links[0]
        type(p1, "echo MK-UN-$((6*7))-X\r"); type(p2, "echo MK-DEUX-$((7*8))-X\r")
        let m1 = await waitText(p1, "MK-UN-42-X"), m2 = await waitText(p2, "MK-DEUX-56-X")
        check("marqueurs_avant", m1 && m2)
        let pid1 = await shellPID(p1, tag: "A1"), pid2 = await shellPID(p2, tag: "A2")
        check("pid_shells_releves", pid1 != nil && pid2 != nil && pid1 != pid2, "\(String(describing: pid1)) \(String(describing: pid2))")
        let engines = [ObjectIdentifier(p1.session.engine), ObjectIdentifier(p2.session.engine)]
        let sessions0 = await link.transport.sessionCount
        let tabCount0 = link.tabCount
        let started0 = model.connections.shellsStarted
        let kids0 = children()
        notes["sessionCount_avant"] = "\(sessions0)"
        check("sessionCount_avant_attendu", sessions0 == 2, "\(sessions0)")
        check("menu_detacher_actif", await wait(10) { menuEnabled("Onglets", "Détacher l'onglet dans une nouvelle fenêtre") == true })
        check("menu_ramener_grise_sans_detache", menuEnabled("Onglets", "Ramener dans la fenêtre principale") == false)
        check("hote_principal_sur_onglet_ssh", main.contentView.flatMap { findHost($0) } != nil)

        // 2. Détacher (action de menu)
        check("action_detacher", menu("Onglets", "Détacher l'onglet dans une nouvelle fenêtre"))
        check("fenetre_detachee_creee", await wait(5) { model.detached.count == 1 && tab.windowID != nil })
        guard let ctl = model.detached.controller(for: tab), let dwin = Optional(ctl.window) else { check("controleur_detache", false); return finish() }
        check("fenetre_titre_hote", await wait(5) { dwin.title == tab.baseTitle } && dwin.title == h1.name, dwin.title)
        check("fenetre_visible", dwin.isVisible && dwin !== main)
        check("onglet_toujours_dans_workspace", model.workspace.tabs.contains { $0.id == tab.id } && !model.workspace.mainTabs.contains { $0.id == tab.id })
        check("principale_sur_onglet_local", model.workspace.activeTab?.id == local.id)
        check("ramener_actif_apres_detachement", await wait(10) { menuEnabled("Onglets", "Ramener dans la fenêtre principale") == true })
        let dhost = dwin.contentView.flatMap { findHost($0) }
        check("hote_de_vues_dans_fenetre_detachee", dhost != nil)
        check("moteurs_dans_fenetre_detachee", await wait(5) { tab.panes.allSatisfy { $0.session.engine.view.window === dwin } })
        check("memes_moteurs", tab.panes.map { ObjectIdentifier($0.session.engine) } == engines)
        check("historique_conserve_apres_detachement", text(p1).contains("MK-UN-42-X") && text(p2).contains("MK-DEUX-56-X"))
        await sleep(0.8)
        let pidD1 = await shellPID(p1, tag: "B1"), pidD2 = await shellPID(p2, tag: "B2")
        check("meme_shell_apres_detachement", pidD1 == pid1 && pidD2 == pid2, "\(String(describing: pidD1)) \(String(describing: pidD2))")
        check("memes_processus_enfants", children() == kids0, "\(children()) / \(kids0)")
        check("sessionCount_inchange_apres_detachement", await link.transport.sessionCount == sessions0, "\(await link.transport.sessionCount)")
        check("tabCount_inchange", link.tabCount == tabCount0 && model.connections.shellsStarted == started0)
        check("panneaux_toujours_running", tab.panes.allSatisfy { $0.status == .running } && tab.status == .running)
        check("aucune_reconnexion", conn.links.count == 1 && link.state == .connected)
        // Saisie dans la fenêtre détachée, taille du pty = taille du moteur
        type(p2, "echo STTY-DET-$(stty size)-E\r")
        let sz = p2.session.engine.size
        check("stty_egal_moteur_detache", await waitText(p2, "STTY-DET-\(sz.rows) \(sz.columns)-E"), "\(sz.rows)x\(sz.columns)")
        let statusCount = model.workspace.tabs.count
        check("compteurs_barre_etat_justes", statusCount == 2 && model.workspace.tabs.reduce(0) { $0 + $1.panes.count } == 3, "\(statusCount)")
        await capture(main, "01-fenetre-principale-apres-detachement", panes: local.panes)
        await capture(dwin, "02-fenetre-detachee", panes: tab.panes)

        // 3. Rattacher (action de menu)
        check("action_ramener", menu("Onglets", "Ramener dans la fenêtre principale"))
        check("rattache_dans_principale", await wait(5) { tab.windowID == nil && model.workspace.mainTabs.contains { $0.id == tab.id } && model.workspace.activeTab?.id == tab.id })
        check("fenetre_detachee_fermee", await wait(5) { model.detached.count == 0 && !dwin.isVisible })
        check("moteurs_dans_principale", await wait(5) { tab.panes.allSatisfy { $0.session.engine.view.window === main } })
        check("memes_moteurs_apres_rattachement", tab.panes.map { ObjectIdentifier($0.session.engine) } == engines)
        check("historique_conserve_apres_rattachement", text(p1).contains("MK-UN-42-X") && text(p2).contains("MK-DEUX-56-X") && text(p2).contains("STTY-DET-"))
        await sleep(0.8)
        let pidR1 = await shellPID(p1, tag: "C1"), pidR2 = await shellPID(p2, tag: "C2")
        check("meme_shell_apres_rattachement", pidR1 == pid1 && pidR2 == pid2, "\(String(describing: pidR1)) \(String(describing: pidR2))")
        check("memes_processus_enfants_apres_rattachement", children() == kids0)
        check("sessionCount_inchange_apres_rattachement", await link.transport.sessionCount == sessions0, "\(await link.transport.sessionCount)")
        check("tabCount_et_shells_inchanges", link.tabCount == tabCount0 && model.connections.shellsStarted == started0)
        check("menu_ramener_grise_apres_rattachement", await wait(10) { menuEnabled("Onglets", "Ramener dans la fenêtre principale") == false })
        type(p1, "echo STTY-REAT-$(stty size)-E\r")
        let sz1 = p1.session.engine.size
        check("stty_egal_moteur_rattache", await waitText(p1, "STTY-REAT-\(sz1.rows) \(sz1.columns)-E"), "\(sz1.rows)x\(sz1.columns)")
        await capture(main, "03-apres-rattachement", panes: tab.panes)

        // 4. Détacher de nouveau puis fermer la fenêtre : ses sessions sont fermées
        model.detached.detach(tab)
        check("redetache", await wait(5) { tab.windowID != nil && model.detached.count == 1 })
        guard let ctl2 = model.detached.controller(for: tab) else { check("controleur_redetache", false); return finish() }
        let ended0 = model.connections.shellsEnded
        ctl2.window.close()
        check("fermeture_fenetre_ferme_onglet", await wait(5) { !model.workspace.tabs.contains { $0.id == tab.id } && model.detached.count == 0 })
        check("shells_fermes_comptes_une_fois", await wait(15) { model.connections.shellsEnded == ended0 + 2 }, "\(model.connections.shellsEnded - ended0)")
        var sc = -1
        for _ in 0..<150 { sc = await link.transport.sessionCount; if sc == 0 { break }; await sleep(0.1) }
        check("sessionCount_zero_apres_fermeture", sc == 0, "\(sc)")
        check("onglet_local_intact", model.workspace.tabs.count == 1 && local.panes[0].status == .running)

        // 5. Tout fermer
        for t in model.workspace.tabs { model.close(t) }
        check("tous_onglets_fermes", model.workspace.tabs.isEmpty)
        check("tous_les_maitres_deconnectes", await wait(25) { model.connections.allLinks.allSatisfy { $0.state == .disconnected } })
        _ = await wait(15) { model.connections.shellsEnded == model.connections.shellsStarted }
        check("shells_demarres_egal_termines", model.connections.shellsEnded == model.connections.shellsStarted, "\(model.connections.shellsStarted)/\(model.connections.shellsEnded)")
        var kids: [Int32: String] = [:]
        _ = await wait(10) { kids = children(); return kids.isEmpty }
        check("aucun_processus_enfant_residuel", kids.isEmpty, "\(kids)")
        return finish()
    }

    private func finish() -> Bool {
        let ok = !checks.isEmpty && checks.allSatisfy { $0.1 }
        let json: [String: Any] = [
            "ok": ok,
            "checks": Dictionary(uniqueKeysWithValues: checks.map { ($0.0, $0.1) }),
            "details": Dictionary(uniqueKeysWithValues: checks.map { ($0.0, $0.2) }),
            "failed": checks.filter { !$0.1 }.map(\.0),
            "screenshots": shots,
            "notes": notes,
        ]
        if let d = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: "\(dir)/result.json"))
        }
        return ok
    }
}
