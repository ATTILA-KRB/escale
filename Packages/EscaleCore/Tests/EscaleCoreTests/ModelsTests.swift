import Testing
@testable import EscaleCore

@Test func cibleAvecEtSansUtilisateur() {
    #expect(HostProfile(name: "a", host: "h").target == "h")
    #expect(HostProfile(name: "a", host: "h", user: "u").target == "u@h")
}

@Test func argumentsDeTunnel() {
    #expect(TunnelSpec(kind: .local, bindPort: 8080, destinationHost: "db", destinationPort: 5432).specArgument == "127.0.0.1:8080:db:5432")
    #expect(TunnelSpec(kind: .dynamic, bindPort: 1080).specArgument == "127.0.0.1:1080")
    #expect(TunnelSpec.Kind.remote.flag == "-R")
}
