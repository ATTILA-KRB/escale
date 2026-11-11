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
        #expect(TunnelValidation.errors(TunnelSpec(kind: .local, bindAddress: "::1", bindPort: 1, destinationHost: "h", destinationPort: 1)).isEmpty) // IPv6 pris en charge
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

    @Test func ipv6AcceptePourEcouteEtDestination() {
        func ok(_ s: TunnelSpec) -> Bool { TunnelValidation.errors(s).isEmpty }
        #expect(ok(TunnelSpec(kind: .local, bindAddress: "::1", bindPort: 8080, destinationHost: "::1", destinationPort: 80)))
        #expect(ok(TunnelSpec(kind: .local, bindAddress: "[::1]", bindPort: 8080, destinationHost: "[2001:db8::10]", destinationPort: 80)))
        #expect(ok(TunnelSpec(kind: .remote, bindAddress: "::", bindPort: 8080, destinationHost: "fe80::1", destinationPort: 80)))
        #expect(ok(TunnelSpec(kind: .local, bindAddress: "fe80::1%lo0", bindPort: 8080, destinationHost: "h", destinationPort: 80)))
        #expect(ok(TunnelSpec(kind: .dynamic, bindAddress: "[::1]", bindPort: 1080)))
        // Invalides : trop de groupes, caractère interdit, crochet seul, zone d'interface, hôte avec deux-points non IPv6.
        for bad in ["1:2:3:4:5:6:7:8:9", "::g", "[::1", "::1]", "host:name"] {
            #expect(!ok(TunnelSpec(kind: .local, bindAddress: bad, bindPort: 1, destinationHost: "h", destinationPort: 1)), "« \(bad) » doit être refusé")
            #expect(!ok(TunnelSpec(kind: .local, bindPort: 1, destinationHost: bad, destinationPort: 1)), "destination « \(bad) » doit être refusée")
        }
    }

    @Test func zonesIPv6Validation() {
        func errs(bind: String = "127.0.0.1", dest: String = "h", kind: TunnelSpec.Kind = .local) -> [String] {
            TunnelValidation.errors(TunnelSpec(kind: kind, bindAddress: bind, bindPort: 8080, destinationHost: dest, destinationPort: 80))
        }
        // Écoute : zone avec ou sans crochets, interface réelle (lo0 porte fe80::1 sur macOS).
        #expect(errs(bind: "fe80::1%lo0").isEmpty)
        #expect(errs(bind: "[fe80::1%lo0]").isEmpty)
        #expect(errs(bind: "fe80::1%1").isEmpty) // index numérique de lo0
        #expect(TunnelValidation.errors(TunnelSpec(kind: .dynamic, bindAddress: "[fe80::1%lo0]", bindPort: 1080)).isEmpty)
        // Écoute locale : interface inexistante refusée (message en français), syntaxe invalide refusée.
        #expect(errs(bind: "fe80::1%nonexist9").first?.contains("n'existe pas sur ce Mac") == true)
        #expect(errs(bind: "fe80::1%").first?.contains("zone IPv6 non valide") == true)
        #expect(errs(bind: "fe80::1%en 0").first?.contains("zone IPv6 non valide") == true)
        for bad in ["fe80::1%en0;rm", "fe80::1%-x'", "fe80::1%a%b", "fe80::1%abcdefghijklmnop", "[fe80::1%en0", "127.0.0.1%lo0", "host%lo0", "zz::1%lo0"] {
            #expect(!errs(bind: bad).isEmpty, "écoute « \(bad) » doit être refusée")
            #expect(!errs(dest: bad).isEmpty, "destination « \(bad) » doit être refusée")
        }
        // Écoute côté serveur (R) et destination : syntaxe seule, l'interface peut n'exister que là-bas.
        #expect(errs(bind: "fe80::1%nonexist9", kind: .remote).isEmpty)
        #expect(errs(dest: "fe80::2%nonexist9").isEmpty)
        #expect(errs(dest: "[fe80::2%en0]").isEmpty)
        #expect(errs(dest: "fe80::2%utun3").isEmpty && errs(dest: "fe80::2%bridge100").isEmpty && errs(dest: "fe80::2%vlan0.5").isEmpty)
    }

    @Test func zonesIPv6FormatageEtDoublons() throws {
        let t = TunnelSpec(kind: .local, bindAddress: "fe80::1%lo0", bindPort: 8080, destinationHost: "[fe80::2%en0]", destinationPort: 80)
        #expect(t.specArgument == "[fe80::1%lo0]:8080:[fe80::2%en0]:80")
        #expect(TunnelSpec(kind: .dynamic, bindAddress: "[fe80::1%lo0]", bindPort: 1080).specArgument == "[fe80::1%lo0]:1080")
        #expect(t.summary == "Local [fe80::1%lo0]:8080 → [fe80::2%en0]:80")
        #expect(t.clientURL == "http://[fe80::1%25lo0]:8080") // RFC 6874 : « % » devient « %25 » dans une URL
        #expect(TunnelValidation.isLoopback("fe80::1%lo0") && !TunnelValidation.isLoopback("fe80::1%en0"))
        #expect(TunnelValidation.warnings(t).count == 0)
        #expect(TunnelValidation.warnings(TunnelSpec(kind: .local, bindAddress: "fe80::1%en0", bindPort: 8080, destinationHost: "h", destinationPort: 1)).count == 1)
        // Doublons et remplacement à chaud : même adresse canonique, zone comparée telle quelle.
        let a = TunnelSpec(kind: .local, bindAddress: "fe80:0:0:0:0:0:0:1%lo0", bindPort: 8080, destinationHost: "h", destinationPort: 1)
        let b = TunnelSpec(kind: .local, bindAddress: "[FE80::1%lo0]", bindPort: 8080, destinationHost: "h", destinationPort: 1)
        let c = TunnelSpec(kind: .local, bindAddress: "fe80::1%lo1", bindPort: 8080, destinationHost: "h", destinationPort: 1)
        #expect(TunnelValidation.listErrors([a, b]).count == 1)
        #expect(TunnelValidation.listErrors([a, c]).isEmpty)
        #expect(a.sameForwarding(as: b) && !a.sameForwarding(as: c))
        // Contrôles du constructeur de commande ssh : la spécification passe telle quelle.
        let builder = try? OpenSSHCommandBuilder(profile: HostProfile(name: "h", host: "h"), controlPath: "/tmp/x/m", options: .init())
        #expect(try builder?.controlArguments(.forward(t)).contains("[fe80::1%lo0]:8080:[fe80::2%en0]:80") == true)
    }

    @Test func portLibreAvecZone() throws {
        // Un port libre est libre sur la zone ; un écouteur réel sur fe80::1%lo0 le rend occupé.
        let free = try LocalSSHD.freePort()
        #expect(TunnelPortCheck.isFree(address: "fe80::1%lo0", port: free))
        #expect(TunnelPortCheck.isFree(address: "[fe80::1%lo0]", port: free))
        let s = socket(AF_INET6, SOCK_STREAM, 0)
        defer { close(s) }
        var ai: UnsafeMutablePointer<addrinfo>?
        var hints = addrinfo(); hints.ai_family = AF_INET6; hints.ai_socktype = SOCK_STREAM
        #expect(getaddrinfo("fe80::1%lo0", String(free), &hints, &ai) == 0)
        defer { freeaddrinfo(ai) }
        #expect(bind(s, ai!.pointee.ai_addr, ai!.pointee.ai_addrlen) == 0 && listen(s, 1) == 0)
        #expect(!TunnelPortCheck.isFree(address: "fe80::1%lo0", port: free), "écouteur actif sur la zone : port occupé")
        #expect(!TunnelPortCheck.isFree(address: "[fe80::1%lo0]", port: free))
    }

    @Test func zoneLocaleIPv6VerifieParCurl() async throws {
        let http = try TestHTTPServer(body: "via-zone", ipv6: true)
        defer { http.stop() }
        try await LocalSSHD.with { d in
            try await withController(d) { c, _ in
                let port = try LocalSSHD.freePort()
                let spec = TunnelSpec(kind: .local, bindAddress: "[fe80::1%lo0]", bindPort: port, destinationHost: "::1", destinationPort: http.port)
                #expect(await c.start(spec) == .active)
                let r = curl(["-g", "http://[fe80::1%25lo0]:\(port)/"])
                #expect(r.status == 0 && r.output == "via-zone", "curl : \(r)")
                #expect(await c.stop(spec.id) == .stopped)
                #expect(await eventually { curl(["-g", "http://[fe80::1%25lo0]:\(port)/"]).status != 0 }, "le port doit être fermé")
                // Interface inexistante : refus à la validation, jamais d'appel à ssh.
                let ghost = TunnelSpec(kind: .local, bindAddress: "fe80::1%nonexist9", bindPort: port, destinationHost: "::1", destinationPort: http.port)
                guard case .failed(let m) = await c.start(ghost) else { Issue.record("échec attendu"); return }
                #expect(m.contains("n'existe pas"), "message : \(m)")
            }
        }
    }

    @Test func argumentsIPv6AvecCrochets() throws {
        // Syntaxe vérifiée avec OpenSSH 10 : sans crochets ssh répond « Bad local forwarding specification ».
        #expect(TunnelSpec(kind: .local, bindAddress: "::1", bindPort: 8080, destinationHost: "::1", destinationPort: 80).specArgument == "[::1]:8080:[::1]:80")
        #expect(TunnelSpec(kind: .remote, bindAddress: "[::1]", bindPort: 8080, destinationHost: "db", destinationPort: 80).specArgument == "[::1]:8080:db:80")
        #expect(TunnelSpec(kind: .dynamic, bindAddress: "::", bindPort: 1080).specArgument == "[::]:1080")
        #expect(TunnelSpec(kind: .local, bindPort: 8080, destinationHost: "db", destinationPort: 80).specArgument == "127.0.0.1:8080:db:80")
        let b = try OpenSSHCommandBuilder(profile: HostProfile(name: "h", host: "h"), controlPath: "/tmp/x/m", options: .init())
        let args = try b.controlArguments(.forward(TunnelSpec(kind: .local, bindAddress: "::1", bindPort: 8080, destinationHost: "::1", destinationPort: 80)))
        #expect(args.contains("[::1]:8080:[::1]:80"))
    }

    @Test func ipv6AffichageEtComparaison() {
        let t = TunnelSpec(kind: .local, bindAddress: "::1", bindPort: 8080, destinationHost: "::1", destinationPort: 80)
        #expect(t.summary == "Local [::1]:8080 → [::1]:80")
        #expect(t.clientURL == "http://[::1]:8080")
        #expect(TunnelSpec(kind: .dynamic, bindAddress: "::", bindPort: 1080).clientURL == "socks5://[::1]:1080")
        #expect(TunnelValidation.isLoopback("::1") && TunnelValidation.isLoopback("[::1]") && !TunnelValidation.isLoopback("::"))
        #expect(!TunnelValidation.warnings(t).contains { $0.contains("réseau") })
        #expect(!TunnelValidation.warnings(TunnelSpec(kind: .local, bindAddress: "::", bindPort: 8080, destinationHost: "h", destinationPort: 1)).isEmpty)
        // Deux écritures de la même adresse : doublon.
        let a = TunnelSpec(kind: .local, bindAddress: "::1", bindPort: 8080, destinationHost: "h", destinationPort: 1)
        let b = TunnelSpec(kind: .local, bindAddress: "0:0:0:0:0:0:0:1", bindPort: 8080, destinationHost: "h", destinationPort: 1)
        #expect(TunnelValidation.listErrors([a, b]).count == 1)
        #expect(a.sameForwarding(as: b))
    }

    @Test func portZeroPourRemoteSeulement() throws {
        #expect(TunnelValidation.errors(TunnelSpec(kind: .remote, bindPort: 0, destinationHost: "h", destinationPort: 1)).isEmpty)
        #expect(!TunnelValidation.errors(TunnelSpec(kind: .local, bindPort: 0, destinationHost: "h", destinationPort: 1)).isEmpty)
        #expect(!TunnelValidation.errors(TunnelSpec(kind: .dynamic, bindPort: 0)).isEmpty)
        #expect(TunnelValidation.warnings(TunnelSpec(kind: .remote, bindPort: 0, destinationHost: "h", destinationPort: 1)).first?.contains("attribue") == true)
        let b = try OpenSSHCommandBuilder(profile: HostProfile(name: "h", host: "h"), controlPath: "/tmp/x/m", options: .init())
        #expect(throws: (any Error).self) { try b.controlArguments(.forward(TunnelSpec(kind: .local, bindPort: 0, destinationHost: "h", destinationPort: 1))) }
        #expect(try b.controlArguments(.forward(TunnelSpec(kind: .remote, bindPort: 0, destinationHost: "h", destinationPort: 1))).contains("127.0.0.1:0:h:1"))
    }

    @Test func fichesDEditionValidations() {
        // Ce que la fiche d'édition affiche comme erreur bloquante, cas par cas.
        func first(_ s: TunnelSpec) -> String? { TunnelValidation.errors(s).first }
        #expect(first(TunnelSpec(kind: .local, bindPort: 65536, destinationHost: "h", destinationPort: 1))?.contains("65535") == true)
        #expect(first(TunnelSpec(kind: .local, bindPort: 1, destinationHost: "  ", destinationPort: 1))?.contains("obligatoire") == true)
        #expect(first(TunnelSpec(kind: .local, bindPort: 1, destinationHost: "h", destinationPort: 0))?.contains("destination") == true)
        #expect(first(TunnelSpec(kind: .local, bindAddress: "*", bindPort: 1, destinationHost: "*", destinationPort: 1))?.contains("*") == true)
        #expect(first(TunnelSpec(kind: .local, bindAddress: " 127.0.0.1", bindPort: 1, destinationHost: "h", destinationPort: 1))?.contains("espaces") == true)
        #expect(first(TunnelSpec(kind: .local, bindAddress: "::zz", bindPort: 1, destinationHost: "h", destinationPort: 1))?.contains("IPv6") == true)
        // Le type dynamique ignore la destination, même invalide.
        #expect(TunnelValidation.errors(TunnelSpec(kind: .dynamic, bindPort: 1080, destinationHost: "a b", destinationPort: -1)).isEmpty)
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

    @Test func ipv6LocalVerifieParCurl() async throws {
        let http = try TestHTTPServer(body: "via-L6", ipv6: true)
        defer { http.stop() }
        try await LocalSSHD.with { d in
            try await withController(d) { c, _ in
                let port = try LocalSSHD.freePort()
                let spec = TunnelSpec(kind: .local, bindAddress: "::1", bindPort: port, destinationHost: "::1", destinationPort: http.port)
                #expect(await c.start(spec) == .active)
                let r = curl(["-g", "http://[::1]:\(port)/"])
                #expect(r.status == 0 && r.output == "via-L6", "curl : \(r)")
                #expect(await c.stop(spec.id) == .stopped)
                #expect(await eventually { curl(["-g", "http://[::1]:\(port)/"]).status != 0 }, "le port IPv6 doit être fermé")
                // Port IPv6 déjà pris : message clair, sans ouvrir.
                let squat = try TestHTTPServer(ipv6: true); defer { squat.stop() }
                let busy = TunnelSpec(kind: .local, bindAddress: "[::1]", bindPort: squat.port, destinationHost: "::1", destinationPort: 9)
                guard case .failed(let m) = await c.start(busy) else { Issue.record("échec attendu"); return }
                #expect(m.contains("déjà utilisé"), "message : \(m)")
            }
        }
    }

    @Test func ipv6DynamicEtRemoteVerifiesParCurl() async throws {
        let http = try TestHTTPServer(body: "via-6", ipv6: true)
        defer { http.stop() }
        try await LocalSSHD.with { d in
            try await withController(d) { c, _ in
                let dport = try LocalSSHD.freePort()
                let dyn = TunnelSpec(kind: .dynamic, bindAddress: "::1", bindPort: dport)
                #expect(await c.start(dyn) == .active)
                let r = curl(["-g", "--socks5-hostname", "[::1]:\(dport)", "http://[::1]:\(http.port)/"])
                #expect(r.status == 0 && r.output == "via-6", "curl SOCKS : \(r)")
                // Distant : sshd écoute sur ::1 (cette machine fait office de serveur), la sonde distante vise ::1.
                let rport = try LocalSSHD.freePort()
                let rem = TunnelSpec(kind: .remote, bindAddress: "::1", bindPort: rport, destinationHost: "::1", destinationPort: http.port)
                #expect(await c.start(rem) == .active)
                let r2 = curl(["-g", "http://[::1]:\(rport)/"])
                #expect(r2.status == 0 && r2.output == "via-6", "curl R : \(r2)")
                #expect(await c.stop(rem.id) == .stopped)
                #expect(await eventually { curl(["-g", "http://[::1]:\(rport)/"]).status != 0 }, "le port distant IPv6 doit être fermé")
                #expect(await c.stop(dyn.id) == .stopped)
            }
        }
    }

    @Test func remotePortZeroRecupereLePortAttribue() async throws {
        let http = try TestHTTPServer(body: "via-R0"), other = try TestHTTPServer(body: "via-R0")
        defer { http.stop(); other.stop() }
        try await LocalSSHD.with { d in
            try await withController(d) { c, t in
                let spec = TunnelSpec(kind: .remote, bindPort: 0, destinationHost: "127.0.0.1", destinationPort: http.port)
                #expect(await c.start(spec) == .active)
                let port = try #require(await c.allocatedPort(of: spec.id), "port attribué attendu")
                #expect(port > 0)
                let r = curl(["http://127.0.0.1:\(port)/"])
                #expect(r.status == 0 && r.output == "via-R0", "curl : \(r)")
                // Un -R 0 identique est fusionné par ssh (même port) : refusé plutôt que de partager l'annulation.
                let twin = TunnelSpec(kind: .remote, bindPort: 0, destinationHost: "127.0.0.1", destinationPort: http.port)
                guard case .failed(let tm) = await c.start(twin) else { Issue.record("jumeau : échec attendu"); return }
                #expect(tm.contains("identique"), "message : \(tm)")
                #expect(curl(["http://127.0.0.1:\(port)/"]).output == "via-R0", "le premier doit rester ouvert")
                // Une autre destination reçoit un autre port.
                let second = TunnelSpec(kind: .remote, bindPort: 0, destinationHost: "127.0.0.1", destinationPort: other.port)
                #expect(await c.start(second) == .active)
                let port2 = try #require(await c.allocatedPort(of: second.id))
                #expect(port2 != port)
                // L'arrêt annule le port attribué, pas « 0 ».
                let stopped = await c.stop(spec.id)
                #expect(stopped == .stopped, "\(stopped)")
                #expect(await eventually { LocalSSHD.portAccepts(port) == false }, "le port attribué doit être fermé")
                #expect(await c.allocatedPort(of: spec.id) == nil)
                #expect(curl(["http://127.0.0.1:\(port2)/"]).output == "via-R0")
                #expect(await c.stop(second.id) == .stopped)
                #expect(await t.activeTunnels.isEmpty)
            }
        }
    }

    @Test func modifierUnTunnelActifPuisRetablirSiEchec() async throws {
        let a = try TestHTTPServer(body: "serveur-A"), b = try TestHTTPServer(body: "serveur-B")
        let squatter = try TestHTTPServer()
        defer { a.stop(); b.stop(); squatter.stop() }
        try await LocalSSHD.with { d in
            try await withController(d) { c, t in
                let port = try LocalSSHD.freePort()
                var spec = TunnelSpec(kind: .local, bindPort: port, destinationHost: "127.0.0.1", destinationPort: a.port, name: "web")
                #expect(await c.start(spec) == .active)
                #expect(curl(["http://127.0.0.1:\(port)/"]).output == "serveur-A")
                // Même port d'écoute, autre destination : annulation puis réouverture.
                spec.destinationPort = b.port
                let ok = await c.replace(with: spec)
                #expect(ok == .init(state: .active, applied: true, restored: false, error: nil), "\(ok)")
                #expect(curl(["http://127.0.0.1:\(port)/"]).output == "serveur-B")
                // Redirection identique (seul le nom change) : rien n'est touché.
                spec.name = "renommé"
                #expect(await c.replace(with: spec).applied)
                // Nouveau tunnel invalide : refusé avant d'annuler l'ancien.
                var bad = spec; bad.destinationHost = ""
                let r0 = await c.replace(with: bad)
                #expect(!r0.applied && !r0.restored && r0.error != nil && r0.state == .active)
                #expect(curl(["http://127.0.0.1:\(port)/"]).output == "serveur-B")
                // Nouveau en échec (port d'écoute occupé par un autre programme) : l'ancien est rétabli.
                var clash = spec; clash.bindPort = squatter.port
                let r1 = await c.replace(with: clash)
                #expect(!r1.applied && r1.restored && r1.state == .active, "\(r1)")
                #expect(r1.error?.contains("déjà utilisé") == true, "\(String(describing: r1.error))")
                #expect(curl(["http://127.0.0.1:\(port)/"]).output == "serveur-B", "l'ancien tunnel doit tourner de nouveau")
                #expect(curl(["http://127.0.0.1:\(squatter.port)/"]).output == squatter.body)
                #expect(await c.state(of: spec.id) == .active)
                #expect(await t.activeTunnels.count == 1)
                // Changement de port d'écoute réussi : l'ancien port se ferme.
                var moved = spec; moved.bindPort = try LocalSSHD.freePort()
                #expect(await c.replace(with: moved).applied)
                #expect(curl(["http://127.0.0.1:\(moved.bindPort)/"]).output == "serveur-B")
                #expect(await eventually { LocalSSHD.portAccepts(port) == false })
                // Un tunnel arrêté n'est pas ouvert par une modification.
                #expect(await c.stop(spec.id) == .stopped)
                let r2 = await c.replace(with: moved)
                #expect(!r2.applied && r2.state == .stopped)
                #expect(LocalSSHD.portAccepts(moved.bindPort) == false)
            }
        }
    }

    @Test func modifierUnTunnelRemoteRetablitSiEchec() async throws {
        let http = try TestHTTPServer(body: "via-R")
        let taken = try TestHTTPServer()
        defer { http.stop(); taken.stop() }
        try await LocalSSHD.with { d in
            try await withController(d) { c, _ in
                let rport = try LocalSSHD.freePort()
                var spec = TunnelSpec(kind: .remote, bindPort: rport, destinationHost: "127.0.0.1", destinationPort: http.port)
                #expect(await c.start(spec) == .active)
                spec.bindPort = taken.port // port distant déjà occupé : sshd refuse
                let r = await c.replace(with: spec)
                #expect(!r.applied && r.restored && r.error?.isEmpty == false, "\(r)")
                #expect(curl(["http://127.0.0.1:\(rport)/"]).output == "via-R", "l'ancien -R doit être rétabli")
                spec.bindPort = 0 // vers un port attribué
                let r2 = await c.replace(with: spec)
                #expect(r2.applied)
                let allocated = try #require(await c.allocatedPort(of: spec.id))
                #expect(curl(["http://127.0.0.1:\(allocated)/"]).output == "via-R")
                #expect(await eventually { LocalSSHD.portAccepts(rport) == false })
            }
        }
    }
}
