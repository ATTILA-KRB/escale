import Foundation

/// Réglages d'un port série (protocole `.serial`). Champs figés (l'import les renseigne) ; ajouts permis,
/// toujours avec décodage tolérant (`decodeIfPresent ?? défaut`).
public struct SerialSettings: Codable, Hashable, Sendable {
    public enum Parity: String, Codable, CaseIterable, Sendable { case none, odd, even }
    public enum FlowControl: String, Codable, CaseIterable, Sendable { case none, hardware, software }

    /// Chemin du périphérique (`/dev/cu.usbserial-…`).
    public var devicePath: String
    public var baudRate: Int
    /// 5 à 8.
    public var dataBits: Int
    public var parity: Parity
    /// 1 ou 2.
    public var stopBits: Int
    public var flowControl: FlowControl
    /// Écho local des caractères saisis (appareils qui ne renvoient pas la saisie).
    public var localEcho: Bool
    /// Fin de ligne envoyée pour Entrée (le moteur émet CR).
    public var lineEnding: SerialLineEnding

    public init(devicePath: String = "", baudRate: Int = 115_200, dataBits: Int = 8, parity: Parity = .none,
                stopBits: Int = 1, flowControl: FlowControl = .none,
                localEcho: Bool = false, lineEnding: SerialLineEnding = .cr) {
        self.devicePath = devicePath; self.baudRate = baudRate; self.dataBits = dataBits
        self.parity = parity; self.stopBits = stopBits; self.flowControl = flowControl
        self.localEcho = localEcho; self.lineEnding = lineEnding
    }

    private enum CodingKeys: String, CodingKey { case devicePath, baudRate, dataBits, parity, stopBits, flowControl, localEcho, lineEnding }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        devicePath = try c.decodeIfPresent(String.self, forKey: .devicePath) ?? ""
        baudRate = try c.decodeIfPresent(Int.self, forKey: .baudRate) ?? 115_200
        dataBits = try c.decodeIfPresent(Int.self, forKey: .dataBits) ?? 8
        parity = try c.decodeIfPresent(Parity.self, forKey: .parity) ?? .none
        stopBits = try c.decodeIfPresent(Int.self, forKey: .stopBits) ?? 1
        flowControl = try c.decodeIfPresent(FlowControl.self, forKey: .flowControl) ?? .none
        localEcho = try c.decodeIfPresent(Bool.self, forKey: .localEcho) ?? false
        lineEnding = try c.decodeIfPresent(SerialLineEnding.self, forKey: .lineEnding) ?? .cr
    }

    /// Messages d'erreur de validation (vide : valide).
    public static func validationErrors(_ s: SerialSettings) -> [String] {
        var e: [String] = []
        if s.devicePath.trimmingCharacters(in: .whitespaces).isEmpty { e.append("Choisissez un port série.") }
        if !(50...4_000_000).contains(s.baudRate) { e.append("Débit invalide (50 à 4 000 000 bauds).") }
        if !(5...8).contains(s.dataBits) { e.append("Bits de données : 5 à 8.") }
        if !(1...2).contains(s.stopBits) { e.append("Bits de stop : 1 ou 2.") }
        return e
    }
}
