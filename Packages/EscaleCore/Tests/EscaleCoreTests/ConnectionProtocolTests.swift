import Foundation
import Testing
@testable import EscaleCore

@Suite("Protocoles d'hôte")
struct ConnectionProtocolTests {
    @Test func ancienneBibliothequeRestaSSH() throws {
        let json = #"{"id":"6F1C2C55-8D0B-4E39-9E0B-6B8C1F1D2A10","name":"a","host":"a.example","auth":{"openSSHDefaults":{}}}"#
        let h = try JSONDecoder().decode(HostProfile.self, from: Data(json.utf8))
        #expect(h.connectionProtocol == .ssh)
        #expect(h.serial == nil && h.telnet == nil && h.vnc == nil && h.rdp == nil)
    }

    @Test func protocoleInconnuRedevientSSH() throws {
        let json = #"{"id":"6F1C2C55-8D0B-4E39-9E0B-6B8C1F1D2A10","name":"a","host":"a","connectionProtocol":"gopher"}"#
        #expect(try JSONDecoder().decode(HostProfile.self, from: Data(json.utf8)).connectionProtocol == .ssh)
    }

    @Test func allerRetourSerieEtBureaux() throws {
        for p in ConnectionProtocol.allCases {
            let h = HostProfile(name: "x", host: "/dev/cu.test", connectionProtocol: p,
                                serial: SerialSettings(devicePath: "/dev/cu.test", baudRate: 9600, parity: .even, stopBits: 2),
                                telnet: TelnetSettings(), vnc: VNCSettings(), rdp: RDPSettings())
            let back = try JSONDecoder().decode(HostProfile.self, from: JSONEncoder().encode(h))
            #expect(back == h)
        }
    }

    @Test func reglagesSeriePartiels() throws {
        let s = try JSONDecoder().decode(SerialSettings.self, from: Data(#"{"devicePath":"/dev/cu.x"}"#.utf8))
        #expect(s == SerialSettings(devicePath: "/dev/cu.x"))
        #expect(SerialSettings.validationErrors(SerialSettings()).count == 1)
    }

    @Test func proprietes() {
        #expect(ConnectionProtocol.allCases.filter(\.isTerminal) == [.ssh, .telnet, .serial])
        #expect(ConnectionProtocol.telnet.defaultPort == 23 && ConnectionProtocol.serial.defaultPort == nil)
    }
}
