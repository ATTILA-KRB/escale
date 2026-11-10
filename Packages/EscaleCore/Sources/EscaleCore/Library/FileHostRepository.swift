import Foundation

/// Erreurs du dépôt de bibliothèque sur fichier.
public enum HostRepositoryError: Error, Equatable, Sendable {
    /// Le fichier existe mais n'est pas un JSON de bibliothèque valide. Il n'a pas été modifié.
    case corrupted(path: String, reason: String)
    /// Le fichier vient d'une version plus récente de l'app. Il n'a pas été modifié.
    case unsupportedVersion(found: Int, supported: Int)
    /// Erreur d'entrée/sortie (permissions, disque plein…).
    case io(path: String, reason: String)
}

/// Dépôt de bibliothèque : un fichier JSON versionné à une URL injectée.
///
/// Garanties :
/// - écriture atomique (fichier temporaire voisin + `rename`), permissions 0600 ;
/// - fichier absent → bibliothèque vide ;
/// - fichier illisible ou de version future → `load` lève une erreur, ne touche à rien ;
///   le `save` suivant met d'abord le fichier de côté (`<nom>.corrupt-<horodatage>-<id>`)
///   au lieu de l'écraser ;
/// - JSON stable (clés triées, indenté) pour des diffs exploitables.
public actor FileHostRepository: HostRepository {
    /// Version de format écrite par cette version de l'app.
    public static let currentVersion = 1

    public nonisolated let url: URL
    private let now: @Sendable () -> Date

    public init(url: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
    }

    private struct Envelope: Codable {
        var version: Int
        var folders: [HostFolder]
        var hosts: [HostProfile]
    }

    private struct VersionProbe: Decodable { var version: Int }

    // MARK: HostRepository

    public func load() async throws -> HostLibrary {
        guard let data = try readExisting() else { return HostLibrary() }
        return try Self.decode(data, path: url.path)
    }

    public func save(_ library: HostLibrary) async throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            throw HostRepositoryError.io(path: dir.path, reason: error.localizedDescription)
        }

        // Fichier existant mais illisible : on le met de côté avant d'écrire.
        if let data = try readExisting() {
            do { _ = try Self.decode(data, path: url.path) } catch is HostRepositoryError {
                try setAside()
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let payload: Data
        do {
            payload = try encoder.encode(Envelope(version: Self.currentVersion,
                                                  folders: library.folders, hosts: library.hosts))
        } catch {
            throw HostRepositoryError.io(path: url.path, reason: "encodage : \(error.localizedDescription)")
        }

        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            guard fm.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw HostRepositoryError.io(path: tmp.path, reason: "création impossible")
            }
            let handle = try FileHandle(forWritingTo: tmp)
            do {
                try handle.write(contentsOf: payload)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            if Darwin.rename(tmp.path, url.path) != 0 {
                throw HostRepositoryError.io(path: url.path, reason: String(cString: strerror(errno)))
            }
        } catch {
            try? fm.removeItem(at: tmp)
            if let e = error as? HostRepositoryError { throw e }
            throw HostRepositoryError.io(path: url.path, reason: error.localizedDescription)
        }
    }

    // MARK: Interne

    /// `nil` si le fichier n'existe pas.
    private func readExisting() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { return try Data(contentsOf: url) } catch {
            throw HostRepositoryError.io(path: url.path, reason: error.localizedDescription)
        }
    }

    private static func decode(_ data: Data, path: String) throws -> HostLibrary {
        let decoder = JSONDecoder()
        let probe: VersionProbe
        do { probe = try decoder.decode(VersionProbe.self, from: data) } catch {
            throw HostRepositoryError.corrupted(path: path, reason: String(describing: error))
        }
        if probe.version > currentVersion {
            throw HostRepositoryError.unsupportedVersion(found: probe.version, supported: currentVersion)
        }
        guard probe.version >= 1 else {
            throw HostRepositoryError.corrupted(path: path, reason: "version invalide : \(probe.version)")
        }
        do {
            let env = try decoder.decode(Envelope.self, from: data)
            return HostLibrary(folders: env.folders, hosts: env.hosts)
        } catch {
            throw HostRepositoryError.corrupted(path: path, reason: String(describing: error))
        }
    }

    /// Renomme le fichier courant en `<nom>.corrupt-<horodatage>-<id court>`.
    private func setAside() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withFractionalSeconds]
        let stamp = formatter.string(from: now())
            .replacingOccurrences(of: ":", with: "").replacingOccurrences(of: ".", with: "")
        let suffix = UUID().uuidString.prefix(8)
        let dest = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)-\(suffix)")
        do { try FileManager.default.moveItem(at: url, to: dest) } catch {
            throw HostRepositoryError.io(path: url.path, reason: "mise de côté impossible : \(error.localizedDescription)")
        }
    }
}
