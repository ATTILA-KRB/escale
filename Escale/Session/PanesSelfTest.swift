import AppKit
import QuartzCore
import Foundation
import EscaleCore

/// Scénario automatique `--selftest-panes <dossier>` : panneaux scindés contre un sshd local.
/// Piloté uniquement par l'API interne (modèles, actions de menu, méthodes des vues) : aucun événement
/// clavier/souris global, pas d'activation de l'app. Écrit result.json + PNG dans le dossier.
/// Variable d'environnement `ESCALE_SSHD_LOG` : journal du sshd (comptage des authentifications).
@MainActor
final class PanesSelfTest {
    let dir: String
    let model: AppModel
    private var checks: [(String, Bool, String)] = []
    private var shots: [String] = []
    private var notes: [String: String] = [:]
    private var window: NSWindow?
    private var host: PaneHostView?

    init(directory: String, model: AppModel) { dir = directory; self.model = model }

    // MARK: Aides

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        checks.append((name, ok, detail))
        FileHandle.standardError.write(Data("[selftest-panes] \(ok ? "OK " : "KO ") \(name) \(detail)\n".utf8))
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
    private func tail(_ s: String, _ n: Int = 400) -> String { String(s.suffix(n)) }

    private var sshdLog: String {
        guard let p = ProcessInfo.processInfo.environment["ESCALE_SSHD_LOG"] else { return "" }
        return (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
    }
    private var acceptedCount: Int { sshdLog.components(separatedBy: "Accepted publickey").count - 1 }

    private func findHost(_ v: NSView) -> PaneHostView? {
        if let h = v as? PaneHostView { return h }
        for s in v.subviews { if let h = findHost(s) { return h } }
        return nil
    }

    private func capture(_ name: String) async {
        guard let win = window else { return }
        win.orderFrontRegardless()
        await sleep(0.5)
        host?.layoutSubtreeIfNeeded()
        for _ in 0..<3 {
            for p in model.workspace.activeTab?.panes ?? [] { p.session.engine.refreshDisplay() }
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

    private func children() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let me = getpid()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, Int32(f[1]) == me else { return nil }
            let name = (String(f[2]) as NSString).lastPathComponent
            return name == "ps" ? nil : "\(f[0]) \(name)"
        }
    }

    /// Action de menu invoquée par l'API (sans événement clavier).
    @discardableResult
    private func menu(_ title: String) -> Bool {
        guard let m = terminalMenu(), let i = m.items.firstIndex(where: { $0.title == title }) else { return false }
        m.performActionForItem(at: i)
        return true
    }

    /// Menu « Terminal » installé par les `Commands` SwiftUI (cherché dans la barre de menus réelle).
    private func terminalMenu() -> NSMenu? {
        NSApp.mainMenu?.items.first { $0.submenu?.title == "Terminal" }?.submenu
    }

    /// Ce qu'AppKit fait juste avant d'afficher un menu : délégué `menuNeedsUpdate`, puis validation des éléments.
    private func refreshMenu(_ m: NSMenu) {
        m.delegate?.menuNeedsUpdate?(m)
        m.update()
    }

    /// État activé d'un élément du menu (validation AppKit comprise).
    private func menuEnabled(_ title: String) -> Bool? {
        guard let m = terminalMenu(), let i = m.items.first(where: { $0.title == title }) else { return nil }
        refreshMenu(m)
        return i.isEnabled
    }

    /// Chaque panneau tape `stty size` ; compare à la taille de son moteur (réessaie si la taille bouge).
    private func sttyMatchesEngine(_ panes: [Pane], tag: String, timeout: Double = 15) async -> (Bool, String) {
        let end = Date().addingTimeInterval(timeout)
        var k = 0
        var detail = ""
        while Date() < end {
            k += 1
            for p in panes { type(p, "echo S\(tag)\(k)Z $(stty size) E\r") }
            await sleep(1.0)
            var all = true
            detail = ""
            for p in panes {
                let s = p.session.engine.size
                let want = "S\(tag)\(k)Z \(s.rows) \(s.columns) E"
                if !text(p).contains(want) { all = false }
                detail += "[\(s.rows)x\(s.columns)] "
            }
            if all { return (true, detail) }
        }
        return (false, detail)
    }

    private func frameInHost(_ v: NSView) -> CGRect { host.map { $0.convert(v.bounds, from: v) } ?? .zero }

    // MARK: Scénario

    func run() async -> Bool {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard await wait(15, { model.mainWindow != nil }), let win = model.mainWindow else {
            check("fenetre_principale", false); return finish()
        }
        window = win
        win.orderFrontRegardless()
        check("fenetre_principale", true)
        model.connections.graceDelay = 0.5
        _ = await wait(10) { model.library.isLoaded }
        let hosts = model.library.library.hosts.sorted { $0.name < $1.name }
        guard let h1 = hosts.first, let h2 = hosts.last, h1.id != h2.id else { check("hotes_disponibles", false); return finish() }

        // 1. Onglet SSH, un panneau
        let tabA = model.newTab(h1)
        let p1 = tabA.panes[0]
        let conn1 = model.connections.connection(for: h1)
        check("onglet_ssh_connecte", await wait(25) { p1.status == .running && conn1.state == .connected }, "\(conn1.state)")
        guard let hv = win.contentView.flatMap({ findHost($0) }) else { check("vue_panneaux_trouvee", false); return finish() }
        host = hv
        check("vue_panneaux_trouvee", true)
        check("menu_terminal_installe", await wait(10) { terminalMenu() != nil })
        let menuTitles = terminalMenu()?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
        check("menu_titres", menuTitles == ["Scinder à droite", "Scinder en bas", "Fermer le panneau", "Panneau suivant", "Panneau précédent",
                                            "Panneau à gauche", "Panneau à droite", "Panneau au-dessus", "Panneau en dessous", "Égaliser les panneaux"], "\(menuTitles)")
        // Un seul panneau : scinder/fermer actifs ; navigation et égalisation grisées.
        check("menu_etat_un_panneau",
              await wait(10) { menuEnabled("Scinder à droite") == true && menuEnabled("Fermer le panneau") == true
                  && menuEnabled("Panneau suivant") == false && menuEnabled("Égaliser les panneaux") == false },
              "\(terminalMenu()?.items.map { "\($0.title):\($0.isEnabled)" } ?? []) etat=\(PaneMenuState.shared.hasTab)/\(PaneMenuState.shared.several) delegue=\(terminalMenu()?.delegate != nil) active=\(NSApp.isActive) key=\(NSApp.keyWindow != nil) onglets=\(NSApp.mainMenu?.items.first { $0.submenu?.title == "Onglets" }?.submenu?.items.map { "\($0.title):\($0.isEnabled)" }.prefix(3) ?? [])")
        if let m = terminalMenu() {
            func key(_ t: String) -> String {
                guard let i = m.items.first(where: { $0.title == t }) else { return "absent" }
                let f = i.keyEquivalentModifierMask
                return "\(f.contains(.command) ? "C" : "")\(f.contains(.option) ? "O" : "")\(f.contains(.shift) ? "S" : "")-\(i.keyEquivalent.unicodeScalars.map { String($0.value, radix: 16) }.joined())"
            }
            let keys = ["Scinder à droite": key("Scinder à droite"), "Scinder en bas": key("Scinder en bas"), "Panneau suivant": key("Panneau suivant"),
                        "Panneau précédent": key("Panneau précédent"), "Panneau à gauche": key("Panneau à gauche"), "Panneau à droite": key("Panneau à droite"),
                        "Panneau au-dessus": key("Panneau au-dessus"), "Panneau en dessous": key("Panneau en dessous")]
            check("menu_raccourcis_declares",
                  keys["Scinder à droite"] == "C-64" && keys["Scinder en bas"] == "CS-64" && ["C-5d", "C-24"].contains(keys["Panneau suivant"]!) && ["C-5b", "C-5e"].contains(keys["Panneau précédent"]!) /* AppKit remappe ] et [ sur la disposition clavier active (AZERTY : $ et ^) */
                  && keys["Panneau à gauche"] == "CO-f702" && keys["Panneau à droite"] == "CO-f703" && keys["Panneau au-dessus"] == "CO-f700" && keys["Panneau en dessous"] == "CO-f701",
                  "\(keys)")
        }
        type(p1, "echo MK1-$((1*111))-${SSH_CONNECTION%% *}\r")
        check("shell_distant_panneau1", await waitText(p1, "MK1-111-127.0.0.1"), tail(text(p1)))
        let engine1 = ObjectIdentifier(p1.session.engine)
        let link1 = conn1.links[0]
        check("une_authentification_avant_scission", acceptedCount == 1, "\(acceptedCount)")

        // 2. Scinder à droite, puis en bas (par les actions de menu)
        check("action_scinder_a_droite", menu("Scinder à droite"))
        check("deux_panneaux", await wait(5) { tabA.panes.count == 2 })
        let p2 = tabA.panes[1]
        check("nouveau_panneau_actif", tabA.activePane.id == p2.id && tabA.layout.active == p2.id)
        check("panneau2_running_meme_maitre", await wait(25) { p2.status == .running } && p2.link === p1.link, "\(p2.status)")
        check("menu_scinder_en_bas", menu("Scinder en bas"))
        check("menu_etat_plusieurs_panneaux", await wait(5) { menuEnabled("Panneau suivant") == true && menuEnabled("Égaliser les panneaux") == true && menuEnabled("Panneau à gauche") == true })
        check("trois_panneaux", await wait(5) { tabA.panes.count == 3 })
        let p3 = tabA.panes[2]
        check("panneau3_running_meme_maitre", await wait(25) { p3.status == .running } && p3.link === p1.link, "\(p3.status)")
        check("meme_hote_pour_les_trois", [p1, p2, p3].allSatisfy { $0.hostID == h1.id })
        check("ordre_arbre", tabA.panes.map(\.id) == [p1.id, p2.id, p3.id])
        check("moteurs_distincts", Set([p1, p2, p3].map { ObjectIdentifier($0.session.engine) }).count == 3)
        // Marqueurs distincts, résultat calculé à distance, un par panneau (saisie au panneau actif via le premier répondeur)
        let ps = [p1, p2, p3]
        for (i, p) in ps.enumerated().dropFirst() { type(p, "echo MK\(i + 1)-$((\(i + 1)*111))-${SSH_CONNECTION%% *}\r") }
        for (i, p) in ps.enumerated() {
            let mine = "MK\(i + 1)-\((i + 1) * 111)-127.0.0.1"
            let others = ps.enumerated().filter { $0.offset != i }.map { "MK\($0.offset + 1)-\(($0.offset + 1) * 111)-127.0.0.1" }
            check("shell_distant_panneau\(i + 1)_marqueur_distinct", await waitText(p, mine) && !others.contains { text(p).contains($0) }, tail(text(p)))
        }
        check("une_seule_authentification_sshd", acceptedCount == 1, "authentifications acceptées : \(acceptedCount)")
        check("un_seul_connect", link1.connectAttempts == 1 && conn1.links.count == 1, "\(link1.connectAttempts)")
        check("compteur_sessions_compte_les_panneaux", link1.tabCount == 3, "\(link1.tabCount)")
        let sc3 = await link1.transport.sessionCount
        check("sessionCount_3", sc3 == 3, "\(sc3)")
        check("premier_panneau_contenu_intact_moteur_identique", text(p1).contains("MK1-111-127.0.0.1") && ObjectIdentifier(p1.session.engine) == engine1, tail(text(p1)))
        await sleep(0.6)
        let (st0, d0) = await sttyMatchesEngine(ps, tag: "A")
        check("stty_size_egal_moteur_3_panneaux", st0, d0)

        // Géométrie : côte à côte p1 | colonne (p2 / p3)
        func geometryChecks(_ label: String) {
            let b = hv.bounds
            let f1 = frameInHost(p1.session.engine.view), f2 = frameInHost(p2.session.engine.view), f3 = frameInHost(p3.session.engine.view)
            let th = PaneLayout.dividerThickness
            let widths = f1.width + f2.width + 2 * 2 * PaneHostView.insetX + th
            check("\(label)_largeurs_somme_egale_fenetre", abs(widths - b.width) <= 1.5, "p1 \(f1.width) + p2 \(f2.width) + marges + séparateur = \(widths) ; zone \(b.width)")
            let cw = f1.width / CGFloat(max(p1.session.engine.size.columns, 1))
            let sumCols = p1.session.engine.size.columns + p2.session.engine.size.columns
            let expected = (b.width - 4 * PaneHostView.insetX - th) / cw
            check("\(label)_colonnes_coherentes_avec_fenetre", abs(CGFloat(sumCols) - expected) <= 4, "colonnes \(p1.session.engine.size.columns)+\(p2.session.engine.size.columns)=\(sumCols) ; attendu ≈ \(Int(expected))")
            check("\(label)_p2_p3_meme_largeur", abs(f2.width - f3.width) <= 1 && abs(f2.minX - f3.minX) <= 1)
            let ch = p1.session.engine.cellHeight
            let multiples = [f1, f2, f3].allSatisfy { r in abs(r.height / ch - (r.height / ch).rounded()) < 0.01 }
            check("\(label)_hauteur_grille_multiple_de_cellule", multiples, "cellule \(ch) ; hauteurs \(f1.height) \(f2.height) \(f3.height)")
        }
        geometryChecks("initial")

        // 3. Navigation directionnelle et panneau actif
        func active() -> UUID { tabA.layout.active }
        check("actif_p3_apres_scission", active() == p3.id)
        check("chrome_actif_distingue", hv.chromeView(p3.id)?.describesActive == true && hv.chromeView(p1.id)?.describesActive == false && hv.chromeView(p2.id)?.describesActive == false)
        menu("Panneau au-dessus")
        check("nav_haut_p3_vers_p2", active() == p2.id)
        menu("Panneau à gauche")
        check("nav_gauche_p2_vers_p1", active() == p1.id)
        let bornes = tabA.focus(.up) == false && tabA.focus(.left) == false && tabA.focus(.down) == false && active() == p1.id
        check("nav_aux_bords_sans_effet", bornes)
        menu("Panneau à droite")
        check("nav_droite_p1_vers_colonne", active() == p2.id || active() == p3.id)
        tabA.setActive(p2.id)
        menu("Panneau en dessous")
        check("nav_bas_p2_vers_p3", active() == p3.id)
        tabA.setActive(p2.id)
        check("nav_droite_p2_sans_voisin", tabA.focus(.right) == false && active() == p2.id)
        check("nav_gauche_p3_vers_p1", { tabA.setActive(p3.id); tabA.focus(.left); return active() == p1.id }())
        menu("Panneau suivant")
        check("suivant_p1_vers_p2", active() == p2.id)
        menu("Panneau suivant"); menu("Panneau suivant")
        check("suivant_circulaire_p3_vers_p1", active() == p1.id)
        menu("Panneau précédent")
        check("precedent_circulaire_p1_vers_p3", active() == p3.id)

        // Focus clavier et saisie dirigée vers le panneau actif uniquement (premier répondeur -> panneau)
        func firstResponderPane() -> Pane? { ps.first { win.firstResponder === $0.session.engine.view } }
        check("focus_clavier_sur_panneau_actif", await wait(3) { firstResponderPane()?.id == tabA.layout.active }, "actif \(tabA.layout.active) / focus \(String(describing: firstResponderPane()?.id))")
        tabA.setActive(p2.id)
        _ = await wait(3) { firstResponderPane()?.id == p2.id }
        if let target = firstResponderPane() { type(target, "echo ONLY-$((5*5))-ACTIVE\r") }
        check("saisie_uniquement_panneau_actif", await waitText(p2, "ONLY-25-ACTIVE") && !text(p1).contains("ONLY-25-ACTIVE") && !text(p3).contains("ONLY-25-ACTIVE"), tail(text(p2)))
        // Clic dans un panneau (méthode appelée par le moniteur de clics) : actif + focus
        let c1 = p1.session.engine.view.convert(NSPoint(x: p1.session.engine.view.bounds.midX, y: p1.session.engine.view.bounds.midY), to: nil)
        check("clic_active_panneau", hv.activatePane(atWindowPoint: c1) && tabA.layout.active == p1.id && p1.session.engine.hasKeyboardFocus)
        // Titre de l'onglet = titre du panneau actif
        type(p3, "printf '\\033]0;TTL-TROIS\\007'\r")
        type(p1, "printf '\\033]0;TTL-UN\\007'\r")
        _ = await wait(8) { p3.displayTitle == "TTL-TROIS" && p1.displayTitle == "TTL-UN" }
        check("titre_onglet_egal_titre_panneau_actif", tabA.displayTitle == "TTL-UN", tabA.displayTitle)
        tabA.setActive(p3.id)
        let winTitled = await wait(3) { win.title == "TTL-TROIS" }
        check("titre_onglet_suit_le_panneau_actif", tabA.displayTitle == "TTL-TROIS" && winTitled, "\(tabA.displayTitle) / fenêtre \(win.title)")

        // 4. Redimensionnement de la fenêtre -> chaque pty
        let f0 = win.frame
        win.setFrame(NSRect(x: f0.minX, y: f0.minY - 40, width: f0.width - 170, height: f0.height + 40), display: true)
        await sleep(1.2)
        let (st1, d1) = await sttyMatchesEngine(ps, tag: "B")
        check("stty_size_egal_moteur_apres_redimensionnement_fenetre", st1, d1)
        geometryChecks("fenetre_redim")
        win.setFrame(f0, display: true)
        await sleep(1.0)

        // 5. Séparateurs : glisser, bornes, double-clic (égaliser)
        let splits = tabA.layout.splitIDs
        check("deux_separateurs", splits.count == 2 && splits.allSatisfy { hv.dividerView($0) != nil })
        let root = splits[0]
        let before = p1.session.engine.size
        let rd = tabA.layout.geometry(in: hv.bounds).dividers.first { $0.splitID == root }!
        hv.dragDivider(root, to: NSPoint(x: rd.parentRect.minX + rd.parentRect.width * 0.3, y: rd.rect.midY))
        await sleep(0.8)
        check("separateur_deplace_p1_plus_etroit", p1.session.engine.size.columns < before.columns && tabA.layout.ratios[0] < 0.4, "colonnes \(before.columns) -> \(p1.session.engine.size.columns), ratios \(tabA.layout.ratios)")
        let (st2, d2) = await sttyMatchesEngine(ps, tag: "C")
        check("stty_size_egal_moteur_apres_deplacement_separateur", st2, d2)
        geometryChecks("separateur_deplace")
        hv.dragDivider(root, to: NSPoint(x: -500, y: rd.rect.midY))
        await sleep(0.5)
        check("redimensionnement_borne_taille_minimale", frameInHost(p1.session.engine.view).width + 2 * PaneHostView.insetX >= PaneLayout.minPaneSize.width - 1, "largeur p1 \(frameInHost(p1.session.engine.view).width)")
        hv.dragDivider(root, to: NSPoint(x: 100000, y: rd.rect.midY))
        await sleep(0.5)
        check("redimensionnement_borne_cote_oppose", frameInHost(p2.session.engine.view).width + 2 * PaneHostView.insetX >= PaneLayout.minPaneSize.width - 1, "largeur p2 \(frameInHost(p2.session.engine.view).width)")
        hv.equalizeActiveTab()
        await sleep(0.8)
        check("egaliser_ratios_moitie", tabA.layout.ratios.allSatisfy { abs($0 - 0.5) < 0.001 }, "\(tabA.layout.ratios)")
        let (st3, d3) = await sttyMatchesEngine(ps, tag: "D")
        check("stty_size_egal_moteur_apres_egalisation", st3, d3)

        // 6. Capture : trois panneaux, actif distingué
        tabA.setActive(p2.id)
        await capture("01-trois-panneaux")

        // 7. Fermeture du panneau du milieu (p2) : les deux autres intacts et retaillés
        let rowsBefore = p3.session.engine.size.rows
        let endedBefore = model.connections.shellsEnded
        tabA.setActive(p2.id)
        check("action_fermer_panneau", menu("Fermer le panneau"))
        check("deux_panneaux_apres_fermeture", await wait(5) { tabA.panes.count == 2 })
        check("frere_reprend_la_place_et_devient_actif", tabA.activePane.id == p3.id && tabA.panes.map(\.id) == [p1.id, p3.id])
        await sleep(0.8)
        check("p3_retaille_plus_haut", p3.session.engine.size.rows > rowsBefore, "\(rowsBefore) -> \(p3.session.engine.size.rows)")
        check("p1_p3_contenu_intact", text(p1).contains("MK1-111-127.0.0.1") && text(p3).contains("MK3-333-127.0.0.1"))
        let (st4, d4) = await sttyMatchesEngine([p1, p3], tag: "E")
        check("stty_size_egal_moteur_apres_fermeture", st4, d4)
        check("shell_du_panneau_ferme_compte_une_fois", await wait(10) { model.connections.shellsEnded == endedBefore + 1 }, "terminés \(model.connections.shellsEnded - endedBefore)")
        check("moteur_p2_retire_de_la_vue", await wait(5) { p2.session.engine.view.superview == nil })
        check("compteur_sessions_apres_fermeture", await wait(10) { link1.tabCount == 2 }, "\(link1.tabCount)")
        let sc2 = await link1.transport.sessionCount
        check("sessionCount_2_apres_fermeture", sc2 == 2, "\(sc2)")
        // Nouvelle scission : retour à 3 panneaux (p1 | p3 / p4)
        model.splitActivePane(.vertical)
        let p4 = tabA.panes.last!
        check("scission_apres_fermeture", await wait(25) { tabA.panes.count == 3 && p4.status == .running && p4.link === link1 })
        type(p4, "echo MK4-$((4*111))-${SSH_CONNECTION%% *}\r")
        check("p4_shell_distant", await waitText(p4, "MK4-444-127.0.0.1"))
        check("toujours_une_authentification", acceptedCount == 1, "\(acceptedCount)")

        // 7b. OSC 52 : écriture permise vers le presse-papiers, lecture refusée (aucune réponse au programme distant).
        // Presse-papiers nommé dédié : celui de l'utilisateur n'est jamais touché (changeCount vérifié).
        let osc = NSPasteboard(name: NSPasteboard.Name("com.attila-krb.Escale.selftest.osc52.\(getpid())"))
        let generalBefore = NSPasteboard.general.changeCount
        TerminalClipboard.pasteboard = osc
        defer { osc.releaseGlobally(); TerminalClipboard.pasteboard = .general }
        osc.clearContents()
        osc.setString("SENTINELLE-AVANT", forType: .string)
        let payload = "OSC52-ECRITURE-\(Int.random(in: 100_000...999_999))"
        type(p4, "printf '\\033]52;c;%s\\007' $(printf '\(payload)' | base64)\r")
        check("osc52_ecriture_dans_presse_papiers", await wait(10) { osc.string(forType: .string) == payload }, "\(osc.string(forType: .string) ?? "nil")")
        osc.clearContents()
        osc.setString("SENTINELLE-LECTURE", forType: .string)
        type(p4, "bash -c 'stty -echo -icanon min 0 time 20; printf \"\\033]52;c;?\\007\"; R=$(dd bs=1 count=64 2>/dev/null | cat -v); stty sane; echo OSC52-LECTURE-[$R]-FIN'\r")
        check("osc52_lecture_demande_sans_reponse", await waitText(p4, "OSC52-LECTURE-[]-FIN", 20), tail(text(p4)))
        check("osc52_lecture_ne_modifie_pas_le_presse_papiers", osc.string(forType: .string) == "SENTINELLE-LECTURE", "\(osc.string(forType: .string) ?? "nil")")
        check("osc52_presse_papiers_general_intact", NSPasteboard.general.changeCount == generalBefore, "changeCount \(generalBefore) -> \(NSPasteboard.general.changeCount)")

        // 8. Autres onglets : B (même hôte, 2 panneaux), C (local, scindé), D (hôte B) ; pire état ; fermeture du dernier panneau
        let tabB = model.newTab(h1)
        check("onglet_b_running", await wait(25) { tabB.status == .running })
        check("onglet_b_meme_maitre", tabB.link === link1 && link1.tabCount == 4, "\(link1.tabCount)")
        model.splitActivePane(.horizontal)
        let b1 = tabB.panes[0], b2 = tabB.panes[1]
        check("onglet_b_deux_panneaux_running", await wait(25) { b2.status == .running && b1.status == .running })
        check("onglet_b_deux_panneaux_actif_b2", tabB.activePane.id == b2.id)
        type(b2, "exit 4\r")
        check("pire_etat_onglet_ended", await wait(10) { b2.status == .ended(.exited(4)) } && tabB.status == .ended(.exited(4)) && b1.status == .running, "\(tabB.status)")
        check("bandeau_panneau_termine_seul", b2.bannerMessage == "Session terminée (code 4)" && b1.bannerMessage == nil)
        model.closePane(b2)
        check("fermer_panneau_termine", await wait(5) { tabB.panes.count == 1 } && tabB.status == .running)
        model.closeActiveTab()   // Cmd-W : dernier panneau -> ferme l'onglet
        check("dernier_panneau_ferme_onglet", await wait(5) { !model.workspace.tabs.contains { $0.id == tabB.id } })
        model.workspace.select(tabA.id)

        let tabC = model.openLocalTab(command: ["/bin/zsh", "-f", "-i"])
        let c1p = tabC.panes[0]
        check("onglet_local_running", await wait(10) { c1p.status == .running })
        let shellsBeforeLocal = model.connections.shellsStarted
        model.splitActivePane(.horizontal)
        let c2p = tabC.panes[1]
        check("scission_terminal_local", await wait(10) { c2p.status == .running } && c2p.link == nil && !c2p.isRemote && c2p.kind == c1p.kind)
        type(c1p, "echo LOC1-$((6*7))-END\r"); type(c2p, "echo LOC2-$((7*8))-END\r")
        let loc1 = await waitText(c1p, "LOC1-42-END"), loc2 = await waitText(c2p, "LOC2-56-END")
        check("deux_shells_locaux", loc1 && loc2 && !text(c1p).contains("LOC2-56-END") && !text(c2p).contains("LOC1-42-END"))
        check("scission_locale_ne_lance_pas_de_ssh", model.connections.shellsStarted == shellsBeforeLocal)
        let (stl, dl) = await sttyLocal([c1p, c2p])
        check("stty_size_egal_moteur_local", stl, dl)

        let tabD = model.newTab(h2)
        check("onglet_d_running", await wait(25) { tabD.status == .running })
        let tabX = model.newTab(h1)
        check("onglet_x_running", await wait(25) { tabX.status == .running })
        model.workspace.select(tabA.id)
        check("quatre_onglets", model.workspace.tabs.count == 4, "\(model.workspace.tabs.map(\.displayTitle))")
        await capture("02-quatre-onglets")

        // 9. Coupure simulée du maître (hôte A) : bandeau par panneau, aucune ligne masquée, une seule reconnexion
        let cutPanes = tabA.panes
        for (i, p) in cutPanes.enumerated() { type(p, "echo BEFORE-CUT-\(i + 1)-$((7*6))\r") }
        var marks = true
        for (i, p) in cutPanes.enumerated() { marks = await waitText(p, "BEFORE-CUT-\(i + 1)-42") && marks }
        check("marqueurs_avant_coupure", marks)
        let textsBefore = cutPanes.map { text($0) }
        model.connections.reconnectDelays = [5]
        let acceptedBefore = acceptedCount
        let attemptsBefore = link1.connectAttempts
        let pid = await link1.transport.masterProcessIdentifier
        check("pid_maitre_expose", pid != nil, "\(pid.map(String.init) ?? "nil")")
        if let pid { kill(pid, SIGKILL) }
        check("coupure_detectee_trois_panneaux", await wait(20) { cutPanes.allSatisfy { $0.status == .reconnecting } }, cutPanes.map { "\($0.status)" }.joined(separator: ","))
        check("pire_etat_onglet_reconnexion", tabA.status == .reconnecting)
        check("bandeau_decompte", await wait(10) {
            if case .reconnecting(_, let s?) = link1.state { return s > 0 && cutPanes.allSatisfy { $0.bannerMessage?.contains("nouvelle tentative dans") == true } }
            return false
        }, cutPanes[0].bannerMessage ?? "nil")
        model.workspace.select(tabA.id)
        check("bandeau_present_sur_chaque_panneau", await wait(5) { cutPanes.allSatisfy { hv.bannerView($0.id) != nil } })
        await sleep(1.2)
        let sizesBand = cutPanes.map { $0.session.engine.size }
        await sleep(1.0)
        check("une_seule_retaille_apres_apparition_du_bandeau", sizesBand == cutPanes.map { $0.session.engine.size }, "\(sizesBand.map { "\($0.rows)x\($0.columns)" })")
        for (i, p) in cutPanes.enumerated() {
            guard let bv = hv.bannerView(p.id) else { check("bandeau_\(i + 1)_geometrie", false, "absent"); continue }
            let bf = frameInHost(bv), ef = frameInHost(p.session.engine.view)
            check("bandeau_\(i + 1)_hauteur_selon_largeur", abs(bv.frame.height - PaneBanner.height(forWidth: bv.frame.width)) < 0.01, "largeur \(bv.frame.width) hauteur \(bv.frame.height)")
            check("bandeau_\(i + 1)_ne_recouvre_pas_la_grille", bf.intersection(ef).isEmpty && bf.maxY <= ef.minY + 0.01, "bandeau y \(bf.minY)…\(bf.maxY), grille y \(ef.minY)…\(ef.maxY)")
            let ch = p.session.engine.cellHeight
            check("grille_\(i + 1)_multiple_entier_de_cellule", abs(ef.height / ch - (ef.height / ch).rounded()) < 0.01 && ef.minY - bf.maxY >= PaneHostView.insetTop - 0.01, "grille h \(ef.height) cellule \(ch)")
            check("ecran_\(i + 1)_conserve_pendant_coupure", text(p).contains("BEFORE-CUT-\(i + 1)-42"))
        }
        notes["bandeau"] = cutPanes[0].bannerMessage ?? ""
        await capture("03-bandeaux-reconnexion")
        check("reconnexion_automatique", await wait(60) { link1.state == .connected && cutPanes.allSatisfy { $0.status == .running } }, "lien \(link1.state), \(cutPanes.map { "\($0.status)" })")
        check("une_seule_reconnexion", link1.connectAttempts - attemptsBefore == 1, "\(link1.connectAttempts - attemptsBefore) tentative(s)")
        check("une_authentification_pour_la_reconnexion", acceptedCount - acceptedBefore == 1, "\(acceptedCount - acceptedBefore)")
        for (i, p) in cutPanes.enumerated() { type(p, "echo AFTER-\(i + 1)-$((9*9))-${SSH_CONNECTION%% *}\r") }
        for (i, p) in cutPanes.enumerated() {
            check("panneau_\(i + 1)_nouveau_shell", await waitText(p, "AFTER-\(i + 1)-81-127.0.0.1"))
            let s = text(p)
            let a = s.range(of: "BEFORE-CUT-\(i + 1)-42")?.lowerBound, b = s.range(of: "Connexion rétablie le")?.lowerBound, c = s.range(of: "AFTER-\(i + 1)-81-127.0.0.1")?.lowerBound
            check("panneau_\(i + 1)_ecran_avant_separateur_apres", a != nil && b != nil && c != nil && a! < b! && b! < c!, tail(s, 500))
            check("panneau_\(i + 1)_contenu_precedent_conserve", s.contains(String(textsBefore[i].prefix(60))))
        }
        check("bandeaux_disparus", await wait(5) { cutPanes.allSatisfy { hv.bannerView($0.id) == nil && $0.bannerMessage == nil } })
        await sleep(0.8)
        let (st5, d5) = await sttyMatchesEngine(cutPanes, tag: "F")
        check("stty_size_egal_moteur_apres_reconnexion", st5, d5)
        check("toujours_un_seul_maitre", conn1.links.count == 1)
        notes["ecran_visible_apres_reconnexion_1"] = cutPanes[0].session.engine.text(includingScrollback: false)
        await capture("04-apres-reconnexion")

        // 10. Dix panneaux sur l'hôte B (plusieurs onglets) : deux maîtres
        let acceptedBeforeH2 = acceptedCount // l'hôte B a déjà un premier maître (onglet D)
        let conn2 = model.connections.connection(for: h2)
        let tabE = model.newTab(h2), tabF = model.newTab(h2)
        _ = await wait(25) { tabE.status == .running && tabF.status == .running }
        func grow(_ t: TerminalTab, to n: Int) {
            model.workspace.select(t.id)
            while t.panes.count < n { model.splitActivePane(t.panes.count % 2 == 1 ? .horizontal : .vertical) }
        }
        grow(tabD, to: 4); grow(tabE, to: 4); grow(tabF, to: 2)
        let h2panes = tabD.panes + tabE.panes + tabF.panes
        check("dix_panneaux_hote_b", h2panes.count == 10, "\(h2panes.count)")
        check("dix_panneaux_running", await wait(80) { h2panes.allSatisfy { $0.status == .running } }, h2panes.map { "\($0.status)" }.joined(separator: ","))
        let counts = conn2.links.map(\.tabCount)
        check("second_maitre_au_dela_de_9_panneaux", conn2.links.count == 2 && counts == [9, 1], "panneaux par maître : \(counts)")
        var sess: [Int] = []
        for l in conn2.links { sess.append(await l.transport.sessionCount) }
        check("sessionCount_par_maitre_9_1", sess == [9, 1], "\(sess)")
        check("une_authentification_pour_le_second_maitre", acceptedCount - acceptedBeforeH2 == 1, "\(acceptedCount - acceptedBeforeH2)")
        let tenth = h2panes[9]
        type(tenth, "echo TENTH-$((5*5))-${SSH_CONNECTION%% *}\r")
        check("dixieme_panneau_fonctionnel", await waitText(tenth, "TENTH-25-127.0.0.1"))
        model.workspace.select(tabE.id)
        await sleep(0.8)
        let (st6, d6) = await sttyMatchesEngine(tabE.panes, tag: "G")
        check("stty_size_egal_moteur_4_panneaux_imbriques", st6, d6)
        await capture("05-quatre-panneaux-imbriques")

        // 11. Tout fermer : plus de maître, plus de ssh
        check("menu_toujours_present", terminalMenu() != nil)
        for t in model.workspace.tabs { model.close(t) }
        check("tous_onglets_fermes", model.workspace.tabs.isEmpty)
        check("menu_grise_sans_onglet", await wait(5) { menuEnabled("Scinder à droite") == false && menuEnabled("Fermer le panneau") == false },
              "état \(PaneMenuState.shared.hasTab)/\(PaneMenuState.shared.several) onglet actif \(model.workspace.activeTab != nil) menu \(terminalMenu()?.items.prefix(3).map { "\($0.title):\($0.isEnabled)" } ?? [])")
        let allDown = await wait(25) { model.connections.allLinks.allSatisfy { $0.state == .disconnected } }
        check("tous_les_maitres_deconnectes", allDown, model.connections.allLinks.map { "\($0.state)" }.joined(separator: ","))
        var pids: [Int32?] = []
        for _ in 0..<100 {
            pids = []
            for l in model.connections.allLinks { pids.append(await l.transport.masterProcessIdentifier) }
            if pids.allSatisfy({ $0 == nil }) { break }
            await sleep(0.1)
        }
        check("aucun_pid_maitre", pids.allSatisfy { $0 == nil }, "\(pids)")
        _ = await wait(15) { model.connections.shellsEnded == model.connections.shellsStarted }
        check("shellSessionDidEnd_exactement_une_fois_par_shell", model.connections.shellsEnded == model.connections.shellsStarted,
              "démarrés \(model.connections.shellsStarted), terminés \(model.connections.shellsEnded)")
        var sc: [Int] = []
        for l in model.connections.allLinks { sc.append(await l.transport.sessionCount) }
        check("sessionCount_zero_partout", sc.allSatisfy { $0 == 0 }, "\(sc)")
        check("compteurs_panneaux_zero", model.connections.allLinks.allSatisfy { $0.tabCount == 0 }, model.connections.allLinks.map { "\($0.tabCount)" }.joined(separator: ","))
        var kids: [String] = []
        _ = await wait(10) { kids = children(); return kids.isEmpty }
        check("aucun_processus_enfant_residuel", kids.isEmpty, kids.joined(separator: ", "))
        await capture("06-etat-vide")
        return finish()
    }

    /// `stty size` en local (même vérification, sans ssh).
    private func sttyLocal(_ panes: [Pane]) async -> (Bool, String) { await sttyMatchesEngine(panes, tag: "L") }

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
