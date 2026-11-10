import Foundation

/// Répond aux mots de passe depuis le `SecretStore` (profil `.keychainPassword(account:)`) et délègue tout le reste
/// (phrase de passe, OTP, confirmation de clé d'hôte, secret absent ou refusé) à un gestionnaire d'interaction (UI).
///
/// - Un mot de passe mémorisé n'est proposé qu'au 1er passage d'une invite : si ssh la repose (secret refusé),
///   l'invite est déléguée à l'UI (`attempt` ≥ 2), jamais re-proposée en boucle.
/// - Une proposition « mémoriser » (`.secret(_, remember: true)`) n'est écrite dans le store qu'APRÈS une connexion réussie
///   (`authenticationSucceeded()`), et oubliée si la connexion échoue.
public actor StoredSecretResponder: AskpassResponder {
    public typealias InteractionHandler = @Sendable (AskpassRequest) async -> AskpassDecision

    private let auth: HostProfile.Auth
    private let store: any SecretStore
    private let interaction: InteractionHandler
    private var pending: (account: String, secret: Secret)?

    public init(auth: HostProfile.Auth, store: any SecretStore, interaction: @escaping InteractionHandler) {
        self.auth = auth; self.store = store; self.interaction = interaction
    }

    public func respond(to request: AskpassRequest) async -> AskpassDecision {
        if case .keychainPassword(let account) = auth, case .password = request.kind, request.attempt == 1 {
            // Une erreur du store (Keychain verrouillé…) n'est pas fatale : on retombe sur l'UI, sans détail.
            if let stored = try? await store.secret(for: account) { return .secret(stored, remember: false) }
        }
        let decision = await interaction(request)
        switch decision {
        case .secret(let secret, let remember):
            if remember, case .keychainPassword(let account) = auth, case .password = request.kind {
                pending = (account, secret)
            }
        case .accept, .cancel:
            break
        }
        return decision
    }

    public func authenticationSucceeded() async {
        guard let p = pending else { return }
        pending = nil
        try? await store.setSecret(p.secret, for: p.account)
    }

    public func authenticationFailed() async { pending = nil }
}
