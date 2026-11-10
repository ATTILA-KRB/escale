import Foundation

/// Un hôte enregistré. Aucun secret ici : uniquement des références (Keychain, fichier de clé).
public struct HostProfile: Codable, Hashable, Identifiable, Sendable {
    public enum Auth: Codable, Hashable, Sendable {
        /// Laisse OpenSSH décider (agent, clés par défaut, ~/.ssh/config).
        case openSSHDefaults
        /// Fichier de clé privée explicite.
        case keyFile(path: String)
        /// Mot de passe lu dans le Keychain via askpass.
        case keychainPassword(account: String)
    }

    public var id: UUID
    public var name: String
    /// Nom d'hôte, IP, ou alias de ~/.ssh/config.
    public var host: String
    public var port: Int?
    public var user: String?
    public var auth: Auth
    /// Bastions traversés dans l'ordre (ProxyJump), au format `user@host:port`.
    public var jumpHosts: [String]
    public var tags: [String]

    public init(
        id: UUID = UUID(), name: String, host: String, port: Int? = nil, user: String? = nil,
        auth: Auth = .openSSHDefaults, jumpHosts: [String] = [], tags: [String] = []
    ) {
        self.id = id; self.name = name; self.host = host; self.port = port; self.user = user
        self.auth = auth; self.jumpHosts = jumpHosts; self.tags = tags
    }

    /// Cible passée à ssh (`user@host` ou `host`).
    public var target: String { user.map { "\($0)@\(host)" } ?? host }
}
