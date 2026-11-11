import Foundation

// Import de sessions depuis d'autres clients SSH (M5). Tout est en LECTURE SEULE : un importeur lit des octets et
// produit des `ImportedSession` ; il n'écrit rien et ne touche jamais aux fichiers sources (invariants 7 et 8 :
// aucun mot de passe repris, rien dans ~/.ssh).

/// Une session lue dans un autre client, prête à devenir un `HostProfile`.
public struct ImportedSession: Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int?
    public var user: String?
    public var auth: HostProfile.Auth
    /// Bastions (`user@host:port`).
    public var jumpHosts: [String]
    public var tags: [String]
    /// Dossier d'origine, du plus haut au plus bas (vide = racine).
    public var folderPath: [String]
    public var tunnels: [TunnelSpec]
    public var x11Forwarding: Bool
    /// Commande de connexion (MobaXterm « Execute command », PuTTY `RemoteCommand`) → `HostProfile.startupCommand`.
    public var startupCommand: String?
    /// Protocole de la session (SSH par défaut). Pour la série, `host` est le chemin du périphérique (vide si l'export
    /// ne donne qu'un port Windows `COMx`, à choisir après l'import).
    public var connectionProtocol: ConnectionProtocol
    public var serial: SerialSettings?

    public init(
        id: UUID = UUID(), name: String, host: String, port: Int? = nil, user: String? = nil,
        auth: HostProfile.Auth = .openSSHDefaults, jumpHosts: [String] = [], tags: [String] = [],
        folderPath: [String] = [], tunnels: [TunnelSpec] = [], x11Forwarding: Bool = false,
        startupCommand: String? = nil, connectionProtocol: ConnectionProtocol = .ssh, serial: SerialSettings? = nil
    ) {
        self.connectionProtocol = connectionProtocol; self.serial = serial
        self.id = id; self.name = name; self.host = host; self.port = port; self.user = user
        self.auth = auth; self.jumpHosts = jumpHosts; self.tags = tags; self.folderPath = folderPath
        self.tunnels = tunnels; self.x11Forwarding = x11Forwarding; self.startupCommand = startupCommand
    }

    /// Clé de dédoublonnage : même hôte (insensible à la casse), même port (22 par défaut), même utilisateur.
    /// Hors SSH, le protocole entre dans la clé ; pour la série (hôte = périphérique, souvent vide à l'import) le nom aussi.
    public var identityKey: String {
        SessionImportMerge.identityKey(connectionProtocol: connectionProtocol, name: name, host: host, port: port, user: user)
    }

    /// Profil de bibliothèque correspondant (le dossier est résolu par la fusion).
    func profile(folderID: UUID?) -> HostProfile {
        HostProfile(name: name, host: host, port: port, user: user, auth: auth, jumpHosts: jumpHosts,
                    tags: tags, folderID: folderID, tunnels: tunnels, x11Forwarding: x11Forwarding,
                    startupCommand: startupCommand, connectionProtocol: connectionProtocol,
                    serial: connectionProtocol == .serial ? (serial ?? SerialSettings(devicePath: host)) : nil,
                    telnet: connectionProtocol == .telnet ? TelnetSettings() : nil,
                    vnc: connectionProtocol == .vnc ? VNCSettings() : nil,
                    rdp: connectionProtocol == .rdp ? RDPSettings() : nil)
    }
}

public struct SessionImportResult: Equatable, Sendable {
    public var sessions: [ImportedSession]
    /// Problèmes non bloquants (clé .ppk, protocole non SSH, entrée incomplète…), en français.
    public var warnings: [String]
    /// Mots de passe trouvés dans la source et volontairement ignorés (invariant 7).
    public var ignoredPasswordCount: Int

    public init(sessions: [ImportedSession] = [], warnings: [String] = [], ignoredPasswordCount: Int = 0) {
        self.sessions = sessions; self.warnings = warnings; self.ignoredPasswordCount = ignoredPasswordCount
    }

    /// « 3 mots de passe non importés » ; `nil` s'il n'y en avait aucun.
    public var passwordNotice: String? {
        switch ignoredPasswordCount {
        case 0: nil
        case 1: "1 mot de passe non importé"
        default: "\(ignoredPasswordCount) mots de passe non importés"
        }
    }
}

/// Source d'import. Les implémentations sont pures : texte (ou octets) en entrée, résultat en sortie.
public protocol SessionImporter: Sendable {
    /// Nom affiché (« MobaXterm », « PuTTY », « CSV »).
    var sourceName: String { get }
    func parse(text: String) -> SessionImportResult
}

extension SessionImporter {
    /// Décode les octets (BOM UTF-8/UTF-16, sinon UTF-8 strict, sinon Windows-1252) puis analyse.
    public func parse(data: Data) -> SessionImportResult { parse(text: ImportTextDecoder.decode(data)) }

    /// Lit le fichier (ouverture en lecture seule uniquement).
    public func parse(fileAt url: URL) throws -> SessionImportResult { parse(data: try Data(contentsOf: url)) }
}

/// Décodage des fichiers d'export Windows.
public enum ImportTextDecoder {
    public static func decode(_ data: Data) -> String {
        let b = [UInt8](data.prefix(4))
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        // .reg de regedit : UTF-16LE avec BOM (« Windows Registry Editor Version 5.00 »).
        if b.starts(with: [0xFF, 0xFE]) { return decode16(data.dropFirst(2), little: true) }
        if b.starts(with: [0xFE, 0xFF]) { return decode16(data.dropFirst(2), little: false) }
        // UTF-16LE sans BOM : un octet nul après chaque caractère ASCII.
        if b.count >= 2, b[0] != 0, b[1] == 0 { return decode16(data[...], little: true) }
        if let s = String(data: data, encoding: .utf8) { return s }
        // Windows-1252 : les .mxtsessions de MobaXterm (jamais d'Unicode complet).
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static func decode16(_ data: Data, little: Bool) -> String {
        String(data: Data(data), encoding: little ? .utf16LittleEndian : .utf16BigEndian) ?? ""
    }
}

/// Utilitaires partagés par les importeurs.
enum ImportSupport {
    /// Fichier de clé : `.ppk` (format PuTTY) et chemins Windows ne sont pas utilisables par OpenSSH sur macOS.
    static func auth(forKeyPath raw: String, sessionName: String, warnings: inout [String]) -> HostProfile.Auth {
        let path = raw.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return .openSSHDefaults }
        if path.lowercased().hasSuffix(".ppk") {
            warnings.append("« \(sessionName) » : clé PuTTY (.ppk) non utilisable telle quelle par OpenSSH (chemin d'origine : \(path)). "
                + "Convertissez-la (puttygen --old-format, ou `puttygen clé.ppk -O private-openssh`) puis choisissez-la dans l'hôte.")
            return .openSSHDefaults
        }
        let looksWindows = path.contains("\\") || path.range(of: #"^[A-Za-z]:"#, options: .regularExpression) != nil
            || path.contains("_ProfileDir_") || path.contains("_CurrentDrive_")
        if looksWindows {
            warnings.append("« \(sessionName) » : chemin de clé Windows non repris (\(path)).")
            return .openSSHDefaults
        }
        return .keyFile(path: path)
    }

    /// Port valide, ou `nil` s'il est invalide ou égal au port par défaut du protocole (22 pour SSH).
    static func port(_ s: String?, protocol proto: ConnectionProtocol = .ssh) -> Int? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), let p = Int(s), (1...65535).contains(p) else { return nil }
        return p == proto.defaultPort ? nil : p
    }

    /// `user@host:port` pour ProxyJump.
    static func jump(host: String, port: Int?, user: String?) -> String {
        var s = host
        if let u = user, !u.isEmpty { s = "\(u)@\(s)" }
        if let p = port, p != 22 { s += ":\(p)" }
        return s
    }
}

// MARK: Fusion

/// Résultat d'une fusion dans la bibliothèque.
public struct SessionImportReport: Equatable, Sendable {
    public var added: [HostProfile]
    public var createdFolders: [HostFolder]
    /// Sessions écartées parce qu'un hôte identique (host + port + user) existait déjà (ou apparaissait deux fois).
    public var skippedDuplicates: Int

    public init(added: [HostProfile] = [], createdFolders: [HostFolder] = [], skippedDuplicates: Int = 0) {
        self.added = added; self.createdFolders = createdFolders; self.skippedDuplicates = skippedDuplicates
    }
}

public enum SessionImportMerge {
    /// Sessions de `sessions` absentes de la bibliothèque (même `identityKey`), sans doublon interne.
    public static func newSessions(_ sessions: [ImportedSession], comparedTo library: HostLibrary) -> [ImportedSession] {
        var known = Set(library.hosts.map { identityKey(of: $0) })
        return sessions.filter { known.insert($0.identityKey).inserted }
    }

    /// Ensemble des `id` de `sessions` déjà présents dans la bibliothèque (à griser dans l'aperçu).
    public static func existingIDs(_ sessions: [ImportedSession], comparedTo library: HostLibrary) -> Set<UUID> {
        let known = Set(library.hosts.map { identityKey(of: $0) })
        return Set(sessions.filter { known.contains($0.identityKey) }.map(\.id))
    }

    /// Ajoute les sessions non dupliquées sous `folderID` (`nil` = racine). Avec `keepFolders`, le dossier d'origine
    /// est recréé sous `folderID` (un dossier de même nom, insensible à la casse, est réutilisé).
    @discardableResult
    public static func merge(_ sessions: [ImportedSession], into library: inout HostLibrary,
                             folderID: UUID? = nil, keepFolders: Bool = true) -> SessionImportReport {
        var report = SessionImportReport(added: [], createdFolders: [], skippedDuplicates: 0)
        let fresh = newSessions(sessions, comparedTo: library)
        report.skippedDuplicates = sessions.count - fresh.count
        for s in fresh {
            var target = folderID
            if keepFolders {
                for name in s.folderPath where !name.isEmpty {
                    if let f = library.folders.first(where: {
                        $0.parentID == target && $0.name.compare(name, options: .caseInsensitive) == .orderedSame
                    }) {
                        target = f.id
                    } else {
                        let f = HostFolder(name: name, parentID: target)
                        library.folders.append(f)
                        report.createdFolders.append(f)
                        target = f.id
                    }
                }
            }
            let p = s.profile(folderID: target)
            library.hosts.append(p)
            report.added.append(p)
        }
        return report
    }

    private static func identityKey(of h: HostProfile) -> String {
        identityKey(connectionProtocol: h.connectionProtocol, name: h.name, host: h.host, port: h.port, user: h.user)
    }

    static func identityKey(connectionProtocol proto: ConnectionProtocol, name: String, host: String, port: Int?, user: String?) -> String {
        let base = "\(host.lowercased()):\(port ?? proto.defaultPort ?? 0):\(user ?? "")"
        switch proto {
        case .ssh: return base
        case .serial: return "serial:\(base):\(host.isEmpty ? name.lowercased() : "")"
        default: return "\(proto.rawValue):\(base)"
        }
    }
}
