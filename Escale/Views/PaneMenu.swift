import AppKit

/// Menu « Terminal » (panneaux). Installé par code dans la barre de menus plutôt que dans `EscaleCommands`
/// (fichier d'un autre périmètre) ; Cmd-W est déjà branché sur `AppModel.closeActiveTab()`, qui ferme le
/// panneau actif puis l'onglet.
@MainActor
final class PaneMenu: NSObject, NSMenuItemValidation {
    static let shared = PaneMenu()
    static let title = "Terminal"
    private weak var model: AppModel?
    private(set) var menu: NSMenu?

    private var watchdog: Timer?

    /// SwiftUI peut reconstruire la barre de menus (changement de commandes) : on vérifie périodiquement
    /// que le menu y est encore et on le réinstalle sinon.
    func install(model: AppModel) {
        self.model = model
        ensureInstalled()
        if watchdog == nil {
            watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.ensureInstalled() }
            }
        }
    }

    private func ensureInstalled() {
        guard let main = NSApp.mainMenu else { return }
        if let m = menu, main.items.contains(where: { $0.submenu === m }) { return }
        let m = NSMenu(title: Self.title)
        func add(_ title: String, _ key: String, _ mods: NSEvent.ModifierFlags, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = key.isEmpty ? [] : mods
            item.target = self
            m.addItem(item)
        }
        func arrow(_ code: Int) -> String { String(Character(UnicodeScalar(UInt32(code))!)) }
        add("Scinder à droite", "d", [.command], #selector(splitRight))
        add("Scinder en bas", "d", [.command, .shift], #selector(splitDown))
        add("Fermer le panneau", "", [], #selector(closePane))
        m.addItem(.separator())
        add("Panneau suivant", "]", [.command], #selector(nextPane))
        add("Panneau précédent", "[", [.command], #selector(previousPane))
        m.addItem(.separator())
        add("Panneau à gauche", arrow(NSLeftArrowFunctionKey), [.command, .option], #selector(goLeft))
        add("Panneau à droite", arrow(NSRightArrowFunctionKey), [.command, .option], #selector(goRight))
        add("Panneau au-dessus", arrow(NSUpArrowFunctionKey), [.command, .option], #selector(goUp))
        add("Panneau en dessous", arrow(NSDownArrowFunctionKey), [.command, .option], #selector(goDown))
        m.addItem(.separator())
        add("Égaliser les panneaux", "", [], #selector(equalize))
        let top = NSMenuItem(title: Self.title, action: nil, keyEquivalent: "")
        top.submenu = m
        // Avant « Fenêtre » si présent, sinon avant le dernier menu.
        let idx = main.items.firstIndex { $0.submenu === NSApp.windowsMenu } ?? max(main.items.count - 1, 0)
        main.insertItem(top, at: idx)
        menu = m
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let t = model?.workspace.activeTab else { return false }
        switch item.action {
        case #selector(closePane), #selector(equalize), #selector(nextPane), #selector(previousPane),
             #selector(goLeft), #selector(goRight), #selector(goUp), #selector(goDown):
            return item.action == #selector(closePane) || t.panes.count > 1
        default: return true
        }
    }

    @objc func splitRight() { model?.splitActivePane(.horizontal) }
    @objc func splitDown() { model?.splitActivePane(.vertical) }
    @objc func closePane() { model?.closeActivePane() }
    @objc func nextPane() { model?.workspace.activeTab?.focusNext() }
    @objc func previousPane() { model?.workspace.activeTab?.focusPrevious() }
    @objc func goLeft() { model?.workspace.activeTab?.focus(.left) }
    @objc func goRight() { model?.workspace.activeTab?.focus(.right) }
    @objc func goUp() { model?.workspace.activeTab?.focus(.up) }
    @objc func goDown() { model?.workspace.activeTab?.focus(.down) }
    @objc func equalize() { model?.workspace.activeTab?.equalize() }
}
