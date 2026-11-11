import SwiftUI
import Observation
import EscaleCore

// PROVISOIRE (squelette M5) : à remplacer par le flux macros + X11. Contrat figé : noms de types et
// initialiseurs appelés depuis `Escale/Features/AppFeature.swift`, `AppModel` et `HostEditorSheet`.

/// M5 : macros (séquences de saisie rejouables) et redirection X11 via XQuartz.
@MainActor
@Observable
final class MacroFeature: AppFeature {
    @ObservationIgnored private(set) weak var model: AppModel?
    func attach(_ model: AppModel) { self.model = model }
    func shutdown() async {}
}

struct MacroCommands: Commands {
    let model: AppModel
    var body: some Commands { EmptyCommands() }
}

struct MacroScene: ViewModifier {
    let model: AppModel
    func body(content: Content) -> some View { content }
}

struct MacroHostMenuItems: View {
    let model: AppModel
    let host: HostProfile
    var body: some View { EmptyView() }
}

/// Section X11 de la feuille d'édition d'hôte.
struct X11EditorSection: View {
    @Binding var isOn: Bool
    var body: some View {
        Section { Toggle("Redirection X11 (XQuartz)", isOn: $isOn) }
    }
}

/// `--selftest-macros <dossier>`.
@MainActor
struct MacroSelfTest {
    let directory: String
    let model: AppModel
    func run() async -> Bool { false }
}
