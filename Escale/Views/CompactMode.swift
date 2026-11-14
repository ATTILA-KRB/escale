import SwiftUI
import AppKit
import Observation

/// Mode compact de la fenêtre principale : barre d'outils en icônes seules, barre latérale repliée, barre d'état réduite.
/// L'état (actif ou non) est persistant ; la visibilité de la barre latérale vit ici pour que le mode, la fenêtre et
/// l'auto-test lisent la même valeur. Aucune session n'est ouverte ni fermée par la bascule (invariant 12).
@MainActor
@Observable
final class CompactMode {
    static let enabledKey = "escale.compact.enabled"
    /// Mode d'affichage de la barre d'outils avant le passage en compact (valeur brute d'`NSToolbar.DisplayMode`).
    /// Persisté : AppKit mémorise aussi le mode courant, donc quitter l'app en compact ne doit pas figer « icônes seules ».
    static let toolbarKey = "escale.compact.previousToolbarMode"

    @ObservationIgnored let defaults: UserDefaults
    private(set) var isOn: Bool
    /// Visibilité de la barre latérale (liée à `NavigationSplitView`).
    var columns: NavigationSplitViewVisibility
    /// Vrai quand un choix de volet a rouvert temporairement la barre latérale en compact.
    private(set) var autoOpened = false
    @ObservationIgnored private var restoreColumns: NavigationSplitViewVisibility = .all
    @ObservationIgnored private var restoreTab: SidebarTab?
    /// Le prochain changement de volet vient de la sortie du compact : il ne doit pas rouvrir la barre latérale.
    @ObservationIgnored private var suppressReveal = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let on = defaults.bool(forKey: Self.enabledKey)
        isOn = on
        columns = on ? .detailOnly : .all
    }

    func toggle(model: AppModel) { set(!isOn, model: model) }

    func set(_ on: Bool, model: AppModel) {
        guard on != isOn else { return }
        isOn = on
        defaults.set(on, forKey: Self.enabledKey)
        autoOpened = false
        if on {
            restoreColumns = columns
            restoreTab = model.sidebarTab
            columns = .detailOnly
        } else {
            columns = restoreColumns
            if let tab = restoreTab, tab != model.sidebarTab {
                suppressReveal = true
                model.sidebarTab = tab
            }
            restoreTab = nil
        }
        applyToolbar(to: model.mainWindow)
    }

    /// Un volet vient d'être choisi (menu, barre d'outils, accueil) ou la connexion rapide appelée.
    /// Décision : en compact, cela rouvre la barre latérale (sinon le choix serait invisible), mais seulement
    /// jusqu'à l'ouverture d'un onglet ou jusqu'à ce que l'utilisateur la replie lui-même.
    func revealSidebar() {
        if suppressReveal { suppressReveal = false; return }
        columns = .all
        autoOpened = isOn
    }

    /// Un onglet vient d'être ouvert : une barre latérale rouverte temporairement se replie.
    func tabsChanged(from old: Int, to new: Int) {
        guard isOn, autoOpened, new > old else { return }
        columns = .detailOnly
        autoOpened = false
    }

    /// Repli de la barre latérale par l'utilisateur (bouton, glissement) : plus rien à refermer.
    func columnsChanged() {
        if columns == .detailOnly { autoOpened = false }
    }

    /// Icônes seules en compact ; sinon rétablit le mode d'avant. Différé : la barre d'outils SwiftUI est installée
    /// après l'arrivée de la vue dans la fenêtre (même précaution que `ToolbarDefaults`).
    func applyToolbar(to window: NSWindow?) {
        guard let window else { return }
        DispatchQueue.main.async { [self] in
            guard let toolbar = window.toolbar else { return }
            if isOn {
                if defaults.object(forKey: Self.toolbarKey) == nil {
                    defaults.set(Int(toolbar.displayMode.rawValue), forKey: Self.toolbarKey)
                }
                toolbar.displayMode = .iconOnly
            } else if let raw = defaults.object(forKey: Self.toolbarKey) as? Int {
                toolbar.displayMode = NSToolbar.DisplayMode(rawValue: UInt(raw)) ?? .iconAndLabel
                defaults.removeObject(forKey: Self.toolbarKey)
            }
        }
    }
}
