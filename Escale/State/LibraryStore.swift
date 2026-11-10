import Foundation
import Observation
import EscaleCore

/// Nœud de l'arborescence de la barre latérale.
struct SidebarNode: Identifiable, Hashable {
    enum Kind: Hashable { case folder(HostFolder), host(HostProfile) }
    let kind: Kind
    var children: [SidebarNode]
    var id: UUID {
        switch kind {
        case .folder(let f): f.id
        case .host(let h): h.id
        }
    }
}

/// Bibliothèque d'hôtes observable. Chargée via `HostRepository`, sauvegardée après chaque modification
/// (sauvegardes sérialisées : la dernière écriture est toujours la plus récente).
@MainActor
@Observable
final class LibraryStore {
    private(set) var library = HostLibrary()
    private(set) var isLoaded = false
    private(set) var lastError: String?

    @ObservationIgnored private let repository: any HostRepository
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(repository: any HostRepository) { self.repository = repository }

    func load() async {
        do { library = try await repository.load() } catch { lastError = "Lecture de la bibliothèque impossible : \(error.localizedDescription)" }
        isLoaded = true
    }

    /// Attend la fin des sauvegardes en cours (tests, fermeture).
    func flush() async { await saveTask?.value }

    private func persist() {
        let snapshot = library
        let previous = saveTask
        let repo = repository
        saveTask = Task { [weak self] in
            await previous?.value
            do { try await repo.save(snapshot) } catch {
                self?.lastError = "Sauvegarde de la bibliothèque impossible : \(error.localizedDescription)"
            }
        }
    }

    // MARK: Lecture

    func host(_ id: UUID) -> HostProfile? { library.hosts.first { $0.id == id } }
    func folder(_ id: UUID) -> HostFolder? { library.folders.first { $0.id == id } }

    private func sorted<T>(_ items: [T], by name: (T) -> String) -> [T] {
        items.sorted { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }
    }

    /// Arborescence : dossiers d'abord, puis hôtes, chacun trié par nom.
    var tree: [SidebarNode] { nodes(under: nil, visited: []) }

    private func nodes(under parent: UUID?, visited: Set<UUID>) -> [SidebarNode] {
        let validFolderIDs = Set(library.folders.map(\.id))
        func parentOK(_ p: UUID?) -> Bool { p == parent || (parent == nil && p != nil && !validFolderIDs.contains(p!)) }
        let folders = sorted(library.folders.filter { parentOK($0.parentID) && !visited.contains($0.id) }, by: \.name)
        let hosts = sorted(library.hosts.filter { parentOK($0.folderID) }, by: \.name)
        return folders.map { SidebarNode(kind: .folder($0), children: nodes(under: $0.id, visited: visited.union([$0.id]))) }
            + hosts.map { SidebarNode(kind: .host($0), children: []) }
    }

    /// Chemin lisible d'un dossier (« A / B »).
    func folderPath(_ id: UUID?) -> String {
        var parts: [String] = []
        var cur = id
        var guardCount = 0
        while let c = cur, let f = folder(c), guardCount < 32 { parts.insert(f.name, at: 0); cur = f.parentID; guardCount += 1 }
        return parts.joined(separator: " / ")
    }

    var allFolderPaths: [(id: UUID, path: String)] {
        library.folders.map { ($0.id, folderPath($0.id)) }.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    // PROVISOIRE : remplacée par la recherche floue du cœur
    /// Filtre simple : sous-chaîne insensible à la casse et aux accents sur nom, hôte, utilisateur, tags, dossier.
    func search(_ query: String) -> [HostProfile] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func match(_ s: String) -> Bool { s.range(of: q, options: opts) != nil }
        return sorted(library.hosts.filter { h in
            match(h.name) || match(h.host) || (h.user.map(match) ?? false) || h.tags.contains(where: match)
                || match(folderPath(h.folderID))
        }, by: \.name)
    }

    // MARK: Modifications (chacune sauvegarde)

    func upsert(_ host: HostProfile) {
        if let i = library.hosts.firstIndex(where: { $0.id == host.id }) { library.hosts[i] = host } else { library.hosts.append(host) }
        persist()
    }

    func deleteHost(_ id: UUID) {
        library.hosts.removeAll { $0.id == id }
        persist()
    }

    @discardableResult
    func duplicateHost(_ id: UUID) -> HostProfile? {
        guard var copy = host(id) else { return nil }
        copy.id = UUID()
        copy.name += " (copie)"
        library.hosts.append(copy)
        persist()
        return copy
    }

    func moveHost(_ id: UUID, to folderID: UUID?) {
        guard let i = library.hosts.firstIndex(where: { $0.id == id }) else { return }
        library.hosts[i].folderID = folderID
        persist()
    }

    @discardableResult
    func addFolder(name: String, parentID: UUID?) -> HostFolder {
        let f = HostFolder(name: name, parentID: parentID)
        library.folders.append(f)
        persist()
        return f
    }

    func renameFolder(_ id: UUID, to name: String) {
        guard let i = library.folders.firstIndex(where: { $0.id == id }) else { return }
        library.folders[i].name = name
        persist()
    }

    /// Supprime un dossier ; ses hôtes et sous-dossiers remontent au niveau supérieur.
    func deleteFolder(_ id: UUID) {
        guard let f = folder(id) else { return }
        for i in library.hosts.indices where library.hosts[i].folderID == id { library.hosts[i].folderID = f.parentID }
        for i in library.folders.indices where library.folders[i].parentID == id { library.folders[i].parentID = f.parentID }
        library.folders.removeAll { $0.id == id }
        persist()
    }

    func hostCount(inFolder id: UUID) -> Int { library.hosts.filter { $0.folderID == id }.count }
}
