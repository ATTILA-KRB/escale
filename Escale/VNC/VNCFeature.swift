import SwiftUI
import EscaleCore

/// Module VNC. Ne s'accroche à l'app que par `attach` (`AppModel.externalOpeners`),
/// `VNCScene`, `VNCHostMenuItems`, `VNCEditorSection` et `--selftest-vnc`. PROVISOIRE : squelette de la vague V1.2/V2.
@MainActor
@Observable
final class VNCFeature: AppFeature {
    @ObservationIgnored private(set) weak var model: AppModel?

    func attach(_ model: AppModel) {
        self.model = model
        // PROVISOIRE : le module ouvre la fenêtre / l'app de bureau distant.
        model.externalOpeners[.vnc] = { _ in }
    }

    func shutdown() async {}
}

enum VNCFeatureError: Error, CustomStringConvertible {
    case notImplemented
    var description: String { "VNC : pas encore disponible." }
}

/// Feuilles, inspecteurs, bandeaux du module (fenêtre principale).
struct VNCScene: ViewModifier {
    let model: AppModel
    func body(content: Content) -> some View { content }
}

/// Entrées du menu contextuel d'un hôte de ce protocole (barre latérale).
struct VNCHostMenuItems: View {
    let model: AppModel
    let host: HostProfile
    var body: some View { EmptyView() }
}

/// Section de l'éditeur d'hôte quand le protocole est `.vnc`.
struct VNCEditorSection: View {
    @Binding var settings: VNCSettings
    let model: AppModel
    var body: some View { EmptyView() }
}
