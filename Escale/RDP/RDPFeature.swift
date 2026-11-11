import SwiftUI
import EscaleCore

/// Module Bureau à distance (RDP). Ne s'accroche à l'app que par `attach` (`AppModel.externalOpeners`),
/// `RDPScene`, `RDPHostMenuItems`, `RDPEditorSection` et `--selftest-rdp`. PROVISOIRE : squelette de la vague V1.2/V2.
@MainActor
@Observable
final class RDPFeature: AppFeature {
    @ObservationIgnored private(set) weak var model: AppModel?

    func attach(_ model: AppModel) {
        self.model = model
        // PROVISOIRE : le module ouvre la fenêtre / l'app de bureau distant.
        model.externalOpeners[.rdp] = { _ in }
    }

    func shutdown() async {}
}

enum RDPFeatureError: Error, CustomStringConvertible {
    case notImplemented
    var description: String { "Bureau à distance (RDP) : pas encore disponible." }
}

/// Feuilles, inspecteurs, bandeaux du module (fenêtre principale).
struct RDPScene: ViewModifier {
    let model: AppModel
    func body(content: Content) -> some View { content }
}

/// Entrées du menu contextuel d'un hôte de ce protocole (barre latérale).
struct RDPHostMenuItems: View {
    let model: AppModel
    let host: HostProfile
    var body: some View { EmptyView() }
}

/// Section de l'éditeur d'hôte quand le protocole est `.rdp`.
struct RDPEditorSection: View {
    @Binding var settings: RDPSettings
    let model: AppModel
    var body: some View { EmptyView() }
}
