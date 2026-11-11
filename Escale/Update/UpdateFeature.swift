import SwiftUI
import Observation
import Sparkle
import EscaleCore

/// M4 : mises à jour (Sparkle 2).
///
/// L'updater n'est créé que si : l'app ne tourne pas en mode selftest (`LaunchOptions.isSelfTest`, aucune
/// fenêtre ni réseau parasite) ET `SUFeedURL` (Info.plist, issu de la variable de build `ESCALE_FEED_URL`)
/// est non vide. Sinon la commande de menu reste visible mais grisée.
@MainActor
@Observable
final class UpdateFeature: AppFeature {
    @ObservationIgnored private(set) weak var model: AppModel?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    /// Vrai quand une vérification peut être lancée (updater actif et libre).
    private(set) var canCheckForUpdates = false

    /// URL de flux déclarée dans l'Info.plist (nil si vide ou absente).
    nonisolated static func configuredFeedURL(_ info: [String: Any]? = Bundle.main.infoDictionary) -> URL? {
        guard let raw = (info?["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, let url = URL(string: raw), url.scheme != nil else { return nil }
        return url
    }

    func attach(_ model: AppModel) {
        self.model = model
        guard !model.options.isSelfTest, Self.configuredFeedURL() != nil else { return }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller = c
        canCheckForUpdates = c.updater.canCheckForUpdates
        observation = c.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    func shutdown() async {}

    /// Vérification demandée par l'utilisateur (menu).
    func checkForUpdates() { controller?.checkForUpdates(nil) }
}

struct UpdateCommands: Commands {
    let model: AppModel
    var body: some Commands {
        // Menu de l'app, juste après « À propos d'Escale ».
        CommandGroup(after: .appInfo) {
            Button("Rechercher les mises à jour…") { model.updates.checkForUpdates() }
                .disabled(!model.updates.canCheckForUpdates)
        }
    }
}

struct UpdateScene: ViewModifier {
    let model: AppModel
    func body(content: Content) -> some View { content }
}
