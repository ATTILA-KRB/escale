import Foundation

/// Réglages VNC (protocole `.vnc`) : hôte et port sont ceux de `HostProfile`.
/// PROVISOIRE : le module `vnc` ajoute ses champs, toujours avec décodage tolérant (`decodeIfPresent ?? défaut`).
public struct VNCSettings: Codable, Hashable, Sendable {
    public init() {}

    /// Messages d'erreur de validation (vide : valide).
    public static func validationErrors(_ s: VNCSettings) -> [String] { [] }
}
