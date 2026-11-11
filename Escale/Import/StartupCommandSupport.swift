import SwiftUI
import EscaleCore

/// Section « Commande de connexion » de l'éditeur d'hôte (M5 : import MobaXterm « Execute command », PuTTY `RemoteCommand`).
struct StartupCommandEditorSection: View {
    @Binding var text: String

    var body: some View {
        Section("Commande de connexion") {
            TextField("Commande", text: $text, prompt: Text("ex. tmux attach || tmux new"))
                .disableAutocorrection(true)
                .font(.system(.body, design: .monospaced))
            Text("Tapée dans le shell à chaque ouverture, puis le shell reste ouvert. Une seule ligne ; séparez les commandes par « ; ».")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension AppModel {
    /// Envoie la commande de connexion de l'hôte au shell qui vient de s'ouvrir (voir `StartupCommand` pour la sémantique).
    /// Court délai : le temps que le shell distant démarre et lise l'entrée (sinon l'écho du pty local la mélangerait).
    func sendStartupCommand(for pane: Pane) {
        guard case .host(let profile) = pane.kind, let data = StartupCommand.input(for: profile.startupCommand) else { return }
        let session = pane.session
        Task { @MainActor [weak session] in
            try? await Task.sleep(nanoseconds: Self.startupCommandDelay)
            session?.write(data)
        }
    }

    static var startupCommandDelay: UInt64 { 500_000_000 }
}
