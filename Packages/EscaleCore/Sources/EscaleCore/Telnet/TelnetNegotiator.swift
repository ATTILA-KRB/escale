import Foundation

/// Négociation d'options par la méthode Q (RFC 1143) : sans boucle, même si les deux côtés demandent en même temps.
/// Deux demi-duplex indépendants : « nous » (WILL/WONT reçus en DO/DONT) et « lui » (le serveur : DO/DONT envoyés).
public struct TelnetNegotiator: Sendable {
    enum Q: Sendable { case no, yes, wantNo, wantNoOpposite, wantYes, wantYesOpposite }

    /// Options que nous acceptons d'activer de notre côté (DO du serveur → WILL).
    public var localSupported: Set<UInt8>
    /// Options que nous acceptons que le serveur active (WILL du serveur → DO).
    public var remoteSupported: Set<UInt8>
    private var us: [UInt8: Q] = [:]
    private var him: [UInt8: Q] = [:]

    public init(localSupported: Set<UInt8> = [Telnet.optNAWS, Telnet.optTerminalType, Telnet.optSuppressGoAhead, Telnet.optBinary],
                remoteSupported: Set<UInt8> = [Telnet.optEcho, Telnet.optSuppressGoAhead, Telnet.optBinary]) {
        self.localSupported = localSupported; self.remoteSupported = remoteSupported
    }

    public func isLocalEnabled(_ o: UInt8) -> Bool { us[o] == .yes || us[o] == .wantNoOpposite }
    public func isRemoteEnabled(_ o: UInt8) -> Bool { him[o] == .yes || him[o] == .wantNoOpposite }
    /// Aucune demande en cours ni activation de notre côté.
    public func isLocalIdle(_ o: UInt8) -> Bool { (us[o] ?? .no) == .no }
    public func isRemoteIdle(_ o: UInt8) -> Bool { (him[o] ?? .no) == .no }

    private static func cmd(_ verb: UInt8, _ option: UInt8) -> Data { Data([Telnet.iac, verb, option]) }

    /// Traite WILL/WONT/DO/DONT reçu ; renvoie les octets de réponse (éventuellement vides).
    public mutating func receive(verb: UInt8, option o: UInt8) -> Data {
        switch verb {
        case Telnet.will:
            switch him[o] ?? .no {
            case .no:
                if remoteSupported.contains(o) { him[o] = .yes; return Self.cmd(Telnet.doo, o) }
                return Self.cmd(Telnet.dont, o)
            case .yes: return Data()
            case .wantNo: him[o] = .no; return Data()
            case .wantNoOpposite: him[o] = .yes; return Data()
            case .wantYes: him[o] = .yes; return Data()
            case .wantYesOpposite: him[o] = .wantNo; return Self.cmd(Telnet.dont, o)
            }
        case Telnet.wont:
            switch him[o] ?? .no {
            case .no: return Data()
            case .yes: him[o] = .no; return Self.cmd(Telnet.dont, o)
            case .wantNo: him[o] = .no; return Data()
            case .wantNoOpposite: him[o] = .wantYes; return Self.cmd(Telnet.doo, o)
            case .wantYes, .wantYesOpposite: him[o] = .no; return Data()
            }
        case Telnet.doo:
            switch us[o] ?? .no {
            case .no:
                if localSupported.contains(o) { us[o] = .yes; return Self.cmd(Telnet.will, o) }
                return Self.cmd(Telnet.wont, o)
            case .yes: return Data()
            case .wantNo: us[o] = .no; return Data()
            case .wantNoOpposite: us[o] = .yes; return Data()
            case .wantYes: us[o] = .yes; return Data()
            case .wantYesOpposite: us[o] = .wantNo; return Self.cmd(Telnet.wont, o)
            }
        case Telnet.dont:
            switch us[o] ?? .no {
            case .no: return Data()
            case .yes: us[o] = .no; return Self.cmd(Telnet.wont, o)
            case .wantNo: us[o] = .no; return Data()
            case .wantNoOpposite: us[o] = .wantYes; return Self.cmd(Telnet.will, o)
            case .wantYes, .wantYesOpposite: us[o] = .no; return Data()
            }
        default: return Data()
        }
    }

    /// Nous demandons d'activer l'option de notre côté (WILL).
    public mutating func requestLocal(_ o: UInt8) -> Data {
        switch us[o] ?? .no {
        case .no: us[o] = .wantYes; return Self.cmd(Telnet.will, o)
        case .wantNo: us[o] = .wantNoOpposite; return Data()
        case .wantYesOpposite: us[o] = .wantYes; return Data()
        default: return Data()
        }
    }

    /// Nous demandons au serveur d'activer l'option (DO).
    public mutating func requestRemote(_ o: UInt8) -> Data {
        switch him[o] ?? .no {
        case .no: him[o] = .wantYes; return Self.cmd(Telnet.doo, o)
        case .wantNo: him[o] = .wantNoOpposite; return Data()
        case .wantYesOpposite: him[o] = .wantYes; return Data()
        default: return Data()
        }
    }
}
