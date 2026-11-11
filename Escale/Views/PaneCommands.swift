import SwiftUI
import Observation

/// État d'activation du menu, recopié du modèle `@Observable` : ni un `Commands` ni son contenu ne suivent
/// Observation (le menu restait figé sur son premier état), alors qu'un `ObservableObject` est observé.
@MainActor
final class PaneMenuState: ObservableObject {
    static let shared = PaneMenuState()
    @Published private(set) var hasTab = false
    @Published private(set) var several = false
    private weak var model: AppModel?

    func bind(_ model: AppModel) {
        guard self.model !== model else { return }
        self.model = model
        refresh()
    }

    /// Relit l'état et se ré-arme sur les propriétés lues (onglet actif, nombre de panneaux).
    private func refresh() {
        guard let model else { return }
        var tab = false, many = false
        withObservationTracking {
            let t = model.workspace.activeTab
            tab = t != nil
            many = (t?.panes.count ?? 0) > 1
        } onChange: { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        if hasTab != tab { hasTab = tab }
        if several != many { several = many }
    }
}

/// Menu « Terminal » (panneaux) en commandes SwiftUI. Cmd-W reste branché sur `AppModel.closeActiveTab()`
/// (ferme le panneau actif puis l'onglet), d'où l'absence de raccourci sur « Fermer le panneau ».
/// Activation : tout est grisé sans onglet actif ; la navigation et l'égalisation exigent au moins deux panneaux.
struct PaneCommands: Commands {
    let model: AppModel

    init(model: AppModel) {
        self.model = model
        PaneMenuState.shared.bind(model)
    }

    var body: some Commands {
        CommandMenu("Terminal") { PaneMenuItems(model: model) }
    }
}

private struct PaneMenuItems: View {
    let model: AppModel
    @ObservedObject private var state = PaneMenuState.shared

    var body: some View {
        Group {
            let tab: Bool? = state.hasTab ? true : nil
            let several = state.several
            Button("Scinder à droite") { model.splitActivePane(.horizontal) }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(tab == nil)
            Button("Scinder en bas") { model.splitActivePane(.vertical) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(tab == nil)
            Button("Fermer le panneau") { model.closeActivePane() }
                .disabled(tab == nil)
            Divider()
            Button("Panneau suivant") { model.workspace.activeTab?.focusNext() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!several)
            Button("Panneau précédent") { model.workspace.activeTab?.focusPrevious() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!several)
            Divider()
            Button("Panneau à gauche") { model.workspace.activeTab?.focus(.left) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!several)
            Button("Panneau à droite") { model.workspace.activeTab?.focus(.right) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!several)
            Button("Panneau au-dessus") { model.workspace.activeTab?.focus(.up) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!several)
            Button("Panneau en dessous") { model.workspace.activeTab?.focus(.down) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!several)
            Divider()
            Button("Égaliser les panneaux") { model.workspace.activeTab?.equalize() }
                .disabled(!several)
        }
    }
}
