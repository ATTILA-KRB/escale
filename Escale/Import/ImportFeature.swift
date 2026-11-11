import SwiftUI
import Observation
import EscaleCore

// PROVISOIRE (squelette M5) : à remplacer par le flux imports. Contrat figé : noms de types et
// initialiseurs appelés depuis `Escale/Features/AppFeature.swift` et `AppModel`.

/// M5 : import de sessions d'autres clients (MobaXterm, PuTTY…), en lecture seule.
@MainActor
@Observable
final class ImportFeature: AppFeature {
    @ObservationIgnored private(set) weak var model: AppModel?
    func attach(_ model: AppModel) { self.model = model }
    func shutdown() async {}
}

struct ImportCommands: Commands {
    let model: AppModel
    var body: some Commands { EmptyCommands() }
}

struct ImportScene: ViewModifier {
    let model: AppModel
    func body(content: Content) -> some View { content }
}

/// `--selftest-import <dossier>`.
@MainActor
struct ImportSelfTest {
    let directory: String
    let model: AppModel
    func run() async -> Bool { false }
}
