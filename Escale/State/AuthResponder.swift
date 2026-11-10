import Foundation
import EscaleCore

/// Comptes et magasin Keychain de l'app.
///
/// `useDataProtectionKeychain = false` : vérifié sur ce poste, un build signé ad hoc (comme `xcodebuild` ici, sans
/// droit `keychain-access-groups`) reçoit `errSecMissingEntitlement` (-34018) sur le trousseau « data protection » ;
/// seul le trousseau de session (fichier) accepte l'ajout, la lecture et la suppression sans fenêtre. Un build signé
/// avec un profil de provisionnement pourra passer à `true`.
enum AuthKeychain {
    static let defaultService = "com.attila-krb.Escale"
    static let useDataProtectionKeychain = false

    static func makeStore(service: String?) -> KeychainSecretStore {
        KeychainSecretStore(service: service ?? defaultService, useDataProtectionKeychain: useDataProtectionKeychain)
    }

    /// Compte du mot de passe : dérivé de l'identifiant de l'hôte (jamais du nom, qui peut changer).
    static func passwordAccount(for hostID: UUID) -> String { "host-\(hostID.uuidString)" }
    /// Compte de la phrase de passe de la clé de l'hôte.
    static func passphraseAccount(for hostID: UUID) -> String { "host-\(hostID.uuidString)-passphrase" }

    /// Supprime tous les secrets d'un hôte (suppression de l'hôte). Les erreurs sont renvoyées, pas avalées.
    static func forgetAll(hostID: UUID, store: any SecretStore) async -> String? {
        var failure: String?
        for account in [passwordAccount(for: hostID), passphraseAccount(for: hostID)] {
            do { try await store.removeSecret(for: account) } catch { failure = "\(error)" }
        }
        return failure
    }
}

/// Responder de l'app : mots de passe via `StoredSecretResponder` du cœur (profil « Trousseau »), et
/// mémorisation / réutilisation de la phrase de passe de clé (que le cœur ne gère pas), toujours après un succès.
actor AppAskpassResponder: AskpassResponder {
    private let inner: StoredSecretResponder
    private let store: any SecretStore
    private let passphraseAccount: String
    private let interaction: StoredSecretResponder.InteractionHandler
    private var pendingPassphrase: Secret?

    init(auth: HostProfile.Auth, hostID: UUID, store: any SecretStore, interaction: @escaping StoredSecretResponder.InteractionHandler) {
        inner = StoredSecretResponder(auth: auth, store: store, interaction: interaction)
        self.store = store
        passphraseAccount = AuthKeychain.passphraseAccount(for: hostID)
        self.interaction = interaction
    }

    func respond(to request: AskpassRequest) async -> AskpassDecision {
        guard case .passphrase = request.kind else { return await inner.respond(to: request) }
        // Phrase mémorisée : proposée une seule fois ; si ssh la repose (refusée), c'est à l'utilisateur.
        if request.attempt == 1, let stored = try? await store.secret(for: passphraseAccount) {
            return .secret(stored, remember: false)
        }
        let decision = await interaction(request)
        if case .secret(let s, let remember) = decision { pendingPassphrase = remember ? s : nil }
        return decision
    }

    func authenticationSucceeded() async {
        await inner.authenticationSucceeded()
        if let p = pendingPassphrase {
            pendingPassphrase = nil
            try? await store.setSecret(p, for: passphraseAccount)
        }
    }

    func authenticationFailed() async {
        pendingPassphrase = nil
        await inner.authenticationFailed()
    }
}

/// Pont entre les invites d'un lien SSH et la file de dialogues. Créé avant le transport (le gestionnaire
/// d'interaction le capture) ; le lien le consulte après un échec pour savoir si une saisie était requise.
@MainActor
final class AuthInteractionGate {
    let hostID: UUID
    let hostName: String
    let auth: HostProfile.Auth
    private unowned let center: AuthDialogCenter

    /// Vrai pendant une reconnexion automatique : aucune feuille, l'invite est refusée et `needsInput` est levé.
    var unattended = false
    private(set) var needsInput = false

    init(profile: HostProfile, center: AuthDialogCenter) {
        hostID = profile.id; hostName = profile.name; auth = profile.auth; self.center = center
    }

    func resetNeedsInput() { needsInput = false }

    func interact(_ request: AskpassRequest) async -> AskpassDecision {
        // Clé d'hôte modifiée : jamais de confirmation (invariant 10) ; le cœur la refuse déjà, ceci est une ceinture.
        if case .hostKeyChanged = request.kind { return .cancel }
        if unattended {
            needsInput = true
            return .cancel
        }
        let canRemember: Bool
        switch request.kind {
        case .password: canRemember = { if case .keychainPassword = auth { true } else { false } }()
        case .passphrase: canRemember = true
        default: canRemember = false
        }
        return await center.present(request: request, hostID: hostID, hostName: hostName, canRemember: canRemember)
    }
}
