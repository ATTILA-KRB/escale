import Foundation

/// Réglages RDP (protocole `.rdp`) : hôte, port et utilisateur sont ceux de `HostProfile`.
/// Escale ne parle pas RDP : il génère un fichier `.rdp` et le confie au client de Microsoft (« Windows App »).
/// Aucun mot de passe ici ni dans le fichier généré (invariant 7) : le client le demande à la connexion.
/// Décodage tolérant : chaque champ absent (ou de valeur inconnue) reprend sa valeur par défaut.
public struct RDPSettings: Codable, Hashable, Sendable {
    /// Affichage de la session.
    public enum DisplayMode: String, Codable, CaseIterable, Sendable {
        /// Plein écran (`screen mode id:i:2`).
        case fullScreen
        /// Fenêtre à la taille dynamique (`screen mode id:i:1`, `dynamic resolution:i:1`).
        case window
        /// Fenêtre à taille fixe (`desktopwidth`/`desktopheight`).
        case fixedSize

        public var displayName: String {
            switch self {
            case .fullScreen: "Plein écran"
            case .window: "Fenêtre (taille dynamique)"
            case .fixedSize: "Taille fixe"
            }
        }
    }

    /// Où sort le son de la session (`audiomode:i:`).
    public enum AudioMode: String, Codable, CaseIterable, Sendable {
        /// Lu sur ce Mac (0).
        case local
        /// Laissé sur l'ordinateur distant (1).
        case remote
        /// Aucun son (2).
        case none

        public var displayName: String {
            switch self {
            case .local: "Sur ce Mac"
            case .remote: "Sur l'ordinateur distant"
            case .none: "Aucun"
            }
        }
        var rdpValue: Int { switch self { case .local: 0; case .remote: 1; case .none: 2 } }
        init?(rdpValue: Int) {
            switch rdpValue { case 0: self = .local; case 1: self = .remote; case 2: self = .none; default: return nil }
        }
    }

    public static let minDimension = 200
    public static let maxDimension = 8192

    public var displayMode: DisplayMode
    /// Taille utilisée en mode `fixedSize`.
    public var width: Int
    public var height: Int
    /// Utiliser tous les écrans (`use multimon`).
    public var multiMonitor: Bool
    public var redirectClipboard: Bool
    public var audio: AudioMode
    /// Dossiers de ce Mac partagés avec la session (chemins absolus).
    public var sharedFolders: [String]
    /// Passerelle Bureau à distance (RD Gateway), vide : aucune.
    public var gatewayHostname: String
    /// Laisser le client demander l'identifiant et le mot de passe (`prompt for credentials`).
    public var promptForCredentials: Bool
    /// Hôte SSH (de la bibliothèque) par lequel passer : un tunnel local est ouvert sur son maître et le `.rdp` vise 127.0.0.1.
    public var viaSSHHostID: UUID?

    public init(displayMode: DisplayMode = .fullScreen, width: Int = 1920, height: Int = 1080, multiMonitor: Bool = false,
                redirectClipboard: Bool = true, audio: AudioMode = .local, sharedFolders: [String] = [],
                gatewayHostname: String = "", promptForCredentials: Bool = true, viaSSHHostID: UUID? = nil) {
        self.displayMode = displayMode; self.width = width; self.height = height; self.multiMonitor = multiMonitor
        self.redirectClipboard = redirectClipboard; self.audio = audio; self.sharedFolders = sharedFolders
        self.gatewayHostname = gatewayHostname; self.promptForCredentials = promptForCredentials
        self.viaSSHHostID = viaSSHHostID
    }

    private enum CodingKeys: String, CodingKey {
        case displayMode, width, height, multiMonitor, redirectClipboard, audio, sharedFolders
        case gatewayHostname, promptForCredentials, viaSSHHostID
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayMode = (try? c.decodeIfPresent(DisplayMode.self, forKey: .displayMode)) ?? .fullScreen
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 1920
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 1080
        multiMonitor = try c.decodeIfPresent(Bool.self, forKey: .multiMonitor) ?? false
        redirectClipboard = try c.decodeIfPresent(Bool.self, forKey: .redirectClipboard) ?? true
        audio = (try? c.decodeIfPresent(AudioMode.self, forKey: .audio)) ?? .local
        sharedFolders = try c.decodeIfPresent([String].self, forKey: .sharedFolders) ?? []
        gatewayHostname = try c.decodeIfPresent(String.self, forKey: .gatewayHostname) ?? ""
        promptForCredentials = try c.decodeIfPresent(Bool.self, forKey: .promptForCredentials) ?? true
        viaSSHHostID = try c.decodeIfPresent(UUID.self, forKey: .viaSSHHostID)
    }

    /// Messages d'erreur de validation (vide : valide).
    public static func validationErrors(_ s: RDPSettings) -> [String] {
        var errors: [String] = []
        if s.displayMode == .fixedSize,
           !(minDimension...maxDimension).contains(s.width) || !(minDimension...maxDimension).contains(s.height) {
            errors.append("La taille de l'écran doit être comprise entre \(minDimension) et \(maxDimension) pixels.")
        }
        for f in s.sharedFolders where !RDPFile.isValidFolder(f) {
            errors.append("Dossier partagé invalide : « \(f.filter { !$0.isNewline }) » (chemin absolu, sans « ; » ni caractère de contrôle).")
        }
        let g = s.gatewayHostname
        if !g.isEmpty && !RDPFile.isValidHostname(g) {
            errors.append("Le nom de la passerelle Bureau à distance est invalide.")
        }
        if !g.isEmpty && s.viaSSHHostID != nil {
            errors.append("Une passerelle Bureau à distance et un hôte SSH intermédiaire ne se combinent pas : choisissez l'un des deux.")
        }
        return errors
    }
}
