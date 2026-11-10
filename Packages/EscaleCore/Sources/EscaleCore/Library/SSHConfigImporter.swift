import Foundation

/// Aperçu d'un alias `Host` : valeurs lues dans le fichier, pour l'affichage uniquement.
/// Le profil candidat ne les copie pas : ssh les relira lui-même via l'alias.
public struct SSHConfigEntry: Equatable, Sendable {
    public var alias: String
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var proxyJump: String?
    public var identityFiles: [String]
    /// Profil à ajouter : `host` = `name` = alias, `auth = .openSSHDefaults`, ni port ni user.
    public var candidate: HostProfile
}

public struct SSHConfigImportResult: Equatable, Sendable {
    public var entries: [SSHConfigEntry]
    /// Problèmes non bloquants (Include illisible, cycle, profondeur dépassée…).
    public var warnings: [String]
}

/// Importeur en lecture seule d'un fichier ssh_config. N'écrit jamais rien.
public struct SSHConfigImporter: Sendable {
    /// Profondeur maximale d'`Include` (comme OpenSSH).
    public static let maxIncludeDepth = 16

    /// Base des chemins relatifs des `Include` (par défaut `~/.ssh`).
    public let baseDirectory: URL

    public init(baseDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".ssh", isDirectory: true)) {
        self.baseDirectory = baseDirectory
    }

    /// Lit un fichier ssh_config (erreur si le fichier principal est illisible).
    public func parse(fileAt url: URL) throws -> SSHConfigImportResult {
        let data = try Data(contentsOf: url)
        var state = ParseState()
        state.stack = [Self.canonical(url.path)]
        parseText(String(decoding: data, as: UTF8.self), state: &state, depth: 0)
        return state.result()
    }

    /// Analyse un texte déjà lu.
    public func parse(text: String) -> SSHConfigImportResult {
        var state = ParseState()
        parseText(text, state: &state, depth: 0)
        return state.result()
    }

    // MARK: Fusion

    /// Entrées qui ne sont pas déjà dans la bibliothèque (même `host` avec `.openSSHDefaults`).
    public static func newEntries(in result: SSHConfigImportResult, comparedTo library: HostLibrary) -> [SSHConfigEntry] {
        var known = Set(library.hosts.filter { $0.auth == .openSSHDefaults }.map(\.host))
        var out: [SSHConfigEntry] = []
        for e in result.entries where known.insert(e.candidate.host).inserted { out.append(e) }
        return out
    }

    /// Ajoute les nouveaux candidats (dans `folderID`) et renvoie la liste des hôtes ajoutés.
    @discardableResult
    public static func merge(_ result: SSHConfigImportResult, into library: inout HostLibrary,
                             folderID: UUID? = nil) -> [HostProfile] {
        var added: [HostProfile] = []
        for e in newEntries(in: result, comparedTo: library) {
            var p = e.candidate
            p.folderID = folderID
            added.append(p)
        }
        library.hosts.append(contentsOf: added)
        return added
    }

    // MARK: Analyse

    private enum Context { case global, host([String]), match }

    private struct ParseState {
        var context: Context = .global
        var order: [String] = []
        var infos: [String: SSHConfigEntry] = [:]
        var warnings: [String] = []
        var stack: [String] = []

        func result() -> SSHConfigImportResult {
            SSHConfigImportResult(entries: order.compactMap { infos[$0] }, warnings: warnings)
        }

        mutating func register(_ alias: String) {
            guard infos[alias] == nil else { return }
            order.append(alias)
            infos[alias] = SSHConfigEntry(
                alias: alias, hostName: nil, user: nil, port: nil, proxyJump: nil, identityFiles: [],
                candidate: HostProfile(name: alias, host: alias, auth: .openSSHDefaults))
        }

        /// Comme ssh, la première valeur obtenue l'emporte (sauf IdentityFile, cumulatif).
        mutating func apply(key: String, args: [String], to aliases: [String]) {
            guard let v = args.first else { return }
            for a in aliases {
                guard var e = infos[a] else { continue }
                switch key {
                case "hostname": if e.hostName == nil { e.hostName = v }
                case "user": if e.user == nil { e.user = v }
                case "port": if e.port == nil { e.port = Int(v) }
                case "proxyjump": if e.proxyJump == nil { e.proxyJump = v }
                case "identityfile": e.identityFiles.append(v)
                default: break
                }
                infos[a] = e
            }
        }
    }

    private func parseText(_ text: String, state: inout ParseState, depth: Int) {
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            guard let (key, args) = Self.tokenize(String(rawLine)) else { continue }
            switch key {
            case "host":
                let aliases = args.filter { !$0.contains(where: { "*?!".contains($0) }) }
                aliases.forEach { state.register($0) }
                state.context = .host(aliases)
            case "match":
                state.context = .match
            case "include":
                // Dans un bloc Match, les directives sont conditionnelles : ignorées.
                if case .match = state.context { continue }
                let saved = state.context
                for pattern in args { include(pattern, state: &state, depth: depth) }
                state.context = saved
            default:
                if case .host(let aliases) = state.context { state.apply(key: key, args: args, to: aliases) }
            }
        }
    }

    private func include(_ pattern: String, state: inout ParseState, depth: Int) {
        guard depth < Self.maxIncludeDepth else {
            state.warnings.append("Include ignoré (profondeur max \(Self.maxIncludeDepth)) : \(pattern)")
            return
        }
        for path in Self.expand(pattern, base: baseDirectory) {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let canon = Self.canonical(path)
            if state.stack.contains(canon) {
                state.warnings.append("Include circulaire ignoré : \(path)")
                continue
            }
            guard let data = FileManager.default.contents(atPath: path) else {
                state.warnings.append("Include illisible : \(path)")
                continue
            }
            state.stack.append(canon)
            parseText(String(decoding: data, as: UTF8.self), state: &state, depth: depth + 1)
            state.stack.removeLast()
        }
    }

    /// `~`, chemin relatif → base, puis glob(3) (résultats triés par ordre lexical).
    private static func expand(_ pattern: String, base: URL) -> [String] {
        var p = pattern
        if p == "~" || p.hasPrefix("~/") {
            p = FileManager.default.homeDirectoryForCurrentUser.path + p.dropFirst()
        }
        if !p.hasPrefix("/") { p = base.path + "/" + p }
        var g = glob_t()
        defer { globfree(&g) }
        guard glob(p, GLOB_BRACE | GLOB_TILDE, nil, &g) == 0 else { return [] }
        return (0..<Int(g.gl_pathc)).compactMap { g.gl_pathv[$0].map { String(cString: $0) } }
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Découpe une ligne en (mot-clé en minuscules, arguments). `nil` si vide ou commentaire.
    /// Gère `Clé Valeur`, `Clé=Valeur`, `Clé = Valeur`, guillemets doubles et `#` en début de jeton.
    static func tokenize(_ line: String) -> (String, [String])? {
        let chars = Array(line)
        var i = 0
        func skipSpaces() { while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 } }
        skipSpaces()
        guard i < chars.count, chars[i] != "#" else { return nil }
        var key = ""
        while i < chars.count, !(chars[i] == " " || chars[i] == "\t" || chars[i] == "=") {
            key.append(chars[i]); i += 1
        }
        skipSpaces()
        if i < chars.count, chars[i] == "=" { i += 1 }
        var args: [String] = []
        while true {
            skipSpaces()
            guard i < chars.count else { break }
            if chars[i] == "#" { break }
            var tok = ""
            var quoted = false
            while i < chars.count {
                let c = chars[i]
                if c == "\"" { quoted.toggle(); i += 1; continue }
                if c == "\\", quoted, i + 1 < chars.count, chars[i + 1] == "\"" { tok.append("\""); i += 2; continue }
                if !quoted, c == " " || c == "\t" { break }
                tok.append(c); i += 1
            }
            args.append(tok)
        }
        guard !key.isEmpty else { return nil }
        return (key.lowercased(), args)
    }
}
