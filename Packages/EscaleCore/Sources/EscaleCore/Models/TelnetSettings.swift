import Foundation

/// Réglages Telnet (protocole `.telnet`) : hôte et port sont ceux de `HostProfile`.
/// Telnet n'est pas chiffré et le login est interactif dans le terminal : aucun identifiant ni mot de passe n'est stocké ici.
/// Décodage tolérant : chaque champ absent reprend sa valeur par défaut.
public struct TelnetSettings: Codable, Hashable, Sendable {
    /// Ce que le terminal envoie pour la touche Entrée (le moteur de terminal produit un CR).
    public enum LineEnding: String, Codable, CaseIterable, Sendable {
        /// RFC 854 : CR NUL (CR seul en mode binaire négocié dans les deux sens).
        case standard
        /// CR LF (certains équipements réseau, serveurs Windows).
        case crlf
        /// CR seul (équipements qui refusent le NUL).
        case cr

        public var displayName: String {
            switch self {
            case .standard: "Standard (CR NUL)"
            case .crlf: "CR LF"
            case .cr: "CR seul"
            }
        }
    }

    /// Type de terminal annoncé au serveur (option TERMINAL-TYPE, RFC 1091).
    public var terminalType: String
    public var lineEnding: LineEnding
    /// Délai maximal d'établissement de la connexion TCP, en secondes.
    public var connectTimeout: Int
    /// Hôte SSH (de la bibliothèque) par lequel passer : la connexion Telnet emprunte un tunnel local ouvert sur son maître.
    public var viaSSHHostID: UUID?

    public static let defaultTerminalType = "XTERM-256COLOR"

    public init(terminalType: String = TelnetSettings.defaultTerminalType, lineEnding: LineEnding = .standard,
                connectTimeout: Int = 10, viaSSHHostID: UUID? = nil) {
        self.terminalType = terminalType; self.lineEnding = lineEnding
        self.connectTimeout = connectTimeout; self.viaSSHHostID = viaSSHHostID
    }

    private enum CodingKeys: String, CodingKey { case terminalType, lineEnding, connectTimeout, viaSSHHostID }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terminalType = try c.decodeIfPresent(String.self, forKey: .terminalType) ?? Self.defaultTerminalType
        // Valeur inconnue (écrite par une version plus récente) : retour au défaut plutôt qu'un échec de décodage.
        lineEnding = (try? c.decodeIfPresent(LineEnding.self, forKey: .lineEnding)) ?? .standard
        connectTimeout = try c.decodeIfPresent(Int.self, forKey: .connectTimeout) ?? 10
        viaSSHHostID = try c.decodeIfPresent(UUID.self, forKey: .viaSSHHostID)
    }

    /// Messages d'erreur de validation (vide : valide).
    public static func validationErrors(_ s: TelnetSettings) -> [String] {
        var errors: [String] = []
        let t = s.terminalType
        if t.isEmpty || t.count > 40 || !t.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7f }) {
            errors.append("Le type de terminal doit être un mot ASCII de 1 à 40 caractères, sans espace.")
        }
        if !(1...120).contains(s.connectTimeout) {
            errors.append("Le délai de connexion doit être compris entre 1 et 120 secondes.")
        }
        return errors
    }
}
