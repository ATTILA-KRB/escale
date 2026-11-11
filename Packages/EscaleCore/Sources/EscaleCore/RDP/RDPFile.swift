import Foundation

/// Erreur de génération ou d'analyse d'un fichier `.rdp`.
public enum RDPFileError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidHost(String)
    case invalidValue(key: String)
    case invalidSettings(String)
    case missingAddress
    case invalidPort(String)
    case notText
    case tooLarge

    public var description: String {
        switch self {
        case .invalidHost(let h): "Nom d'hôte invalide pour un fichier .rdp : « \(h.filter { !$0.isNewline }) »."
        case .invalidValue(let k): "La valeur de « \(k) » contient un caractère interdit (retour à la ligne ou caractère de contrôle)."
        case .invalidSettings(let m): m
        case .missingAddress: "Le fichier .rdp ne contient pas d'adresse (full address)."
        case .invalidPort(let p): "Port invalide dans le fichier .rdp : « \(p.filter { !$0.isNewline }) »."
        case .notText: "Le fichier .rdp n'est pas un texte lisible (UTF-8 ou UTF-16)."
        case .tooLarge: "Le fichier .rdp est trop volumineux."
        }
    }
}

/// Résultat de l'analyse d'un `.rdp` existant.
public struct RDPImport: Equatable, Sendable {
    public var host: HostProfile
    /// Éléments ignorés ou approximés (mot de passe, partage de tous les lecteurs…).
    public var warnings: [String]
}

/// Génération et analyse des fichiers `.rdp` (texte `clé:type:valeur`, une par ligne).
///
/// Sécurité : une valeur ne peut jamais contenir de retour à la ligne ni de caractère de contrôle (sinon une valeur
/// forgée — nom d'utilisateur, dossier — injecterait une clé comme `drivestoredirect`) : elle est refusée, pas filtrée.
/// Aucun mot de passe n'est écrit ni importé (invariant 7).
public enum RDPFile {
    public static let maxImportSize = 1_048_576

    // MARK: Validation

    /// Vrai s'il y a un caractère de contrôle ou un séparateur de ligne Unicode.
    static func hasControl(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f || $0.value == 0x85 || $0.value == 0x2028 || $0.value == 0x2029 }
    }

    /// Nom d'hôte, adresse IPv4 ou IPv6 (avec ou sans crochets).
    public static func isValidHostname(_ s: String) -> Bool {
        var h = s
        if h.hasPrefix("[") && h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        guard !h.isEmpty, h.utf8.count <= 253 else { return false }
        let extra = CharacterSet(charactersIn: ".-_:%")
        return h.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || extra.contains($0) }
    }

    /// Chemin absolu sans point-virgule (séparateur de `drivestoredirect`) ni caractère de contrôle.
    public static func isValidFolder(_ s: String) -> Bool {
        s.hasPrefix("/") && s.utf8.count <= 1024 && !s.contains(";") && !hasControl(s)
    }

    private static func line(_ key: String, _ type: Character, _ value: String) throws -> String {
        guard !hasControl(value) else { throw RDPFileError.invalidValue(key: key) }
        return "\(key):\(type):\(value)"
    }

    // MARK: Génération

    /// Contenu du fichier `.rdp` d'un hôte. `address` remplace hôte et port (tunnel SSH : 127.0.0.1:<port local>).
    public static func generate(host: HostProfile, settings: RDPSettings? = nil,
                                address: (host: String, port: Int)? = nil) throws -> String {
        let s = settings ?? host.rdp ?? RDPSettings()
        if let first = RDPSettings.validationErrors(s).first { throw RDPFileError.invalidSettings(first) }
        let target = address?.host ?? host.host
        let port = address?.port ?? host.port ?? ConnectionProtocol.rdp.defaultPort ?? 3389
        guard isValidHostname(target) else { throw RDPFileError.invalidHost(target) }
        guard (1...65535).contains(port) else { throw RDPFileError.invalidPort(String(port)) }
        let bare = target.hasPrefix("[") && target.hasSuffix("]") ? String(target.dropFirst().dropLast()) : target
        let shown = bare.contains(":") ? "[\(bare)]" : bare

        var out: [String] = []
        out.append(try line("full address", "s", "\(shown):\(port)"))
        if let user = host.user, !user.isEmpty { out.append(try line("username", "s", user)) }
        out.append(try line("prompt for credentials", "i", s.promptForCredentials ? "1" : "0"))
        switch s.displayMode {
        case .fullScreen:
            out.append("screen mode id:i:2")
        case .window:
            out.append("screen mode id:i:1")
            out.append("dynamic resolution:i:1")
        case .fixedSize:
            out.append("screen mode id:i:1")
            out.append("desktopwidth:i:\(s.width)")
            out.append("desktopheight:i:\(s.height)")
            out.append("dynamic resolution:i:0")
        }
        out.append("use multimon:i:\(s.multiMonitor ? 1 : 0)")
        out.append("redirectclipboard:i:\(s.redirectClipboard ? 1 : 0)")
        out.append("audiomode:i:\(s.audio.rdpValue)")
        if !s.sharedFolders.isEmpty { out.append(try line("drivestoredirect", "s", s.sharedFolders.joined(separator: ";"))) }
        if !s.gatewayHostname.isEmpty {
            out.append(try line("gatewayhostname", "s", s.gatewayHostname))
            out.append("gatewayusagemethod:i:1")
        }
        return out.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: Analyse

    /// Décode le contenu d'un `.rdp` (UTF-8, ou UTF-16 avec BOM comme l'écrivent les clients Windows).
    public static func decode(_ data: Data) throws -> String {
        guard data.count <= maxImportSize else { throw RDPFileError.tooLarge }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            guard let s = String(data: data, encoding: .utf16) else { throw RDPFileError.notText }
            return s
        }
        let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        guard let s = String(data: Data(body), encoding: .utf8) else { throw RDPFileError.notText }
        return s
    }

    /// Hôte et port d'une valeur `full address` (`host`, `host:port`, `[v6]`, `[v6]:port`, `v6` nu).
    static func splitAddress(_ raw: String) throws -> (host: String, port: Int?) {
        let a = raw.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { throw RDPFileError.missingAddress }
        var host = a
        var portText: String?
        if a.hasPrefix("["), let close = a.firstIndex(of: "]") {
            host = String(a[a.index(after: a.startIndex)..<close])
            let rest = a[a.index(after: close)...]
            if rest.hasPrefix(":") { portText = String(rest.dropFirst()) } else if !rest.isEmpty { throw RDPFileError.invalidHost(a) }
        } else if a.filter({ $0 == ":" }).count == 1, let i = a.firstIndex(of: ":") {
            host = String(a[..<i]); portText = String(a[a.index(after: i)...])
        }
        guard isValidHostname(host) else { throw RDPFileError.invalidHost(host) }
        var port: Int?
        if let t = portText {
            guard let p = Int(t), (1...65535).contains(p) else { throw RDPFileError.invalidPort(t) }
            port = p
        }
        return (host, port)
    }

    /// Hôte de bibliothèque construit depuis un `.rdp` (`name` : nom proposé, en général celui du fichier).
    public static func parse(_ text: String, name: String? = nil) throws -> RDPImport {
        guard text.utf8.count <= maxImportSize else { throw RDPFileError.tooLarge }
        var values: [String: (type: String, value: String)] = [:]
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            var l = String(raw)
            if l.hasPrefix("\u{FEFF}") { l.removeFirst() }
            let parts = l.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { continue }
            values[key] = (parts[1].trimmingCharacters(in: .whitespaces).lowercased(), String(parts[2]))
        }
        func str(_ k: String) -> String? { values[k].flatMap { $0.type == "s" ? $0.value.trimmingCharacters(in: .whitespaces) : nil } }
        func int(_ k: String) -> Int? { values[k].flatMap { Int($0.value.trimmingCharacters(in: .whitespaces)) } }

        guard let addr = str("full address"), !addr.isEmpty else { throw RDPFileError.missingAddress }
        let (hostName, port) = try splitAddress(addr)
        var warnings: [String] = []
        var s = RDPSettings()

        if int("screen mode id") == 2 {
            s.displayMode = .fullScreen
        } else if let w = int("desktopwidth"), let h = int("desktopheight"), int("dynamic resolution") != 1,
                  (RDPSettings.minDimension...RDPSettings.maxDimension).contains(w),
                  (RDPSettings.minDimension...RDPSettings.maxDimension).contains(h) {
            s.displayMode = .fixedSize; s.width = w; s.height = h
        } else if int("screen mode id") == 1 {
            s.displayMode = .window
        }
        if let v = int("use multimon") { s.multiMonitor = v == 1 }
        if let v = int("redirectclipboard") { s.redirectClipboard = v != 0 }
        if let v = int("audiomode"), let a = RDPSettings.AudioMode(rdpValue: v) { s.audio = a }
        if let v = int("prompt for credentials") { s.promptForCredentials = v != 0 }
        if let g = str("gatewayhostname"), !g.isEmpty {
            if isValidHostname(g) { s.gatewayHostname = g } else { warnings.append("Passerelle ignorée : nom invalide.") }
        }
        if let d = str("drivestoredirect"), !d.isEmpty {
            var folders: [String] = []
            for p in d.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where !p.isEmpty {
                if isValidFolder(p) { folders.append(p) } else { warnings.append("Redirection de lecteur ignorée : « \(p.filter { !$0.isNewline }) ».") }
            }
            s.sharedFolders = folders
        }
        if values.keys.contains(where: { $0.hasPrefix("password") }) { warnings.append("Mot de passe du fichier ignoré : Escale n'en enregistre pas.") }

        var user = str("username")
        if let u = user, u.isEmpty || hasControl(u) { user = nil }
        let display = (name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? hostName
        let profile = HostProfile(name: display, host: hostName, port: port == 3389 ? nil : port, user: user,
                                  connectionProtocol: .rdp, rdp: s)
        return RDPImport(host: profile, warnings: warnings)
    }

    /// Lecture d'un fichier `.rdp` sur disque (nom d'hôte proposé : nom du fichier sans extension).
    public static func load(from url: URL) throws -> RDPImport {
        let data = try Data(contentsOf: url)
        return try parse(try decode(data), name: url.deletingPathExtension().lastPathComponent)
    }

    /// Nom de fichier sûr pour un hôte (pas de séparateur de chemin, pas de caractère de contrôle).
    public static func fileName(for host: HostProfile) -> String {
        var base = host.name.unicodeScalars.map { (CharacterSet.alphanumerics.contains($0) || " -_.".unicodeScalars.contains($0)) ? Character($0) : "_" }
            .map(String.init).joined().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if base.isEmpty { base = "hote" }
        return String(base.prefix(80)) + ".rdp"
    }

    // MARK: Dossier privé

    /// Crée un dossier privé 0700 `rdp-<uuid>` sous `parent` (cache de l'app).
    public static func makePrivateDirectory(under parent: URL) throws -> URL {
        let dir = parent.appendingPathComponent("rdp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// Écrit le fichier (0600) dans `directory` et rend son URL.
    @discardableResult
    public static func write(_ content: String, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(content.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }
}
