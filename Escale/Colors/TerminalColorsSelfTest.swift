import AppKit
import Foundation
import EscaleCore

/// `--selftest-colors <dossier>` : thèmes du terminal et surlignage de la sortie, sur un vrai shell local (zsh -f).
/// Réglages en mémoire (préférences de l'utilisateur jamais touchées). Piloté par l'API interne et par la vraie barre
/// de menus (aucun événement clavier global, app non activée). Écrit `result.json` + captures.
///
/// Les mots surlignés sont produits par `printf` avec des échappements octaux : la ligne de commande tapée (écho)
/// ne contient donc jamais le mot cherché, seule la sortie le contient.
@MainActor
final class TerminalColorsSelfTest {
    let dir: String
    let model: AppModel
    private var checks: [(String, Bool, String)] = []
    private var notes: [String: String] = [:]
    private var shots: [String] = []
    private var tab: TerminalTab?

    init(directory: String, model: AppModel) { dir = directory; self.model = model }

    private var feature: TerminalColorsFeature { model.colors }
    private var pane: Pane? { tab?.activePane }
    private var engine: SwiftTermEngine? { pane?.session.engine }

    // MARK: Aides

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        checks.append((name, ok, detail))
        FileHandle.standardError.write(Data("[selftest-colors] \(ok ? "OK " : "KO ") \(name) \(detail)\n".utf8))
    }
    private func wait(_ timeout: Double = 10, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 30_000_000) }
        return cond()
    }
    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
    private var text: String { engine?.text(includingScrollback: true) ?? "" }
    private func type(_ s: String) { engine?.sendInput(Data(s.utf8)) }
    private func run(_ cmd: String, marker: String, timeout: Double = 10) async -> Bool {
        type(cmd + "\r")
        return await wait(timeout) { text.contains(marker) }
    }
    private func fg(_ word: String) -> [String] { engine?.foregroundDescriptions(of: word) ?? [] }

    private func capture(_ name: String) async {
        guard let win = model.mainWindow else { return }
        win.orderFrontRegardless()
        await sleep(0.5)
        for _ in 0..<3 {
            for p in model.workspace.activeTab?.panes ?? [] { p.session.engine.refreshDisplay() }
            win.contentView?.needsDisplay = true
            win.displayIfNeeded()
            await sleep(0.25)
        }
        let path = "\(dir)/\(name).png"
        let pr = Process()
        pr.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        pr.arguments = ["-x", "-o", "-l", "\(win.windowNumber)", path]
        try? pr.run(); pr.waitUntilExit()
        if FileManager.default.fileExists(atPath: path) { shots.append("\(name).png") }
    }

    /// Entrée d'un sous-menu de la barre de menus (Présentation › `submenu` › `title`).
    private func menuItem(_ submenu: String, _ title: String) -> (NSMenu, Int)? {
        func find(_ menu: NSMenu) -> (NSMenu, Int)? {
            for item in menu.items {
                if item.title == submenu, let sub = item.submenu {
                    sub.update()
                    if let i = sub.items.firstIndex(where: { $0.title == title }) { return (sub, i) }
                }
                if let sub = item.submenu, let r = find(sub) { return r }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(find)
    }

    // MARK: Scénario

    func run() async -> Bool {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        check("reglages_en_memoire", feature.defaults == nil)
        check("defauts", feature.themeID == "system" && feature.rules == .keywords, "\(feature.themeID) \(feature.rules)")

        let t = model.openLocalTab(command: ["/bin/zsh", "-f", "-i"])
        tab = t
        check("fenetre", await wait { model.mainWindow != nil && engine?.view.window != nil })
        model.mainWindow?.orderFrontRegardless()
        _ = await wait { t.status == .running }
        check("shell_pret", await run("PROMPT='$ '; clear; echo PR\\EADY", marker: "PREADY"))
        check("theme_applique_au_lancement", engine?.themeID == "system", engine?.themeID ?? "nil")
        check("surlignage_applique_au_lancement", pane?.session.highlightRules == .keywords)

        // 1. Mots-clés (réglage par défaut) : erreur rouge, réussite verte, avertissement jaune ; IP non colorée.
        _ = await run(#"printf 'L1 \145rror \157k w\141rning \106AILED 192.168.1.\61\60 \145rrorx\n'; echo M\A1"#, marker: "MA1")
        let l1 = text
        check("texte_inchange", l1.contains("L1 error ok warning FAILED 192.168.1.10 errorx"), String(l1.suffix(300)))
        check("mot_cle_erreur_rouge", fg("error ok") == ["ansi:1"], "\(fg("error ok"))")
        check("mot_cle_ok_vert", fg("ok warning") == ["ansi:2"], "\(fg("ok warning"))")
        check("mot_cle_avertissement_jaune", fg("warning FAILED") == ["ansi:3"], "\(fg("warning FAILED"))")
        check("mot_cle_majuscules", fg("FAILED") == ["ansi:1"], "\(fg("FAILED"))")
        check("mot_partiel_non_colore", fg("errorx") == ["default"], "\(fg("errorx"))")
        check("ip_non_coloree_sans_jeu_reseau", fg("192.168.1.10") == ["default"], "\(fg("192.168.1.10"))")

        // 2. Texte déjà coloré par le programme : sa couleur est conservée.
        _ = await run(#"printf '\033[34m\146atal\033[0m \033[1m\160anic\033[0m\n'; echo M\A2"#, marker: "MA2")
        check("couleur_du_programme_conservee", fg("fatal") == ["ansi:4"], "\(fg("fatal"))")
        check("gras_seul_surligne", fg("panic") == ["ansi:1"], "\(fg("panic"))")

        // 3. Jeu « mots-clés et réseau ».
        feature.setRules(.keywordsAndNetwork)
        check("reglage_propage", pane?.session.highlightRules == .keywordsAndNetwork)
        _ = await run(#"printf 'L3 10.20.30.\64\60:22 h\164tps://exemple.fr/a \144enied\n'; echo M\A3"#, marker: "MA3")
        check("ip_magenta", fg("10.20.30.40:22") == ["ansi:5"], "\(fg("10.20.30.40:22"))")
        check("url_bleue", fg("https://exemple.fr/a") == ["ansi:4"], "\(fg("https://exemple.fr/a"))")
        check("refus_rouge", fg("denied") == ["ansi:1"], "\(fg("denied"))")
        await capture("01-surlignage-systeme")

        // 4. Écran alternatif (vim, less) : aucun surlignage.
        _ = await run(#"printf '\033[?1049h\162efused ALT\n'; echo M\A4"#, marker: "MA4")
        check("ecran_alternatif_non_surligne", fg("refused") == ["default"], "\(fg("refused"))")
        _ = await run(#"printf '\033[?1049l'; clear; echo M\A5"#, marker: "MA5")
        _ = await run(#"printf 'L6 \162efused\n'; echo M\A6"#, marker: "MA6")
        check("surlignage_repris_apres_ecran_alternatif", fg("refused").last == "ansi:1", "\(fg("refused"))")

        // 5. Vrai vim : le contenu du fichier n'est pas recoloré.
        let file = "\(dir)/vim-error.txt"
        try? "vimline error ok\n".write(toFile: file, atomically: true, encoding: .utf8)
        type("clear; vim -u NONE -N '\(file)'\r")
        let vimUp = await wait(10) { text.contains("vimline") }
        check("vim_ouvert", vimUp)
        if vimUp { check("vim_non_surligne", fg("error ok") == ["default"], "\(fg("error ok"))") }
        type("\u{1b}:q!\r")
        _ = await run("clear; echo M\\A7", marker: "MA7")

        // 6. Désactivé.
        feature.setRules(.off)
        _ = await run(#"printf 'L8 \145rror\n'; echo M\A8"#, marker: "MA8")
        check("desactive", fg("error").last == "default", "\(fg("error"))")

        // 7. Réglage par hôte.
        let hid = UUID()
        feature.setRules(.keywordsAndNetwork, host: hid)
        check("reglage_par_hote", feature.effectiveRules(host: hid) == .keywordsAndNetwork && feature.effectiveRules(host: UUID()) == .off
              && feature.effectiveRules(host: nil) == .off)
        feature.setRules(nil, host: hid)
        check("retour_reglage_general", feature.effectiveRules(host: hid) == .off && feature.hostRules.isEmpty)
        feature.setRules(.keywordsAndNetwork)

        // 8. Écho interactif sans attente : un mot-clé tapé s'affiche aussitôt (pas retenu).
        let t0 = Date()
        type("erro")
        let echoed = await wait(1) { text.contains("$ erro") }
        notes["latence_echo_ms"] = String(format: "%.1f", Date().timeIntervalSince(t0) * 1000)
        check("echo_immediat", echoed, notes["latence_echo_ms"] ?? "")
        type("\u{15}") // ^U

        // 9. Débit : 20 000 lignes surlignées.
        let t1 = Date()
        let flood = await run(#"i=0; while (( i++ < 20000 )); do print -r -- "line $i error ok 10.0.0.1 done"; done; echo M\A9"#,
                              marker: "MA9", timeout: 60)
        notes["flood_20000_lignes_s"] = String(format: "%.2f", Date().timeIntervalSince(t1))
        check("debit_20000_lignes", flood, notes["flood_20000_lignes_s"] ?? "")
        _ = await run("clear; echo M\\A10", marker: "MA10")

        // 10. Thèmes : palette et fond appliqués au panneau ouvert ; contenu existant conservé.
        _ = await run(#"printf 'T1 \145rror \157k w\141rning 192.168.0.\61 \033[35mmagenta\033[0m \033[42m vert \033[0m\n'; echo M\B1"#, marker: "MB1")
        for (id, bg) in [("solarized-dark", "#002b36"), ("classic", "#000000"), ("paper", "#ffffff"), ("dracula", "#282a36")] {
            feature.setTheme(id)
            check("theme_\(id)", engine?.themeID == id && engine?.effectiveBackground.description == bg,
                  "\(engine?.themeID ?? "nil") \(engine?.effectiveBackground.description ?? "")")
            await capture("02-theme-\(id)")
        }
        check("contenu_conserve_apres_themes", text.contains("T1 error ok warning"))

        // 11. Nouveau panneau : thème appliqué avant son premier octet.
        if let p2 = model.splitActivePane(.horizontal) {
            check("nouveau_panneau_theme", p2.session.engine.themeID == "dracula" && p2.session.highlightRules == .keywordsAndNetwork,
                  p2.session.engine.themeID ?? "nil")
            _ = await wait { p2.status == .running }
            await sleep(0.8)
            await capture("03-deux-panneaux")
            model.closePane(p2)
        } else {
            check("nouveau_panneau_theme", false, "scission impossible")
        }

        // 12. Barre de menus : Présentation › Thème du terminal › Tango sombre ; Coloration › Mots-clés.
        if let (menu, i) = menuItem("Thème du terminal", "Tango sombre") {
            menu.performActionForItem(at: i)
            check("menu_theme", await wait(3) { feature.themeID == "tango" && engine?.themeID == "tango" }, feature.themeID)
        } else { check("menu_theme", false, "entrée absente") }
        if let (menu, i) = menuItem("Coloration de la sortie", "Mots-clés") {
            menu.performActionForItem(at: i)
            check("menu_coloration", await wait(3) { feature.rules == .keywords }, feature.rules.rawValue)
        } else { check("menu_coloration", false, "entrée absente") }
        await capture("04-theme-tango")

        // 13. Retour au thème Système : défauts du moteur.
        feature.setTheme("system")
        check("retour_theme_systeme", engine?.themeID == "system" && engine?.themeBackground == nil)
        await capture("05-theme-systeme")

        type("exit\r")
        _ = await wait { if case .ended = t.status { return true } else { return false } }
        return finish()
    }

    private func finish() -> Bool {
        tab.map { model.close($0) }
        let ok = !checks.isEmpty && checks.allSatisfy { $0.1 }
        let json: [String: Any] = [
            "ok": ok,
            "checks": Dictionary(checks.map { ($0.0, $0.1) }, uniquingKeysWith: { a, b in a && b }),
            "details": Dictionary(checks.map { ($0.0, $0.2) }, uniquingKeysWith: { a, _ in a }),
            "failed": checks.filter { !$0.1 }.map(\.0),
            "notes": notes,
            "screenshots": shots,
        ]
        if let d = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: "\(dir)/result.json"))
        }
        return ok
    }
}
