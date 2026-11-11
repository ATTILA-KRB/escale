import Foundation

/// Variables simples d'une commande groupée : `{host}` (adresse), `{user}`, `{name}` (nom dans la bibliothèque).
/// Les valeurs sont substituées côté client et échappées pour le shell distant : un nom d'hôte ne peut pas
/// injecter de commande. Une valeur « ordinaire » (lettres, chiffres, `_ @ % + = : , . / -`) est insérée telle
/// quelle (elle reste valable entre guillemets) ; toute autre est entourée d'apostrophes.
public enum GroupExecTemplate {
    public static let variables = ["host", "user", "name"]

    /// Échappe `value` pour un shell POSIX.
    public static func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+=:,./-")
        if value.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Valeurs des variables d'un hôte.
    public static func values(for host: HostProfile) -> [String: String] {
        ["host": host.host, "user": host.user ?? "", "name": host.name]
    }

    /// Remplace les variables connues ; les accolades inconnues sont laissées intactes (`${HOME}`, `{1..3}`…).
    public static func expand(_ command: String, host: HostProfile) -> String {
        expand(command, values: values(for: host))
    }

    /// Même substitution avec des valeurs fournies (terminal local, tests). Un seul passage : une valeur qui
    /// contient elle-même `{user}` n'est jamais re-développée. Pas d'échappement `{{` : une accolade
    /// littérale s'écrit déjà telle quelle, seules `{host}`, `{user}` et `{name}` exactes sont remplacées.
    public static func expand(_ command: String, values: [String: String]) -> String {
        guard command.contains("{") else { return command }
        var out = ""
        var i = command.startIndex
        while i < command.endIndex {
            if command[i] == "{", let close = command[i...].firstIndex(of: "}") {
                let key = String(command[command.index(after: i)..<close])
                if variables.contains(key), let v = values[key] {
                    out += shellQuote(v)
                    i = command.index(after: close)
                    continue
                }
            }
            out.append(command[i])
            i = command.index(after: i)
        }
        return out
    }

    /// Vrai si la commande contient au moins une variable.
    public static func usesVariables(_ command: String) -> Bool {
        variables.contains { command.contains("{\($0)}") }
    }
}

/// Choix des cibles d'une exécution groupée à partir de la bibliothèque.
extension HostLibrary {
    /// Identifiants du dossier et de tous ses sous-dossiers.
    public func folderSubtree(_ id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [id]
        var frontier = [id]
        while let f = frontier.popLast() {
            for c in folders where c.parentID == f && !result.contains(c.id) { result.insert(c.id); frontier.append(c.id) }
        }
        return result
    }

    /// Hôtes d'un dossier, sous-dossiers compris (ordre de la bibliothèque).
    public func hosts(inFolder id: UUID, recursive: Bool = true) -> [HostProfile] {
        let ids = recursive ? folderSubtree(id) : [id]
        return hosts.filter { $0.folderID.map(ids.contains) ?? false }
    }

    /// Hôtes portant l'étiquette (sans tenir compte de la casse ni d'un `#` initial).
    public func hosts(withTag tag: String) -> [HostProfile] {
        let t = Self.normalizedTag(tag)
        return t.isEmpty ? [] : hosts.filter { $0.tags.contains { Self.normalizedTag($0) == t } }
    }

    /// Étiquettes utilisées, triées, avec le nombre d'hôtes.
    public var tagCounts: [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for h in hosts { for t in Set(h.tags.map(Self.normalizedTag)) where !t.isEmpty { counts[t, default: 0] += 1 } }
        return counts.map { (tag: $0.key, count: $0.value) }.sorted { $0.tag < $1.tag }
    }

    static func normalizedTag(_ t: String) -> String {
        var s = t.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("#") { s.removeFirst() }
        return s
    }
}

/// Détection de commandes qui contiennent probablement un secret : elles ne sont jamais mémorisées.
public enum CommandSecretCheck {
    /// Description du soupçon, nil si rien de suspect.
    public static func warning(for command: String) -> String? {
        let patterns = [
            #"(?i)(pass(word|wd)?|pwd|secret|token|api[_-]?key|credential)s?\s*[=:]\s*\S"#,
            #"(?i)--(pass(word|phrase)?|token|secret)[ =]\S"#,
            #"(?i)\bsshpass\b"#,
            #"(?i)\bmysql\b.*\s-p\S"#,
            #"(?i)authorization:\s*(bearer|basic)\s+\S"#,
        ]
        for p in patterns where command.range(of: p, options: .regularExpression) != nil {
            return "Cette commande semble contenir un mot de passe ou un jeton : elle ne sera pas mémorisée dans l'historique. Préférez une clé ou un fichier lu sur l'hôte."
        }
        return nil
    }
}

/// Historique des dernières commandes groupées (20), en mémoire et dans un fichier JSON. Aucun secret :
/// les commandes suspectes ne sont pas enregistrées (`CommandSecretCheck`).
public struct GroupExecHistory: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var command: String
        public var date: Date
        public var hostCount: Int
        /// Vrai si certains hôtes avaient leur propre commande (non mémorisée).
        public var hadOverrides: Bool
        public init(id: UUID = UUID(), command: String, date: Date = Date(), hostCount: Int, hadOverrides: Bool = false) {
            self.id = id; self.command = command; self.date = date; self.hostCount = hostCount; self.hadOverrides = hadOverrides
        }
    }

    public static let limit = 20
    /// Plus récente en premier.
    public private(set) var entries: [Entry] = []
    public init() {}

    /// Ajoute `command` en tête (la même commande déjà présente remonte). Retourne faux si refusée
    /// (vide ou suspecte).
    @discardableResult
    public mutating func record(_ command: String, hostCount: Int, hadOverrides: Bool = false, date: Date = Date()) -> Bool {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, CommandSecretCheck.warning(for: c) == nil else { return false }
        entries.removeAll { $0.command == c }
        entries.insert(Entry(command: c, date: Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)), hostCount: hostCount, hadOverrides: hadOverrides), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        return true
    }

    public mutating func clear() { entries = [] }

    /// Charge le fichier ; historique vide s'il est absent ou illisible (jamais bloquant).
    public static func load(from url: URL) -> GroupExecHistory {
        guard let d = try? Data(contentsOf: url) else { return GroupExecHistory() }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard var h = try? dec.decode(GroupExecHistory.self, from: d) else { return GroupExecHistory() }
        // Filtre de sécurité : un fichier édité à la main ne réintroduit pas de secret ni plus de 20 entrées.
        h.entries = Array(h.entries.filter { CommandSecretCheck.warning(for: $0.command) == nil }.prefix(limit))
        return h
    }

    /// Écriture atomique, lisible par l'utilisateur seul.
    public func save(to url: URL) throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(self).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Double Échap rapide pour quitter la diffusion. Un Échap seul est retenu (non diffusé) jusqu'à ce qu'on sache
/// s'il est suivi d'un second dans `window` : si oui, c'est le geste de sortie, aucun des deux n'est diffusé ;
/// sinon l'Échap retenu est diffusé avec un léger retard (`flushDelay`) avant toute autre saisie.
public struct DoubleEscapeDetector: Sendable {
    public enum Action: Equatable, Sendable {
        /// Diffuser normalement.
        case forward
        /// Retenir (ne pas diffuser maintenant).
        case hold
        /// Diffuser d'abord l'Échap retenu, puis cette saisie.
        case flushThenForward
        /// Geste de sortie : arrêter la diffusion, ne rien diffuser.
        case exit
    }
    public var window: TimeInterval
    private var pendingAt: TimeInterval?
    public var hasPending: Bool { pendingAt != nil }
    public init(window: TimeInterval = 0.35) { self.window = window }

    public mutating func feed(_ data: Data, now: TimeInterval) -> Action {
        if data == Data([0x1b]) {
            if let t = pendingAt, now - t <= window { pendingAt = nil; return .exit }
            pendingAt = now
            return .hold
        }
        defer { pendingAt = nil }
        return pendingAt == nil ? .forward : .flushThenForward
    }

    /// Délai écoulé sans second Échap : vrai s'il faut diffuser l'Échap retenu.
    public mutating func expire() -> Bool {
        defer { pendingAt = nil }
        return pendingAt != nil
    }
}
