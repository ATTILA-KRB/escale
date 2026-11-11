import Foundation

/// Logique Telnet d'une session, sans réseau : parseur + négociation + encodage de la saisie.
/// `TelnetConnection` ne fait que brancher ses entrées/sorties sur une connexion TCP.
public struct TelnetSession: Sendable {
    public var terminalType: String
    public var lineEnding: TelnetSettings.LineEnding
    public private(set) var columns: Int
    public private(set) var rows: Int

    private var parser = TelnetParser()
    private var negotiator = TelnetNegotiator()

    public init(terminalType: String = TelnetSettings.defaultTerminalType, lineEnding: TelnetSettings.LineEnding = .standard,
                columns: Int = 80, rows: Int = 24) {
        self.terminalType = terminalType; self.lineEnding = lineEnding
        self.columns = max(1, columns); self.rows = max(1, rows)
    }

    /// Le serveur fait l'écho (WILL ECHO accepté) : la saisie n'est pas répétée localement.
    public var serverEchoes: Bool { negotiator.isRemoteEnabled(Telnet.optEcho) }
    /// Mode binaire négocié dans les deux sens (RFC 856) : CR sans NUL.
    public var isBinary: Bool { negotiator.isLocalEnabled(Telnet.optBinary) && negotiator.isRemoteEnabled(Telnet.optBinary) }
    public var nawsActive: Bool { negotiator.isLocalEnabled(Telnet.optNAWS) }

    /// Offres initiales d'un client (comme telnet BSD) : TERMINAL-TYPE, NAWS, SGA dans les deux sens.
    public mutating func start() -> Data {
        var d = Data()
        d += negotiator.requestLocal(Telnet.optTerminalType)
        d += negotiator.requestLocal(Telnet.optNAWS)
        d += negotiator.requestRemote(Telnet.optSuppressGoAhead)
        d += negotiator.requestLocal(Telnet.optSuppressGoAhead)
        return d
    }

    /// Octets reçus du serveur → (texte à afficher, réponse à renvoyer).
    public mutating func receive(_ bytes: Data) -> (display: Data, reply: Data) {
        var display = Data(), reply = Data()
        for event in parser.feed(bytes) {
            switch event {
            case .data(let d): display += d
            case .command: break // NOP, GA, AYT… : sans effet pour un terminal
            case .negotiation(let verb, let option):
                let nawsBefore = nawsActive
                let binLocal = negotiator.isLocalEnabled(Telnet.optBinary), binRemote = negotiator.isRemoteEnabled(Telnet.optBinary)
                reply += negotiator.receive(verb: verb, option: option)
                if option == Telnet.optNAWS, nawsActive, !nawsBefore { reply += nawsSubnegotiation() }
                if option == Telnet.optBinary {
                    // Un sens accepté : on demande l'autre une seule fois (le mode binaire n'a d'effet que dans les deux).
                    let l = negotiator.isLocalEnabled(Telnet.optBinary), r = negotiator.isRemoteEnabled(Telnet.optBinary)
                    if l, !binLocal, !r, negotiator.isRemoteIdle(Telnet.optBinary) { reply += negotiator.requestRemote(Telnet.optBinary) }
                    if r, !binRemote, !l, negotiator.isLocalIdle(Telnet.optBinary) { reply += negotiator.requestLocal(Telnet.optBinary) }
                }
            case .subnegotiation(let option, let payload):
                if option == Telnet.optTerminalType, payload.first == Telnet.ttypeSend, negotiator.isLocalEnabled(option) {
                    reply += Data([Telnet.iac, Telnet.sb, option, Telnet.ttypeIs]) + Self.escape(Data(terminalType.utf8))
                        + Data([Telnet.iac, Telnet.se])
                }
            }
        }
        return (display, reply)
    }

    /// Nouvelle taille d'écran → sous-négociation NAWS à envoyer (vide si l'option n'est pas active ou si la taille n'a pas changé).
    public mutating func resize(columns: Int, rows: Int) -> Data {
        let c = max(1, columns), r = max(1, rows)
        guard c != self.columns || r != self.rows else { return Data() }
        self.columns = c; self.rows = r
        return nawsActive ? nawsSubnegotiation() : Data()
    }

    /// Saisie du terminal → octets à envoyer : 0xFF dédoublé, Entrée (CR) selon le mode de fin de ligne.
    public func encodeInput(_ input: Data) -> Data {
        var out = Data()
        out.reserveCapacity(input.count + 4)
        var i = input.startIndex
        while i < input.endIndex {
            let b = input[i]
            if b == Telnet.iac {
                out.append(contentsOf: [0xff, 0xff])
            } else if b == 0x0d {
                let next = input.index(after: i)
                if next < input.endIndex, input[next] == 0x0a || input[next] == 0 {
                    // CR LF ou CR NUL déjà complet (collage) : conservé tel quel.
                    out.append(contentsOf: [0x0d, input[next]]); i = input.index(after: next); continue
                }
                switch lineEnding {
                case .crlf: out.append(contentsOf: [0x0d, 0x0a])
                case .cr: out.append(0x0d)
                case .standard: isBinary ? out.append(0x0d) : out.append(contentsOf: [0x0d, 0x00])
                }
            } else {
                out.append(b)
            }
            i = input.index(after: i)
        }
        return out
    }

    private func nawsSubnegotiation() -> Data {
        let w = UInt16(min(columns, 65535)), h = UInt16(min(rows, 65535))
        let raw = Data([UInt8(w >> 8), UInt8(w & 0xff), UInt8(h >> 8), UInt8(h & 0xff)])
        return Data([Telnet.iac, Telnet.sb, Telnet.optNAWS]) + Self.escape(raw) + Data([Telnet.iac, Telnet.se])
    }

    /// Dédouble 0xFF (obligatoire aussi dans une sous-négociation).
    static func escape(_ d: Data) -> Data {
        var out = Data()
        for b in d { out.append(b); if b == Telnet.iac { out.append(b) } }
        return out
    }
}
