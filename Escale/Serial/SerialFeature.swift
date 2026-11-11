import SwiftUI
import EscaleCore

/// Module Série (termios). Ne s'accroche à l'app que par `attach` (`AppModel.terminalLaunchers`),
/// `SerialScene`, `SerialHostMenuItems`, `SerialEditorSection` et `--selftest-serial`. PROVISOIRE : squelette de la vague V1.2/V2.
@MainActor
@Observable
final class SerialFeature: AppFeature {
    @ObservationIgnored private(set) weak var model: AppModel?

    func attach(_ model: AppModel) {
        self.model = model
        // PROVISOIRE : le module ouvre la vraie source d'octets.
        model.terminalLaunchers[.serial] = { _, _ in throw SerialFeatureError.notImplemented }
    }

    func shutdown() async {}
}

enum SerialFeatureError: Error, CustomStringConvertible {
    case notImplemented
    var description: String { "Série (termios) : pas encore disponible." }
}

/// Feuilles, inspecteurs, bandeaux du module (fenêtre principale).
struct SerialScene: ViewModifier {
    let model: AppModel
    func body(content: Content) -> some View { content }
}

/// Entrées du menu contextuel d'un hôte de ce protocole (barre latérale).
struct SerialHostMenuItems: View {
    let model: AppModel
    let host: HostProfile
    var body: some View { EmptyView() }
}

/// Section de l'éditeur d'hôte quand le protocole est `.serial`.
struct SerialEditorSection: View {
    @Binding var settings: SerialSettings
    let model: AppModel
    var body: some View { EmptyView() }
}
