import Foundation

/// Réglages RDP (protocole `.rdp`) : hôte, port et utilisateur sont ceux de `HostProfile`.
/// PROVISOIRE : le module `rdp` ajoute ses champs, toujours avec décodage tolérant (`decodeIfPresent ?? défaut`).
public struct RDPSettings: Codable, Hashable, Sendable {
    public init() {}

    /// Messages d'erreur de validation (vide : valide).
    public static func validationErrors(_ s: RDPSettings) -> [String] { [] }
}
