import Foundation

/// Dossier de la bibliothèque d'hôtes (arborescence par `parentID`).
public struct HostFolder: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var parentID: UUID?

    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil) {
        self.id = id; self.name = name; self.parentID = parentID
    }
}

/// Tout ce que l'utilisateur a enregistré : dossiers et hôtes. Aucun secret.
public struct HostLibrary: Codable, Equatable, Sendable {
    public var folders: [HostFolder]
    public var hosts: [HostProfile]

    public init(folders: [HostFolder] = [], hosts: [HostProfile] = []) {
        self.folders = folders; self.hosts = hosts
    }
}

/// Stockage de la bibliothèque. L'app n'en connaît que ce contrat (fichier JSON en production,
/// mémoire en test).
public protocol HostRepository: Sendable {
    /// Bibliothèque vide si rien n'a encore été enregistré.
    func load() async throws -> HostLibrary
    func save(_ library: HostLibrary) async throws
}

/// Dépôt en mémoire, pour les tests et les aperçus.
public actor InMemoryHostRepository: HostRepository {
    private var library: HostLibrary
    public init(_ library: HostLibrary = HostLibrary()) { self.library = library }
    public func load() -> HostLibrary { library }
    public func save(_ library: HostLibrary) { self.library = library }
}
