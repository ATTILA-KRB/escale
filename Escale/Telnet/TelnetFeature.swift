import SwiftUI
import EscaleCore

/// Module Telnet. Ne s'accroche à l'app que par `attach` (`AppModel.terminalLaunchers`),
/// `TelnetScene`, `TelnetHostMenuItems`, `TelnetEditorSection` et `--selftest-telnet`. PROVISOIRE : squelette de la vague V1.2/V2.
@MainActor
@Observable
final class TelnetFeature: AppFeature {
    @ObservationIgnored private(set) weak var model: AppModel?

    func attach(_ model: AppModel) {
        self.model = model
        // PROVISOIRE : le module ouvre la vraie source d'octets.
        model.terminalLaunchers[.telnet] = { _, _ in throw TelnetFeatureError.notImplemented }
    }

    func shutdown() async {}
}

enum TelnetFeatureError: Error, CustomStringConvertible {
    case notImplemented
    var description: String { "Telnet : pas encore disponible." }
}

/// Feuilles, inspecteurs, bandeaux du module (fenêtre principale).
struct TelnetScene: ViewModifier {
    let model: AppModel
    func body(content: Content) -> some View { content }
}

/// Entrées du menu contextuel d'un hôte de ce protocole (barre latérale).
struct TelnetHostMenuItems: View {
    let model: AppModel
    let host: HostProfile
    var body: some View { EmptyView() }
}

/// Section de l'éditeur d'hôte quand le protocole est `.telnet`.
struct TelnetEditorSection: View {
    @Binding var settings: TelnetSettings
    let model: AppModel
    var body: some View { EmptyView() }
}
