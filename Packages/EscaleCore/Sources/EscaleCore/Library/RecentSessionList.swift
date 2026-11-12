import Foundation

/// Sessions ouvertes récemment (page d'accueil) : identifiants d'hôtes de la bibliothèque, du plus récent au plus ancien.
/// Aucune donnée de connexion ni secret : seulement l'identifiant et la date.
public struct RecentSessionList: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var hostID: UUID
        public var date: Date
        public init(hostID: UUID, date: Date) { self.hostID = hostID; self.date = date }
    }

    public static let fileName = "recents.json"
    public static let currentVersion = 1

    public var version = RecentSessionList.currentVersion
    public private(set) var entries: [Entry] = []
    /// Nombre d'entrées conservées.
    public var limit: Int { 12 }

    public init() {}

    private enum CodingKeys: String, CodingKey { case version, entries }

    /// Place l'hôte en tête (une seule entrée par hôte), tronque à `limit`.
    public mutating func record(_ hostID: UUID, at date: Date = Date()) {
        entries.removeAll { $0.hostID == hostID }
        entries.insert(Entry(hostID: hostID, date: date), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    /// Retire les hôtes qui n'existent plus ; vrai si la liste a changé.
    @discardableResult
    public mutating func prune(keeping known: Set<UUID>) -> Bool {
        let before = entries.count
        entries.removeAll { !known.contains($0.hostID) }
        return entries.count != before
    }

    public mutating func clear() { entries.removeAll() }

    public static func url(besideLibrary library: URL) -> URL {
        library.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    /// Lecture tolérante : fichier absent, illisible ou de version inconnue = liste vide (donnée de confort).
    public static func load(from url: URL) -> RecentSessionList {
        guard let data = try? Data(contentsOf: url) else { return RecentSessionList() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var list = try? decoder.decode(RecentSessionList.self, from: data), list.version == currentVersion else { return RecentSessionList() }
        if list.entries.count > list.limit { list.entries.removeLast(list.entries.count - list.limit) }
        return list
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
