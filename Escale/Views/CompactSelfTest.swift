import AppKit
import Foundation
import SwiftUI

/// Scénario `--selftest-compact <dossier>` : mode compact de la fenêtre principale (écrit `result.json` + PNG).
/// Piloté par l'API interne et par la vraie barre de menus (aucun événement clavier/souris global, app non activée).
/// Les préférences passent par une suite `UserDefaults` dédiée : celles de l'utilisateur ne sont jamais touchées
/// (seul le mode d'affichage de la barre d'outils est rétabli à la fin).
@MainActor
final class CompactSelfTest {
    static let defaultsSuite = "fr.escale.selftest.compact"

    let dir: String
    let model: AppModel
    private var checks: [(String, Bool, String)] = []
    private var shots: [String] = []

    init(directory: String, model: AppModel) { dir = directory; self.model = model }

    // MARK: Aides

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        checks.append((name, ok, detail))
        FileHandle.standardError.write(Data("[selftest-compact] \(ok ? "OK " : "KO ") \(name) \(detail)\n".utf8))
    }
    private func wait(_ timeout: Double = 10, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }
        return cond()
    }
    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    private var window: NSWindow? { model.mainWindow }
    private var defaults: UserDefaults { model.compact.defaults }

    private func capture(_ name: String) async {
        guard let win = window else { return }
        win.orderFrontRegardless()
        await sleep(0.6)
        for _ in 0..<3 {
            for p in model.workspace.activeTab?.panes ?? [] { p.session.engine.refreshDisplay() }
            win.contentView?.needsDisplay = true
            win.displayIfNeeded()
            await sleep(0.3)
        }
        let path = "\(dir)/\(name).png"
        let pr = Process()
        pr.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        pr.arguments = ["-x", "-o", "-l", "\(win.windowNumber)", path]
        try? pr.run(); pr.waitUntilExit()
        if FileManager.default.fileExists(atPath: path) { shots.append("\(name).png") }
    }

    private func findSplit(_ v: NSView) -> NSSplitView? {
        if let s = v as? NSSplitView, s.subviews.count >= 2 { return s }
        for c in v.subviews { if let s = findSplit(c) { return s } }
        return nil
    }
    /// Largeur visible de la barre latérale (0 si repliée) : le second conteneur du `NSSplitView` de la fenêtre
    /// (le premier porte le détail), tronqué à la zone visible du split (replié, il sort du cadre ou est masqué).
    private var sidebarWidth: CGFloat {
        guard let root = window?.contentView?.superview, let s = findSplit(root) else { return -1 }
        let wrappers = s.subviews.filter { String(describing: type(of: $0)).contains("ItemViewWrapper") }
        guard wrappers.count >= 2 else { return -1 }
        let side = wrappers[1]
        if side.isHidden { return 0 }
        return max(0, side.frame.intersection(s.bounds).width)
    }
    private var displayMode: NSToolbar.DisplayMode? { window?.toolbar?.displayMode }

    private func menuItem(_ title: String) -> NSMenuItem? {
        func search(_ m: NSMenu) -> NSMenuItem? {
            for i in m.items {
                if i.title == title { return i }
                if let sub = i.submenu, let f = search(sub) { return f }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(search)
    }
    /// Valide la barre de menus (AppKit le fait avant d'afficher un menu), puis lit l'item.
    private func compactItem() -> NSMenuItem? { validatedItem("Mode compact") }
    /// Item lu après validation de son menu (SwiftUI ne met à jour titre et coche qu'à ce moment). Le titre peut
    /// changer : on valide le menu qui contient « Mode compact » (Présentation), puis on cherche `title`.
    private func validatedItem(_ title: String) -> NSMenuItem? {
        if let m = menuItem("Mode compact")?.menu { m.delegate?.menuNeedsUpdate?(m); m.update() }
        return menuItem(title)
    }
    private func clickCompactMenu() -> Bool {
        guard let item = compactItem(), let m = item.menu, let i = m.items.firstIndex(of: item) else { return false }
        m.performActionForItem(at: i)
        return true
    }

    // MARK: Scénario

    func run() async -> Bool {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Départ propre : suite dédiée vide.
        defaults.removePersistentDomain(forName: Self.defaultsSuite)
        let ok0 = await wait(15) { window != nil && window?.toolbar != nil && sidebarWidth > 100 }
        check("fenetre_prete", ok0, "fenêtre \(window != nil) barre \(window?.toolbar != nil) latérale \(sidebarWidth)")
        _ = await wait(5) { displayMode == .iconAndLabel }
        _ = model.openLocalTab()
        model.sidebarTab = .tools
        await sleep(0.8)

        // 1. État normal.
        check("normal_pas_compact", !model.compact.isOn && model.compact.columns == .all)
        check("normal_barre_outils_avec_libelles", displayMode == .iconAndLabel, "mode \(String(describing: displayMode?.rawValue))")
        check("normal_barre_laterale_visible", sidebarWidth > 200, "largeur \(sidebarWidth)")
        let before = compactItem()
        check("menu_mode_compact_present", before != nil)
        check("menu_coche_absente_en_normal", before?.state == .off, "état \(String(describing: before?.state.rawValue))")
        check("menu_raccourci_shift_cmd_M", before?.keyEquivalent.lowercased() == "m"
              && before?.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == [.command, .shift],
              "touche \(before?.keyEquivalent ?? "?") masque \(String(describing: before?.keyEquivalentModifierMask.rawValue))")
        // Bouton « Barre latérale » : le nôtre, pas celui du système (légende débordante, non personnalisable).
        let ids = window?.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
        check("barre_outils_sans_bouton_systeme", !ids.contains(NSToolbarItem.Identifier.toggleSidebar.rawValue)
              && !ids.contains { $0.localizedCaseInsensitiveContains("sidebarToggle") }, ids.joined(separator: ","))
        check("barre_outils_bouton_barre_laterale", ids.contains { $0.contains("barre-laterale") }, ids.joined(separator: ","))
        let showItem = validatedItem("Masquer la barre latérale")
        check("menu_masquer_barre_laterale_ctrl_cmd_S", showItem?.keyEquivalent.lowercased() == "s"
              && showItem?.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == [.command, .control],
              "touche \(showItem?.keyEquivalent ?? "?") masque \(String(describing: showItem?.keyEquivalentModifierMask.rawValue))")
        model.compact.toggleSidebar()
        check("bouton_masque_la_barre", await wait(5) { sidebarWidth == 0 } && !model.compact.sidebarVisible, "largeur \(sidebarWidth)")
        check("menu_libelle_afficher", await wait(3) { validatedItem("Afficher la barre latérale") != nil })
        model.compact.toggleSidebar()
        check("bouton_rouvre_la_barre", await wait(5) { sidebarWidth > 200 }, "largeur \(sidebarWidth)")
        await capture("01-normal")

        // 2. Entrée en compact par la commande de menu.
        check("menu_clic_compact", clickCompactMenu())
        check("compact_actif", await wait(3) { model.compact.isOn })
        check("compact_barre_laterale_repliee", await wait(5) { sidebarWidth == 0 }, "largeur \(sidebarWidth)")
        check("compact_barre_outils_icones_seules", await wait(5) { displayMode == .iconOnly }, "mode \(String(describing: displayMode?.rawValue))")
        check("compact_menu_coche", await wait(3) { compactItem()?.state == .on }, "état \(String(describing: compactItem()?.state.rawValue))")
        check("compact_persiste_dans_les_preferences", defaults.bool(forKey: CompactMode.enabledKey))
        check("compact_mode_precedent_memorise", defaults.object(forKey: CompactMode.toolbarKey) as? Int == Int(NSToolbar.DisplayMode.iconAndLabel.rawValue),
              "valeur \(String(describing: defaults.object(forKey: CompactMode.toolbarKey)))")
        await capture("02-compact")

        // 3. Persistance : une nouvelle instance relit l'état comme au lancement.
        let reborn = CompactMode(defaults: defaults)
        check("persistance_relance_actif", reborn.isOn && reborn.columns == .detailOnly, "actif \(reborn.isOn) colonnes \(reborn.columns)")

        // 4. Choisir un volet en compact rouvre temporairement la barre latérale.
        model.sidebarTab = .macros
        check("volet_en_compact_rouvre_la_barre", await wait(5) { sidebarWidth > 200 }, "largeur \(sidebarWidth)")
        check("volet_en_compact_temporaire", model.compact.isOn && model.compact.autoOpened)
        await capture("03-compact-volet-rouvert")
        // ... et elle se replie dès qu'un onglet s'ouvre.
        _ = model.openLocalTab()
        check("onglet_ouvert_replie_la_barre", await wait(5) { sidebarWidth == 0 && !model.compact.autoOpened }, "largeur \(sidebarWidth)")
        // Replié à la main : plus de repli automatique ensuite.
        model.sidebarTab = .tools
        _ = await wait(5) { sidebarWidth > 200 }
        model.compact.columns = .detailOnly
        model.compact.columnsChanged()
        _ = model.openLocalTab()
        await sleep(0.5)
        check("repli_manuel_annule_l_auto", !model.compact.autoOpened && sidebarWidth == 0)
        model.sidebarTab = .macros
        _ = await wait(5) { sidebarWidth > 200 }

        // 5. Sortie du compact : barre latérale et volet d'avant restaurés.
        check("menu_clic_sortie", clickCompactMenu())
        check("sortie_inactif", await wait(3) { !model.compact.isOn })
        check("sortie_volet_restaure", await wait(3) { model.sidebarTab == .tools }, "volet \(model.sidebarTab)")
        check("sortie_barre_laterale_restauree", await wait(5) { sidebarWidth > 200 }, "largeur \(sidebarWidth)")
        check("sortie_barre_outils_libellee", await wait(5) { displayMode == .iconAndLabel }, "mode \(String(describing: displayMode?.rawValue))")
        check("sortie_menu_decoche", await wait(3) { compactItem()?.state == .off })
        check("sortie_preferences_effacees", !defaults.bool(forKey: CompactMode.enabledKey) && defaults.object(forKey: CompactMode.toolbarKey) == nil)
        await capture("04-restaure")

        // 6. Barre latérale déjà repliée avant le compact : elle le reste après, sans rouvrir le volet.
        model.compact.columns = .detailOnly
        await sleep(0.5)
        model.sidebarTab = .tools
        model.compact.columns = .detailOnly // le changement de volet l'a rouverte
        _ = await wait(5) { sidebarWidth == 0 }
        model.compact.set(true, model: model)
        model.sidebarTab = .macros
        _ = await wait(5) { sidebarWidth > 200 }
        model.compact.set(false, model: model)
        check("repliee_avant_reste_repliee", await wait(5) { sidebarWidth == 0 && model.sidebarTab == .tools }, "largeur \(sidebarWidth) volet \(model.sidebarTab)")
        model.compact.columns = .all
        check("raccourci_bascule_par_api", { model.compact.toggle(model: model); return model.compact.isOn }())
        model.compact.toggle(model: model)
        check("bascule_retour", !model.compact.isOn && defaults.object(forKey: CompactMode.toolbarKey) == nil)
        _ = await wait(5) { displayMode == .iconAndLabel }
        check("fin_barre_outils_rétablie", displayMode == .iconAndLabel, "mode \(String(describing: displayMode?.rawValue))")

        defaults.removePersistentDomain(forName: Self.defaultsSuite)
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
        ]
        if let d = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: "\(dir)/result.json"))
        }
        return ok
    }
}
