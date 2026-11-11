import Foundation

/// Protocole d'un hôte de la bibliothèque. SSH (défaut), Telnet et série ouvrent un terminal ; VNC et RDP un bureau distant.
/// Contrat figé de la vague V1.2/V2 : ajouter des membres, ne jamais renommer un cas (valeur brute persistée).
public enum ConnectionProtocol: String, Codable, CaseIterable, Hashable, Sendable {
    case ssh, telnet, serial, vnc, rdp

    /// Nom affiché.
    public var displayName: String {
        switch self {
        case .ssh: "SSH"
        case .telnet: "Telnet"
        case .serial: "Série"
        case .vnc: "VNC"
        case .rdp: "Bureau à distance (RDP)"
        }
    }

    /// Port par défaut (`nil` : sans objet, port série).
    public var defaultPort: Int? {
        switch self {
        case .ssh: 22
        case .telnet: 23
        case .serial: nil
        case .vnc: 5900
        case .rdp: 3389
        }
    }

    /// Vrai si l'hôte s'ouvre dans un panneau de terminal (sinon : fenêtre ou app de bureau distant).
    public var isTerminal: Bool { self == .ssh || self == .telnet || self == .serial }

    /// Symbole SF Symbols de la barre latérale.
    public var symbolName: String {
        switch self {
        case .ssh: "server.rack"
        case .telnet: "network"
        case .serial: "cable.connector"
        case .vnc: "display"
        case .rdp: "pc"
        }
    }

    /// Décodage tolérant : une valeur inconnue (bibliothèque écrite par une version plus récente) redevient SSH.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ConnectionProtocol(rawValue: raw) ?? .ssh
    }
}
