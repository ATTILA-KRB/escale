import Foundation
import EscaleCore

// PROVISOIRE : remplacée par FileHostRepository du cœur
/// Dépôt fichier JSON minimal de la bibliothèque d'hôtes (écriture atomique).
/// Le fichier n'est créé qu'à la première sauvegarde.
struct ProvisionalJSONHostRepository: HostRepository {
    let url: URL

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Escale", isDirectory: true).appendingPathComponent("hosts.json")
    }

    func load() async throws -> HostLibrary {
        guard FileManager.default.fileExists(atPath: url.path) else { return HostLibrary() }
        return try JSONDecoder().decode(HostLibrary.self, from: Data(contentsOf: url))
    }

    func save(_ library: HostLibrary) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(library).write(to: url, options: .atomic)
    }
}
