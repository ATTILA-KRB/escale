import SwiftUI
import Observation
import EscaleCore

// PROVISOIRE (squelette M2) : à remplacer par le flux SFTP. Contrat figé : noms de types et initialiseurs
// appelés depuis `Escale/Features/AppFeature.swift` et `AppModel`.

/// M2 : navigateur SFTP latéral, transferts, édition distante.
@MainActor
@Observable
final class SFTPFeature: AppFeature {
    @ObservationIgnored private(set) weak var model: AppModel?
    func attach(_ model: AppModel) { self.model = model }
    func shutdown() async {}
}

struct SFTPCommands: Commands {
    let model: AppModel
    var body: some Commands { EmptyCommands() }
}

struct SFTPScene: ViewModifier {
    let model: AppModel
    func body(content: Content) -> some View { content }
}

struct SFTPHostMenuItems: View {
    let model: AppModel
    let host: HostProfile
    var body: some View { EmptyView() }
}

/// `--selftest-sftp <dossier>`.
@MainActor
struct SFTPSelfTest {
    let directory: String
    let model: AppModel
    func run() async -> Bool { false }
}
