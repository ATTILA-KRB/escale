import SwiftUI
import EscaleCore

/// Section de l'éditeur d'hôte propre au protocole non SSH (une par module, voir `<Module>EditorSection`).
struct ProtocolEditorSection: View {
    let model: AppModel
    let connectionProtocol: ConnectionProtocol
    @Binding var serial: SerialSettings
    @Binding var telnet: TelnetSettings
    @Binding var vnc: VNCSettings
    @Binding var rdp: RDPSettings

    var body: some View {
        switch connectionProtocol {
        case .ssh: EmptyView()
        case .serial: SerialEditorSection(settings: $serial, model: model)
        case .telnet: TelnetEditorSection(settings: $telnet, model: model)
        case .vnc: VNCEditorSection(settings: $vnc, model: model)
        case .rdp: RDPEditorSection(settings: $rdp, model: model)
        }
    }

    /// Erreurs de validation du protocole courant.
    static func errors(_ p: ConnectionProtocol, serial: SerialSettings, telnet: TelnetSettings, vnc: VNCSettings,
                       rdp: RDPSettings) -> [String] {
        switch p {
        case .ssh: []
        case .serial: SerialSettings.validationErrors(serial)
        case .telnet: TelnetSettings.validationErrors(telnet)
        case .vnc: VNCSettings.validationErrors(vnc)
        case .rdp: RDPSettings.validationErrors(rdp)
        }
    }
}
