import SwiftUI
import Observation
import EscaleCore

// PROVISOIRE (squelette M3) : à remplacer par le flux tunnels. Contrat figé : noms de types et initialiseurs
// appelés depuis `Escale/Features/AppFeature.swift`, `AppModel` et `HostEditorSheet`.

/// M3 : gestionnaire de tunnels L/R/D (ouverture, état, rétablissement après reconnexion).
@MainActor
@Observable
final class TunnelFeature: AppFeature {
    @ObservationIgnored private(set) weak var model: AppModel?
    func attach(_ model: AppModel) { self.model = model }
    func shutdown() async {}
}

struct TunnelCommands: Commands {
    let model: AppModel
    var body: some Commands { EmptyCommands() }
}

struct TunnelScene: ViewModifier {
    let model: AppModel
    func body(content: Content) -> some View { content }
}

struct TunnelHostMenuItems: View {
    let model: AppModel
    let host: HostProfile
    var body: some View { EmptyView() }
}

/// Section « Tunnels » de la feuille d'édition d'hôte (la liste est enregistrée avec l'hôte).
struct TunnelEditorSection: View {
    @Binding var tunnels: [TunnelSpec]
    var body: some View { EmptyView() }
}

/// `--selftest-tunnels <dossier>`.
@MainActor
struct TunnelSelfTest {
    let directory: String
    let model: AppModel
    func run() async -> Bool { false }
}
