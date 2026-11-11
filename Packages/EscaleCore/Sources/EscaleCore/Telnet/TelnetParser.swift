import Foundation

/// Octets du protocole Telnet (RFC 854/855) et options gérées.
public enum Telnet {
    public static let se: UInt8 = 240, nop: UInt8 = 241, ga: UInt8 = 249, sb: UInt8 = 250
    public static let will: UInt8 = 251, wont: UInt8 = 252, doo: UInt8 = 253, dont: UInt8 = 254, iac: UInt8 = 255

    public static let optBinary: UInt8 = 0, optEcho: UInt8 = 1, optSuppressGoAhead: UInt8 = 3
    public static let optTerminalType: UInt8 = 24, optNAWS: UInt8 = 31

    /// Sous-négociation TERMINAL-TYPE : SEND = 1, IS = 0.
    public static let ttypeIs: UInt8 = 0, ttypeSend: UInt8 = 1
}

/// Ce que le parseur reconnaît dans le flux reçu.
public enum TelnetEvent: Equatable, Sendable {
    /// Données à afficher (IAC IAC déjà ramené à 0xFF, CR NUL à CR).
    case data(Data)
    /// Commande à un octet (NOP, GA, AYT…).
    case command(UInt8)
    /// WILL / WONT / DO / DONT + option.
    case negotiation(verb: UInt8, option: UInt8)
    /// IAC SB option … IAC SE (charge utile sans le premier octet d'option, 0xFF dédoublés ramenés).
    case subnegotiation(option: UInt8, payload: Data)
}

/// Machine à états NVT pure : peut être alimentée par morceaux de n'importe quelle taille, jusqu'à l'octet.
public struct TelnetParser: Sendable {
    private enum State: Equatable {
        case normal
        case iac
        case verb(UInt8)
        case sbOption
        case sb(UInt8)
        case sbIac(UInt8)
    }
    private var state: State = .normal
    private var afterCR = false
    private var sbPayload = Data()
    private var pending = Data()
    /// Plafond d'une sous-négociation (le reste est ignoré) : un serveur hostile ne gonfle pas la mémoire.
    public static let maxSubnegotiation = 1024

    public init() {}

    public mutating func feed(_ bytes: Data) -> [TelnetEvent] {
        var events: [TelnetEvent] = []
        func flush(_ p: inout Data) { if !p.isEmpty { events.append(.data(p)); p.removeAll(keepingCapacity: true) } }
        for b in bytes {
            switch state {
            case .normal:
                if afterCR {
                    afterCR = false
                    if b == 0 { continue } // CR NUL : retour chariot seul, le NUL est supprimé
                }
                if b == Telnet.iac { flush(&pending); state = .iac; continue }
                pending.append(b)
                if b == 0x0d { afterCR = true }
            case .iac:
                afterCR = false
                switch b {
                case Telnet.iac: pending.append(0xff); state = .normal
                case Telnet.will, Telnet.wont, Telnet.doo, Telnet.dont: state = .verb(b)
                case Telnet.sb: state = .sbOption
                default: events.append(.command(b)); state = .normal
                }
            case .verb(let v):
                events.append(.negotiation(verb: v, option: b)); state = .normal
            case .sbOption:
                sbPayload.removeAll(keepingCapacity: true); state = .sb(b)
            case .sb(let opt):
                if b == Telnet.iac { state = .sbIac(opt) } else if sbPayload.count < Self.maxSubnegotiation { sbPayload.append(b) }
            case .sbIac(let opt):
                switch b {
                case Telnet.iac:
                    if sbPayload.count < Self.maxSubnegotiation { sbPayload.append(0xff) }
                    state = .sb(opt)
                case Telnet.se:
                    events.append(.subnegotiation(option: opt, payload: sbPayload)); sbPayload.removeAll(); state = .normal
                default:
                    // Sous-négociation mal terminée : on la clôt et on traite l'octet comme une commande.
                    events.append(.subnegotiation(option: opt, payload: sbPayload)); sbPayload.removeAll()
                    events.append(.command(b)); state = .normal
                }
            }
        }
        flush(&pending)
        return events
    }
}
