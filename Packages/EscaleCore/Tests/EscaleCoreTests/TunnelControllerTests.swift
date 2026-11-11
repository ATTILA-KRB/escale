import Foundation
import Testing
@testable import EscaleCore

// MARK: - Validation (sans réseau)

@Suite struct TunnelValidationTests {
    @Test func tunnelValideSansErreur() {
        #expect(TunnelValidation.errors(TunnelSpec(kind: .local, bindPort: 8080, destinationHost: "db.local", destinationPort: 5432)).isEmpty)
        #expect(TunnelValidation.errors(TunnelSpec(kind: .dynamic, bindPort: 1080)).isEmpty)
    }

    @Test func portsEtAdressesInvalides() {
        #expect(!TunnelValidation.errors(TunnelSpec(kind: .local, bindPort: 0, destinationHost: "h", destinationPort: 1)).isEmpty)
        #expect(!TunnelValidation.errors(TunnelSpec(kind: .local, bindPort: 70000, destinationHost: "h", destinationPort: 1)).isEmpty)
        #expect(!TunnelValidation.errors(TunnelSpec(kind: .local, bindPort: 1, destinationHost: "", destinationPort: 1)).isEmpty)
        #expect(!TunnelValidation.errors(TunnelSpec(kind: .remote, bindPort: 1, destinationHost: "h", destinationPort: 0)).isEmpty)
        #expect(!TunnelValidation.errors(TunnelSpec(kind: .local, bindAddress: "a b", bindPort: 1, destinationHost: "h", destinationPort: 1)).isEmpty)
        #expect(!TunnelValidation.errors(TunnelSpec(kind: .local, bindAddress: "::1", bindPort: 1, destinationHost: "h", destinationPort: 1)).isEmpty)
        #expect(!TunnelValidation.errors(TunnelSpec(kind: .local, bindPort: 1, destinationHost: "h;rm", destinationPort: 1)).isEmpty)
        #expect(!TunnelValidation.errors(TunnelSpec(kind: .local, bindPort: 1, destinationHost: "-oProxy", destinationPort: 1)).isEmpty)
        // La destination d'un SOCKS est ignorée.
        #expect(TunnelValidation.errors(TunnelSpec(kind: .dynamic, bindPort: 1080, destinationHost: "", destinationPort: 0)).isEmpty)
    }

    @Test func avertissementNonLoopbackEtPortPrivilegie() {
        #expect(TunnelValidation.warnings(TunnelSpec(kind: .dynamic, bindPort: 1080)).isEmpty)
        #expect(TunnelValidation.warnings(TunnelSpec(kind: .local, bindAddress: "0.0.0.0", bindPort: 8080, destinationHost: "h", destinationPort: 1)).count == 1)
        #expect(TunnelValidation.warnings(TunnelSpec(kind: .local, bindAddress: "*", bindPort: 80, destinationHost: "h", destinationPort: 1)).count == 2)
        #expect(TunnelValidation.warnings(TunnelSpec(kind: .remote, bindAddress: "0.0.0.0", bindPort: 8080, destinationHost: "h", destinationPort: 1)).first?.contains("GatewayPorts") == true)
    }

    @Test func doublonDePortDetecte() {
        let a = TunnelSpec(kind: .local, bindPort: 8080, destinationHost: "h", destinationPort: 1)
        let b = TunnelSpec(kind: .dynamic, bindAddress: "localhost", bindPort: 8080)
        let c = TunnelSpec(kind: .remote, bindPort: 8080, destinationHost: "h", destinationPort: 1)
        #expect(TunnelValidation.listErrors([a, b]).count == 1)
        #expect(TunnelValidation.listErrors([a, c]).isEmpty) // R écoute côté serveur : pas de conflit local
    }

    @Test func urlsAcopier() {
        #expect(TunnelSpec(kind: .local, bindPort: 8080, destinationHost: "h", destinationPort: 1).clientURL == "http://127.0.0.1:8080")
        #expect(TunnelSpec(kind: .dynamic, bindAddress: "*", bindPort: 1080).clientURL == "socks5://127.0.0.1:1080")
    }
}

// MARK: - Contrôleur contre un sshd local

private func makeTransport(_ d: LocalSSHD) -> OpenSSHTransport {
    OpenSSHTransport(profile: d.profile(), configuration: .init(ssh: d.sshOptions(), masterReadyTimeout: 15, forwardProbeTimeout: 0.5))
}

private func withController<T>(_ d: LocalSSHD, _ body: (TunnelController, OpenSSHTransport) async throws -> T) async throws -> T {
    let t = makeTransport(d)
    try await t.connect()
    let c = TunnelController(transport: t)
    do { let r = try await body(c, t); await t.disconnect(); return r }
    catch { await t.disconnect(); throw error }
}

private func eventually(_ seconds: Double = 3, _ cond: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if await cond() { return true }; try? await Task.sleep(for: .milliseconds(30)) }
    return await cond()
}

@Suite(.enabled(if: LocalSSHD.isAvailable, "sshd local indisponible"), .serialized) struct TunnelControllerTests {
    @Test func localVerifieParCurlPuisAnnule() async throws {
        let http = try TestHTTPServer(body: "via-L")
        defer { http.stop() }
        try await LocalSSHD.with { d in
            try await withController(d) { c, _ in
                let port = try LocalSSHD.freePort()
                let spec = TunnelSpec(kind: .local, bindPort: port, destinationHost: "127.0.0.1", destinationPort: http.port)
                #expect(await c.state(of: spec.id) == .stopped)
                #expect(await c.start(spec) == .active)
                let r = curl(["http://127.0.0.1:\(port)/"])
                #expect(r.status == 0 && r.output == "via-L", "curl : \(r)")
                #expect(await c.start(spec) == .active) // idempotent
                #expect(await c.stop(spec.id) == .stopped)
                #expect(await eventually { LocalSSHD.portAccepts(port) == false }, "le port doit être fermé après cancel")
                #expect(curl(["http://127.0.0.1:\(port)/"]).status != 0)
                // Réouverture possible après arrêt.
                #expect(await c.start(spec) == .active)
                #expect(curl(["http://127.0.0.1:\(port)/"]).output == "via-L")
                #expect(d.acceptedAuthenticationCount() == 1)
            }
        }
    }

    @Test func dynamicVerifieParCurlSocks() async throws {
        let http = try TestHTTPServer(body: "via-D")
        defer { http.stop() }
        try await LocalSSHD.with { d in
            try await withController(d) { c, _ in
                let port = try LocalSSHD.freePort()
                let spec = TunnelSpec(kind: .dynamic, bindPort: port)
                #expect(await c.start(spec) == .active)
                let r = curl(["--socks5-hostname", "127.0.0.1:\(port)", "http://127.0.0.1:\(http.port)/"])
                #expect(r.status == 0 && r.output == "via-D", "curl : \(r)")
                #expect(await c.stop(spec.id) == .stopped)
                #expect(await eventually { LocalSSHD.portAccepts(port) == false })
            }
        }
    }

    @Test func remoteVerifieParCurlCoteServeur() async throws {
        // Ici le « serveur » est cette machine : le port distant est écouté par sshd sur 127.0.0.1.
        let http = try TestHTTPServer(body: "via-R")
        defer { http.stop() }
        try await LocalSSHD.with { d in
            try await withController(d) { c, _ in
                let remotePort = try LocalSSHD.freePort()
                let spec = TunnelSpec(kind: .remote, bindPort: remotePort, destinationHost: "127.0.0.1", destinationPort: http.port)
                #expect(await c.start(spec) == .active)
                let r = curl(["http://127.0.0.1:\(remotePort)/"])
                #expect(r.status == 0 && r.output == "via-R", "curl : \(r)")
                #expect(await c.stop(spec.id) == .stopped)
                #expect(await eventually { LocalSSHD.portAccepts(remotePort) == false }, "le port distant doit être fermé après cancel")
            }
        }
    }

    @Test func portLocalOccupeEchoueClairement() async throws {
        let squatter = try TestHTTPServer()
        defer { squatter.stop() }
        try await LocalSSHD.with { d in
            try await withController(d) { c, t in
                let spec = TunnelSpec(kind: .local, bindPort: squatter.port, destinationHost: "127.0.0.1", destinationPort: 9)
                guard case .failed(let m) = await c.start(spec) else { Issue.record("échec attendu"); return }
                #expect(m.contains("\(squatter.port)") && m.contains("déjà utilisé"), "message : \(m)")
                #expect(await t.activeTunnels.isEmpty)
                // Le programme qui occupait le port n'est pas perturbé.
                #expect(curl(["http://127.0.0.1:\(squatter.port)/"]).output == squatter.body)
            }
        }
    }

    @Test func portDistantOccupeRefuse() async throws {
        let http = try TestHTTPServer()
        defer { http.stop() }
        try await LocalSSHD.with { d in
            try await withController(d) { c, _ in
                // Le port « distant » est déjà occupé (même machine) : sshd ne peut pas l'écouter.
                let spec = TunnelSpec(kind: .remote, bindPort: http.port, destinationHost: "127.0.0.1", destinationPort: 9)
                guard case .failed(let m) = await c.start(spec) else { Issue.record("échec attendu pour R sur port occupé"); return }
                #expect(!m.isEmpty)
                #expect(await c.state(of: spec.id) == .failed(m))
                #expect(curl(["http://127.0.0.1:\(http.port)/"]).output == http.body)
            }
        }
    }

    @Test func forwardingInterditEstRefuse() async throws {
        let http = try TestHTTPServer()
        defer { http.stop() }
        try await LocalSSHD.with(.init(allowTcpForwarding: false)) { d in
            try await withController(d) { c, t in
                let lport = try LocalSSHD.freePort()
                let l = TunnelSpec(kind: .local, bindPort: lport, destinationHost: "127.0.0.1", destinationPort: http.port)
                guard case .failed(let ml) = await c.start(l) else { Issue.record("L aurait dû échouer"); return }
                #expect(!ml.isEmpty, "message L : \(ml)")
                #expect(await eventually { LocalSSHD.portAccepts(lport) == false }, "le tunnel L refusé doit être annulé")
                let rport = try LocalSSHD.freePort()
                let r = TunnelSpec(kind: .remote, bindPort: rport, destinationHost: "127.0.0.1", destinationPort: http.port)
                guard case .failed(let mr) = await c.start(r) else { Issue.record("R aurait dû échouer"); return }
                #expect(!mr.isEmpty, "message R : \(mr)")
                #expect(LocalSSHD.portAccepts(rport) == false)
                #expect(await t.activeTunnels.isEmpty)
            }
        }
    }

    @Test func coupureDuMaitrePuisReouverture() async throws {
        let http = try TestHTTPServer(body: "apres-coupure")
        defer { http.stop() }
        try await LocalSSHD.with { d in
            let t = makeTransport(d)
            try await t.connect()
            let c = TunnelController(transport: t)
            let port = try LocalSSHD.freePort()
            let spec = TunnelSpec(kind: .local, bindPort: port, destinationHost: "127.0.0.1", destinationPort: http.port)
            #expect(await c.start(spec) == .active)
            // Coupure brutale du maître (pid propre à ce transport).
            let pid = try #require(await t.masterProcessIdentifier)
            kill(pid, SIGKILL)
            #expect(await eventually(5) { await t.isAlive() == false })
            await c.connectionLost()
            #expect(await c.state(of: spec.id) == .stopped)
            try await t.connect()
            #expect(await c.reopen([spec])[spec.id] == .active)
            let r = curl(["http://127.0.0.1:\(port)/"])
            let journal = await t.masterJournal().suffix(600)
            #expect(r.output == "apres-coupure", "curl : \(r) journal : \(journal)")
            await t.disconnect()
        }
    }
}
