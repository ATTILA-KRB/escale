import SwiftUI
import Observation
import EscaleCore

// PROVISOIRE (squelette M3) : à remplacer par le flux multi-exécution. Contrat figé : noms de types et
// initialiseurs appelés depuis `Escale/Features/AppFeature.swift` et `AppModel`.

/// M3 : diffusion de la saisie vers plusieurs panneaux, commande lancée sur plusieurs hôtes.
@MainActor
@Observable
final class MultiExecFeature: AppFeature {
    @ObservationIgnored private(set) weak var model: AppModel?
    func attach(_ model: AppModel) { self.model = model }
    func shutdown() async {}
}

struct MultiExecCommands: Commands {
    let model: AppModel
    var body: some Commands { EmptyCommands() }
}

struct MultiExecScene: ViewModifier {
    let model: AppModel
    func body(content: Content) -> some View { content }
}

struct MultiExecSelectionMenuItems: View {
    let model: AppModel
    let hosts: [HostProfile]
    var body: some View { EmptyView() }
}

/// `--selftest-multiexec <dossier>`.
@MainActor
struct MultiExecSelfTest {
    let directory: String
    let model: AppModel
    func run() async -> Bool { false }
}
