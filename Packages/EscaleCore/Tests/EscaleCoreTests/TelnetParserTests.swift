import Foundation
import Testing
@testable import EscaleCore

@Suite("Telnet : parseur NVT")
struct TelnetParserTests {
    private func parse(_ bytes: [UInt8], chunk: Int? = nil) -> [TelnetEvent] {
        var p = TelnetParser()
        var out: [TelnetEvent] = []
        if let chunk {
            var i = 0
            while i < bytes.count { out += p.feed(Data(bytes[i..<min(i + chunk, bytes.count)])); i += chunk }
        } else { out = p.feed(Data(bytes)) }
        // Recolle les données fragmentées pour comparer indépendamment du découpage.
        var merged: [TelnetEvent] = []
        for e in out {
            if case .data(let d) = e, case .data(let prev)? = merged.last { merged[merged.count - 1] = .data(prev + d) } else { merged.append(e) }
        }
        return merged
    }

    private let sample: [UInt8] = Array("ab".utf8) + [255, 255] + Array("c\r".utf8) + [0] + Array("d\r\n".utf8)
        + [255, 253, 31] + [255, 250, 31, 0, 80, 0, 24, 255, 240] + [255, 241] + Array("z".utf8)

    private var expected: [TelnetEvent] {
        [.data(Data("ab".utf8) + Data([255]) + Data("c\rd\r\n".utf8)),
         .negotiation(verb: Telnet.doo, option: Telnet.optNAWS),
         .subnegotiation(option: Telnet.optNAWS, payload: Data([0, 80, 0, 24])),
         .command(Telnet.nop), .data(Data("z".utf8))]
    }

    @Test func fluxComplet() { #expect(parse(sample) == expected) }
    @Test func octetParOctet() { #expect(parse(sample, chunk: 1) == expected) }
    @Test func decoupagesVaries() { for n in 2...7 { #expect(parse(sample, chunk: n) == expected, "morceaux de \(n)") } }

    @Test func iacIacDonneUnOctetFF() { #expect(parse([255, 255]) == [.data(Data([255]))]) }

    @Test func crNulEtCrLf() {
        #expect(parse([0x0d, 0x00, 0x41]) == [.data(Data([0x0d, 0x41]))])
        #expect(parse([0x0d, 0x0a]) == [.data(Data([0x0d, 0x0a]))])
        // CR NUL coupé entre deux lectures.
        var p = TelnetParser()
        #expect(p.feed(Data([0x0d])) == [.data(Data([0x0d]))])
        #expect(p.feed(Data([0x00, 0x42])) == [.data(Data([0x42]))])
    }

    @Test func nawsAvecOctetFFDedouble() {
        // Largeur 255 : 00 FF → dédoublé 00 FF FF dans la sous-négociation.
        let ev = parse([255, 250, 31, 0, 255, 255, 0, 24, 255, 240])
        #expect(ev == [.subnegotiation(option: Telnet.optNAWS, payload: Data([0, 255, 0, 24]))])
    }

    @Test func sousNegociationMalTerminee() {
        let ev = parse([255, 250, 24, 1, 255, 241, 65])
        #expect(ev == [.subnegotiation(option: 24, payload: Data([1])), .command(241), .data(Data([65]))])
    }

    @Test func sousNegociationDemesureeEstBornee() {
        var bytes: [UInt8] = [255, 250, 24]
        bytes += Array(repeating: 7, count: 5000)
        bytes += [255, 240]
        guard case .subnegotiation(_, let payload)? = parse(bytes).first else { Issue.record("pas de sous-négociation"); return }
        #expect(payload.count == TelnetParser.maxSubnegotiation)
    }

    @Test func commandesNegociation() {
        #expect(parse([255, 251, 1, 255, 252, 3, 255, 253, 24, 255, 254, 31]) == [
            .negotiation(verb: Telnet.will, option: 1), .negotiation(verb: Telnet.wont, option: 3),
            .negotiation(verb: Telnet.doo, option: 24), .negotiation(verb: Telnet.dont, option: 31)])
    }
}
