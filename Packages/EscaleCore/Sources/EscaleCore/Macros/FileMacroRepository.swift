import Foundation

public enum MacroRepositoryError: Error, Equatable, Sendable {
    case corrupted(path: String, reason: String)
    case unsupportedVersion(found: Int, supported: Int)
    case io(path: String, reason: String)
}

/// Dépôt des macros : un fichier JSON versionné (clés triées), écriture atomique (fichier voisin + `rename`),
/// permissions 0600, même comportement que `FileHostRepository` (fichier illisible mis de côté avant d'être remplacé).
public actor FileMacroRepository {
    public static let currentVersion = 1
    public static let fileName = "macros.json"

    public nonisolated let url: URL

    public init(url: URL) { self.url = url }

    /// Fichier des macros rangé à côté de la bibliothèque d'hôtes.
    public static func url(besideLibrary library: URL) -> URL {
        library.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    private struct Envelope: Codable { var version: Int; var macros: [Macro] }
    private struct VersionProbe: Decodable { var version: Int }

    public func load() async throws -> MacroLibrary {
        guard FileManager.default.fileExists(atPath: url.path) else { return MacroLibrary() }
        let data = try readData()
        return try Self.decode(data, path: url.path)
    }

    public func save(_ library: MacroLibrary) async throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { throw MacroRepositoryError.io(path: dir.path, reason: error.localizedDescription) }

        if fm.fileExists(atPath: url.path) {
            let data = try readData()
            do { _ = try Self.decode(data, path: url.path) } catch is MacroRepositoryError { try setAside() }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let payload: Data
        do { payload = try encoder.encode(Envelope(version: Self.currentVersion, macros: library.macros)) }
        catch { throw MacroRepositoryError.io(path: url.path, reason: "encodage : \(error.localizedDescription)") }

        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            guard fm.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw MacroRepositoryError.io(path: tmp.path, reason: "création impossible")
            }
            let handle = try FileHandle(forWritingTo: tmp)
            do { try handle.write(contentsOf: payload); try handle.synchronize(); try handle.close() }
            catch { try? handle.close(); throw error }
            if Darwin.rename(tmp.path, url.path) != 0 {
                throw MacroRepositoryError.io(path: url.path, reason: String(cString: strerror(errno)))
            }
        } catch {
            try? fm.removeItem(at: tmp)
            if let e = error as? MacroRepositoryError { throw e }
            throw MacroRepositoryError.io(path: url.path, reason: error.localizedDescription)
        }
    }

    private func readData() throws -> Data {
        do { return try Data(contentsOf: url) } catch {
            throw MacroRepositoryError.io(path: url.path, reason: error.localizedDescription)
        }
    }

    private static func decode(_ data: Data, path: String) throws -> MacroLibrary {
        let decoder = JSONDecoder()
        let probe: VersionProbe
        do { probe = try decoder.decode(VersionProbe.self, from: data) }
        catch { throw MacroRepositoryError.corrupted(path: path, reason: String(describing: error)) }
        if probe.version > currentVersion { throw MacroRepositoryError.unsupportedVersion(found: probe.version, supported: currentVersion) }
        guard probe.version >= 1 else { throw MacroRepositoryError.corrupted(path: path, reason: "version invalide : \(probe.version)") }
        do { return MacroLibrary(macros: try decoder.decode(Envelope.self, from: data).macros) }
        catch { throw MacroRepositoryError.corrupted(path: path, reason: String(describing: error)) }
    }

    private func setAside() throws {
        let stamp = String(Int(Date().timeIntervalSince1970))
        let dest = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)-\(UUID().uuidString.prefix(8))")
        do { try FileManager.default.moveItem(at: url, to: dest) }
        catch { throw MacroRepositoryError.io(path: url.path, reason: "mise de côté impossible : \(error.localizedDescription)") }
    }
}
