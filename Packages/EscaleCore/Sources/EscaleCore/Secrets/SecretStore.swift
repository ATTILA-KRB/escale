import Foundation

/// Un secret (mot de passe, phrase de passe). Jamais journalisé : toutes les descriptions sont masquées.
public struct Secret: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let data: Data

    public init(data: Data) { self.data = data }
    public init(_ string: String) { self.data = Data(string.utf8) }

    /// Contenu en texte (UTF-8). À n'utiliser que pour le passer à ssh.
    public var string: String { String(decoding: data, as: UTF8.self) }
    public var isEmpty: Bool { data.isEmpty }

    public var description: String { "Secret(masqué)" }
    public var debugDescription: String { "Secret(masqué)" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// Erreurs d'un magasin de secrets. Ne contiennent jamais de secret ni de nom de compte.
public enum SecretStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Échec Keychain (code `OSStatus`).
    case keychain(status: Int32)
    /// Donnée stockée illisible.
    case invalidData

    public var description: String {
        switch self {
        case .keychain(let s): "erreur Keychain (OSStatus \(s))"
        case .invalidData: "donnée Keychain illisible"
        }
    }
}

/// Magasin de secrets indexé par compte. Invariant 7 : les secrets ne vivent que là, jamais dans les modèles ni sur disque.
public protocol SecretStore: Sendable {
    /// `nil` si aucun secret n'est enregistré pour ce compte.
    func secret(for account: String) async throws -> Secret?
    func setSecret(_ secret: Secret, for account: String) async throws
    /// Idempotent : supprimer un compte absent n'est pas une erreur.
    func removeSecret(for account: String) async throws
}

/// Magasin en mémoire (tests, aperçus). Rien n'est persisté.
public actor InMemorySecretStore: SecretStore {
    private var items: [String: Secret] = [:]

    public init(_ initial: [String: Secret] = [:]) { items = initial }

    public func secret(for account: String) async throws -> Secret? { items[account] }
    public func setSecret(_ secret: Secret, for account: String) async throws { items[account] = secret }
    public func removeSecret(for account: String) async throws { items[account] = nil }

    /// Comptes présents (pour les assertions de test ; jamais les valeurs).
    public var accounts: Set<String> { Set(items.keys) }
}
