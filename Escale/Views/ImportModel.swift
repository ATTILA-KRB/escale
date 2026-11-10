import Foundation
import Observation
import EscaleCore

/// État de la feuille « Importer depuis ~/.ssh/config… » (aussi piloté directement par l'auto-test).
/// Lecture seule stricte : le fichier source n'est jamais ouvert en écriture ni créé.
@MainActor
@Observable
final class ImportModel: Identifiable {
    nonisolated let id = UUID()
    let source: URL
    private(set) var result: SSHConfigImportResult?
    /// Alias déjà présents dans la bibliothèque (grisés, non importables).
    private(set) var existing: Set<String> = []
    private(set) var error: String?
    /// Alias cochés (uniquement des entrées importables).
    var selected: Set<String> = []
    var folderID: UUID?
    private(set) var importedCount: Int?

    @ObservationIgnored private let library: LibraryStore

    static var defaultSource: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
    }

    init(library: LibraryStore, source: URL) { self.library = library; self.source = source }

    var entries: [SSHConfigEntry] { result?.entries ?? [] }
    var warnings: [String] { result?.warnings ?? [] }
    var importableCount: Int { entries.count - existing.count }

    func isImportable(_ e: SSHConfigEntry) -> Bool { !existing.contains(e.alias) }

    /// Lit et analyse le fichier source ; coche par défaut toutes les entrées nouvelles.
    func load() {
        error = nil
        guard FileManager.default.fileExists(atPath: source.path) else {
            result = nil
            error = "Aucun fichier de configuration SSH à « \(source.path) »."
            return
        }
        do {
            // Les `Include` relatifs sont résolus depuis le dossier du fichier lu (~/.ssh en production).
            let r = try SSHConfigImporter(baseDirectory: source.deletingLastPathComponent()).parse(fileAt: source)
            result = r
            let fresh = Set(library.newEntries(in: r).map(\.alias))
            existing = Set(r.entries.map(\.alias)).subtracting(fresh)
            selected = fresh
        } catch {
            result = nil
            self.error = "Lecture de « \(source.path) » impossible : \(error.localizedDescription)"
        }
    }

    /// Ajoute les entrées cochées au dossier choisi ; renvoie les hôtes ajoutés.
    @discardableResult
    func commit() -> [HostProfile] {
        guard let r = result else { return [] }
        let chosen = r.entries.filter { selected.contains($0.alias) && isImportable($0) }
        let added = library.importEntries(chosen, from: r, into: folderID)
        importedCount = added.count
        return added
    }
}
