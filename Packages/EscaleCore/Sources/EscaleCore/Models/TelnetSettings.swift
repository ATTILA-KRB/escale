import Foundation

/// Réglages Telnet (protocole `.telnet`) : hôte et port sont ceux de `HostProfile`.
/// PROVISOIRE : le module `telnet` ajoute ses champs, toujours avec décodage tolérant (`decodeIfPresent ?? défaut`).
public struct TelnetSettings: Codable, Hashable, Sendable {
    public init() {}

    /// Messages d'erreur de validation (vide : valide).
    public static func validationErrors(_ s: TelnetSettings) -> [String] { [] }
}
