import Foundation
import Testing
@testable import EscaleCore

/// Une bibliothèque écrite avant M2 (sans `tunnels` ni `x11Forwarding`) se relit sans migration.
@Test func hoteAncienFormatSeRelit() throws {
    let json = """
    {"id":"6F1D2C3B-0000-4000-8000-000000000001","name":"a","host":"h","auth":{"openSSHDefaults":{}},
     "jumpHosts":[],"tags":["x"]}
    """
    let h = try JSONDecoder().decode(HostProfile.self, from: Data(json.utf8))
    #expect(h.tunnels.isEmpty)
    #expect(h.x11Forwarding == false)
    #expect(h.tags == ["x"])
}

@Test func tunnelAncienFormatSeRelit() throws {
    let json = #"{"id":"6F1D2C3B-0000-4000-8000-000000000002","kind":"local","bindAddress":"127.0.0.1","bindPort":8080,"destinationHost":"db","destinationPort":5432}"#
    let t = try JSONDecoder().decode(TunnelSpec.self, from: Data(json.utf8))
    #expect(t.name == "" && t.autoStart == false)
    #expect(t.specArgument == "127.0.0.1:8080:db:5432")
}

@Test func hoteAllerRetourAvecNouveauxChamps() throws {
    let t = TunnelSpec(kind: .dynamic, bindPort: 1080, name: "socks", autoStart: true)
    let h = HostProfile(name: "a", host: "h", tunnels: [t], x11Forwarding: true)
    let back = try JSONDecoder().decode(HostProfile.self, from: JSONEncoder().encode(h))
    #expect(back == h)
}
