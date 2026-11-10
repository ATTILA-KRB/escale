import Foundation

/// Erreurs des opérations pures sur la bibliothèque.
public enum HostLibraryError: Error, Equatable, Sendable {
    case unknownHost(UUID)
    case unknownFolder(UUID)
    case duplicateID(UUID)
    /// Déplacer un dossier dans lui-même ou dans un de ses descendants.
    case cycle
}

// Toutes les opérations modifient la valeur sans effet de bord : à l'appelant de sauvegarder.
extension HostLibrary {
    // MARK: Hôtes

    public mutating func addHost(_ host: HostProfile) throws {
        guard !hosts.contains(where: { $0.id == host.id }) else { throw HostLibraryError.duplicateID(host.id) }
        if let f = host.folderID { try requireFolder(f) }
        hosts.append(host)
    }

    /// Remplace l'hôte de même `id`.
    public mutating func updateHost(_ host: HostProfile) throws {
        guard let i = hosts.firstIndex(where: { $0.id == host.id }) else { throw HostLibraryError.unknownHost(host.id) }
        if let f = host.folderID { try requireFolder(f) }
        hosts[i] = host
    }

    public mutating func removeHost(id: UUID) throws {
        guard let i = hosts.firstIndex(where: { $0.id == id }) else { throw HostLibraryError.unknownHost(id) }
        hosts.remove(at: i)
    }

    /// `folderID == nil` : racine.
    public mutating func moveHost(id: UUID, to folderID: UUID?) throws {
        guard let i = hosts.firstIndex(where: { $0.id == id }) else { throw HostLibraryError.unknownHost(id) }
        if let f = folderID { try requireFolder(f) }
        hosts[i].folderID = folderID
    }

    // MARK: Dossiers

    @discardableResult
    public mutating func addFolder(name: String, parentID: UUID? = nil, id: UUID = UUID()) throws -> HostFolder {
        guard !folders.contains(where: { $0.id == id }) else { throw HostLibraryError.duplicateID(id) }
        if let p = parentID { try requireFolder(p) }
        let folder = HostFolder(id: id, name: name, parentID: parentID)
        folders.append(folder)
        return folder
    }

    public mutating func renameFolder(id: UUID, to name: String) throws {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { throw HostLibraryError.unknownFolder(id) }
        folders[i].name = name
    }

    /// Supprime le dossier ; ses sous-dossiers et ses hôtes remontent au parent. Aucun hôte n'est supprimé.
    public mutating func removeFolder(id: UUID) throws {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { throw HostLibraryError.unknownFolder(id) }
        let parent = folders[i].parentID
        folders.remove(at: i)
        for j in folders.indices where folders[j].parentID == id { folders[j].parentID = parent }
        for j in hosts.indices where hosts[j].folderID == id { hosts[j].folderID = parent }
    }

    /// Déplace un dossier ; refuse de le placer dans lui-même ou un de ses descendants.
    public mutating func moveFolder(id: UUID, to parentID: UUID?) throws {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { throw HostLibraryError.unknownFolder(id) }
        if let p = parentID {
            try requireFolder(p)
            if p == id || isDescendant(p, of: id) { throw HostLibraryError.cycle }
        }
        folders[i].parentID = parentID
    }

    // MARK: Lecture

    /// Sous-dossiers directs, triés par nom (localisé, insensible à la casse).
    public func childFolders(of parentID: UUID?) -> [HostFolder] {
        folders.filter { $0.parentID == parentID }.sorted {
            Self.nameOrder($0.name, $1.name, $0.id, $1.id)
        }
    }

    /// Hôtes directs d'un dossier (`nil` = racine), triés par nom.
    public func hosts(in folderID: UUID?) -> [HostProfile] {
        hosts.filter { $0.folderID == folderID }.sorted {
            Self.nameOrder($0.name, $1.name, $0.id, $1.id)
        }
    }

    /// Chemin de la racine jusqu'au dossier inclus. Vide si le dossier est inconnu.
    /// Protégé contre un fichier corrompu contenant un cycle.
    public func folderPath(of id: UUID) -> [HostFolder] {
        var path: [HostFolder] = []
        var seen = Set<UUID>()
        var current: UUID? = id
        while let c = current, seen.insert(c).inserted, let f = folders.first(where: { $0.id == c }) {
            path.append(f)
            current = f.parentID
        }
        return path.reversed()
    }

    // MARK: Interne

    private func requireFolder(_ id: UUID) throws {
        guard folders.contains(where: { $0.id == id }) else { throw HostLibraryError.unknownFolder(id) }
    }

    private func isDescendant(_ candidate: UUID, of ancestor: UUID) -> Bool {
        var seen = Set<UUID>()
        var current: UUID? = candidate
        while let c = current, seen.insert(c).inserted {
            if c == ancestor { return true }
            current = folders.first(where: { $0.id == c })?.parentID
        }
        return false
    }

    private static func nameOrder(_ a: String, _ b: String, _ ida: UUID, _ idb: UUID) -> Bool {
        switch a.localizedCaseInsensitiveCompare(b) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return ida.uuidString < idb.uuidString
        }
    }
}
