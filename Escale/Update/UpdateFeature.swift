import SwiftUI
import Observation
import EscaleCore

// PROVISOIRE (squelette M4) : à remplacer par le flux distribution. Contrat figé : noms de types et
// initialiseurs appelés depuis `Escale/Features/AppFeature.swift` et `AppModel`.

/// M4 : mises à jour (Sparkle).
@MainActor
@Observable
final class UpdateFeature: AppFeature {
    @ObservationIgnored private(set) weak var model: AppModel?
    func attach(_ model: AppModel) { self.model = model }
    func shutdown() async {}
}

struct UpdateCommands: Commands {
    let model: AppModel
    var body: some Commands { EmptyCommands() }
}

struct UpdateScene: ViewModifier {
    let model: AppModel
    func body(content: Content) -> some View { content }
}
