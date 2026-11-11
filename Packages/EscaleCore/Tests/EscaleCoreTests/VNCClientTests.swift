import Foundation
import Testing
@testable import EscaleCore

/// Client RFB contre un serveur scripté en mémoire (aucun réseau).
@Suite("VNC : client RFB (serveur scripté)", .timeLimit(.minutes(1)))
struct VNCClientTests {
    let noCredentials: RFBCredentialsProvider = { _ in nil }

    /// Serveur 3.8 : version, sécurité « Aucune », ServerInit ; lit ensuite les messages d'initialisation du client.
    func serve38None(_ s: VNCLoopbackEnd, width: Int = 32, height: Int = 16, name: String = "bureau-test") async throws -> (shared: UInt8, pixelFormat: [UInt8], encodings: [Int32]) {
        try await s.send(Array("RFB 003.008\n".utf8))
        #expect(try await s.read(12) == Array("RFB 003.008\n".utf8))
        try await s.send([1, 1])
        #expect(try await s.read(1) == [1])
        try await s.send(be32(0))
        let shared = try await s.read(1)[0]
        try await s.send(vncServerInit(width: width, height: height, name: name))
        let spf = try await s.read(20)
        let se = try await s.read(4)
        let n = Int(se[2]) << 8 | Int(se[3])
        let raw = try await s.read(n * 4)
        let encs = stride(from: 0, to: raw.count, by: 4).map { Int32(bitPattern: UInt32(raw[$0]) << 24 | UInt32(raw[$0 + 1]) << 16 | UInt32(raw[$0 + 2]) << 8 | UInt32(raw[$0 + 3])) }
        let req = try await s.read(10)
        #expect(req == [3, 0, 0, 0, 0, 0] + be16(width) + be16(height))
        return (shared, Array(spf[4...]), encs)
    }

    func collect(_ client: RFBClient, until: (RFBEvent) -> Bool) async -> [RFBEvent] {
        var out: [RFBEvent] = []
        for await e in client.events { out.append(e); if until(e) { break } }
        return out
    }

    @Test func poigneeDeMain38SansAuthentification() async throws {
        let (c, s) = VNCLoopbackEnd.pair()
        let client = RFBClient(transport: c, configuration: RFBConfiguration(shared: true, encodings: RFBEncoding.list(for: .hextile)))
        async let server = serve38None(s)
        let info = try await client.connect(credentials: noCredentials)
        let seen = try await server
        #expect(info == RFBServerInfo(name: "bureau-test", width: 32, height: 16, version: "3.8", securityType: 1))
        #expect(seen.shared == 1)
        #expect(seen.pixelFormat == RFBPixelFormat.bgra32.wireBytes)
        #expect(seen.encodings == [5, 1, 0, -239, -223])
        #expect(client.framebuffer.width == 32 && client.framebuffer.height == 16)
        await client.disconnect()
    }

    @Test func sessionExclusiveEnvoieShared0() async throws {
        let (c, s) = VNCLoopbackEnd.pair()
        let client = RFBClient(transport: c, configuration: RFBConfiguration(shared: false))
        async let server = serve38None(s)
        _ = try await client.connect(credentials: noCredentials)
        #expect(try await server.shared == 0)
        await client.disconnect()
    }

    @Test func authentificationVNCReussie() async throws {
        let (c, s) = VNCLoopbackEnd.pair()
        let client = RFBClient(transport: c)
        let challenge = Array(0..<16).map { UInt8($0 &* 7 &+ 1) }
        let server = Task {
            try await s.send(Array("RFB 003.008\n".utf8)); _ = try await s.read(12)
            try await s.send([3, 30, 2, 16]) // VNC et ARD proposés : le client prend VNC (pas d'identifiant utilisateur requis)
            #expect(try await s.read(1) == [2])
            try await s.send(challenge)
            let answer = try await s.read(16)
            #expect(answer == VNCDES.vncResponse(challenge: challenge, password: "s3cret"))
            try await s.send(be32(0))
            _ = try await s.read(1)
            try await s.send(vncServerInit(width: 8, height: 8, name: "x"))
        }
        let info = try await client.connect(credentials: { req in
            #expect(req.kind == .vncPassword)
            return RFBCredentials(password: "s3cret")
        })
        try await server.value
        #expect(info.securityType == 2)
        await client.disconnect()
    }

    @Test func motDePasseRefuseAvecMessageDuServeur() async throws {
        let (c, s) = VNCLoopbackEnd.pair()
        let client = RFBClient(transport: c)
        let server = Task {
            try await s.send(Array("RFB 003.008\n".utf8)); _ = try await s.read(12)
            try await s.send([1, 2]); _ = try await s.read(1)
            try await s.send([UInt8](repeating: 9, count: 16)); _ = try await s.read(16)
            let why = Array("Too many failures".utf8)
            try await s.send(be32(1) + be32(UInt32(why.count)) + why)
        }
        do {
            _ = try await client.connect(credentials: { _ in RFBCredentials(password: "faux") })
            Issue.record("devait échouer")
        } catch let e as RFBError {
            guard case .authenticationFailed(let m) = e else { Issue.record("mauvaise erreur : \(e)"); return }
            #expect(m.contains("Too many failures"))
            #expect(!m.contains("faux"))
        }
        try await server.value
    }

    @Test func annulationDeLaSaisieDuMotDePasse() async throws {
        let (c, s) = VNCLoopbackEnd.pair()
        let client = RFBClient(transport: c)
        let server = Task {
            try await s.send(Array("RFB 003.008\n".utf8)); _ = try await s.read(12)
            try await s.send([1, 2]); _ = try await s.read(1)
            try await s.send([UInt8](repeating: 1, count: 16))
        }
        await #expect(throws: RFBError.authenticationCancelled) { _ = try await client.connect(credentials: { _ in nil }) }
        try await server.value
    }

    @Test func serveurQuiRefuseAvantLAuthentification() async throws {
        let (c, s) = VNCLoopbackEnd.pair()
        let client = RFBClient(transport: c)
        let server = Task {
            try await s.send(Array("RFB 003.008\n".utf8)); _ = try await s.read(12)
            let why = Array("Trop de clients".utf8)
            try await s.send([0] + be32(UInt32(why.count)) + why)
        }
        await #expect(throws: RFBError.refused("Trop de clients")) { _ = try await client.connect(credentials: { _ in nil }) }
        try await server.value
    }

    @Test func aucunTypeDeSecuriteCommun() async throws {
        let (c, s) = VNCLoopbackEnd.pair()
        let client = RFBClient(transport: c)
        let server = Task { try await s.send(Array("RFB 003.008\n".utf8)); _ = try await s.read(12); try await s.send([2, 16, 19]) }
        await #expect(throws: RFBError.unsupportedSecurity([16, 19])) { _ = try await client.connect(credentials: { _ in nil }) }
        try await server.value
    }

    @Test func versionNonRFBRefusee() async throws {
        let (c, s) = VNCLoopbackEnd.pair()
        let client = RFBClient(transport: c)
        let server = Task { try await s.send(Array("SSH-2.0-Open".utf8)) }
        do { _ = try await client.connect(credentials: { _ in nil }); Issue.record("devait échouer") }
        catch let e as RFBError { if case .unsupportedVersion = e {} else { Issue.record("mauvaise erreur : \(e)") } }
        try await server.value
    }

    @Test func version33AuthentificationVNC() async throws {
        let (c, s) = VNCLoopbackEnd.pair()
        let client = RFBClient(transport: c)
        let server = Task {
            try await s.send(Array("RFB 003.003\n".utf8))
            #expect(try await s.read(12) == Array("RFB 003.003\n".utf8))
            try await s.send(be32(2)) // 3.3 : le serveur impose le type sans liste
            try await s.send([UInt8](repeating: 3, count: 16)); _ = try await s.read(16)
            try await s.send(be32(0)); _ = try await s.read(1)
            try await s.send(vncServerInit(width: 4, height: 4, name: "vieux"))
        }
        let info = try await client.connect(credentials: { _ in RFBCredentials(password: "pw") })
        try await server.value
        #expect(info.version == "3.3" && info.securityType == 2)
        await client.disconnect()
    }

    @Test func version37SansAuthentificationNAttendPasDeResultat() async throws {
        let (c, s) = VNCLoopbackEnd.pair()
        let client = RFBClient(transport: c)
        let server = Task {
            try await s.send(Array("RFB 003.007\n".utf8)); _ = try await s.read(12)
            try await s.send([1, 1]); _ = try await s.read(1)
            _ = try await s.read(1) // ClientInit directement, sans SecurityResult
            try await s.send(vncServerInit(width: 4, height: 4, name: "s37"))
        }
        let info = try await client.connect(credentials: noCredentials)
        try await server.value
        #expect(info.version == "3.7")
        await client.disconnect()
    }

    @Test func miseAJourOctetParOctetEtEvenements() async throws {
        let (c, s) = VNCLoopbackEnd.pair()
        s.chunkSize = 1 // le client reçoit chaque octet séparément
        c.chunkSize = 1
        let client = RFBClient(transport: c)
        async let initial = serve38None(s, width: 8, height: 4)
        _ = try await client.connect(credentials: noCredentials)
        _ = try await initial

        // Un rectangle Raw 2×1, un RRE, puis cloche.
        let raw: [UInt8] = [10, 20, 30, 0, 40, 50, 60, 0]
        let rre = be32(1) + [1, 2, 3, 0] + [9, 8, 7, 0] + be16(0) + be16(0) + be16(1) + be16(1)
        let update = vncUpdate([(RFBRect(x: 0, y: 0, width: 2, height: 1), 0, raw), (RFBRect(x: 4, y: 1, width: 3, height: 2), 2, rre)]) + [2]
        try await s.send(update)

        let events = await collect(client) { if case .bell = $0 { true } else { false } }
        var rects: [RFBRect] = []
        for case .updated(let r) in events { rects += r }
        #expect(rects == [RFBRect(x: 0, y: 0, width: 2, height: 1), RFBRect(x: 4, y: 1, width: 3, height: 2)])
        #expect(client.framebuffer.pixel(x: 0, y: 0)?.r == 30 && client.framebuffer.pixel(x: 1, y: 0)?.b == 40)
        #expect(client.framebuffer.pixel(x: 4, y: 1)?.b == 9 && client.framebuffer.pixel(x: 5, y: 1)?.b == 1)
        // Après chaque mise à jour, le client redemande de façon incrémentale.
        #expect(try await s.read(10) == [3, 1, 0, 0, 0, 0, 0, 8, 0, 4])
        await client.disconnect()
    }

    @Test func redimensionnementDuBureau() async throws {
        let (c, s) = VNCLoopbackEnd.pair()
        let client = RFBClient(transport: c)
        async let initial = serve38None(s, width: 8, height: 4)
        _ = try await client.connect(credentials: noCredentials)
        _ = try await initial
        try await s.send(vncUpdate([(RFBRect(x: 0, y: 0, width: 20, height: 10), RFBEncoding.desktopSize, [])]))
        let events = await collect(client) { if case .resized = $0 { true } else { false } }
        guard case .resized(let w, let h)? = events.last else { Issue.record("pas de redimensionnement"); return }
        #expect(w == 20 && h == 10 && client.framebuffer.width == 20 && client.framebuffer.height == 10)
        // Demande complète sur la nouvelle taille.
        #expect(try await s.read(10) == [3, 0, 0, 0, 0, 0, 0, 20, 0, 10])
        await client.disconnect()
    }

    @Test func curseurPressePapiersEtSortieClavierSouris() async throws {
        let (c, s) = VNCLoopbackEnd.pair()
        let client = RFBClient(transport: c)
        async let initial = serve38None(s, width: 8, height: 4)
        _ = try await client.connect(credentials: noCredentials)
        _ = try await initial

        // Curseur 2×1 (point chaud 1,0), masque 10xxxxxx ; presse-papiers « héé » en latin-1.
        let cursor = vncUpdate([(RFBRect(x: 1, y: 0, width: 2, height: 1), RFBEncoding.cursor, [1, 2, 3, 0, 4, 5, 6, 0, 0b1000_0000])])
        try await s.send(cursor + [3, 0, 0, 0] + be32(3) + [0x68, 0xe9, 0xe9])
        let events = await collect(client) { if case .clipboard = $0 { true } else { false } }
        var gotCursor: RFBCursor?, gotClip = ""
        for e in events { if case .cursor(let k) = e { gotCursor = k }; if case .clipboard(let t) = e { gotClip = t } }
        #expect(gotCursor == RFBCursor(hotspotX: 1, hotspotY: 0, width: 2, height: 1, bgra: [1, 2, 3, 255, 0, 0, 0, 0]))
        #expect(gotClip == "héé")

        // Entrées : l'ordre d'appel est l'ordre du fil.
        _ = try await s.read(10) // demande incrémentale après la mise à jour
        client.sendKey(keysym: 0xe9, down: true)
        client.sendKey(keysym: 0xe9, down: false)
        client.sendPointer(x: 300, y: -5, buttons: 0b101)
        client.sendClipboard("ok€")
        #expect(try await s.read(8) == [4, 1, 0, 0, 0, 0, 0, 0xe9])
        #expect(try await s.read(8) == [4, 0, 0, 0, 0, 0, 0, 0xe9])
        #expect(try await s.read(6) == [5, 5, 1, 44, 0, 0])
        #expect(try await s.read(11) == [6, 0, 0, 0, 0, 0, 0, 3, 0x6f, 0x6b, 0x3f])
        await client.disconnect()
    }

    @Test func lectureSeuleNEnvoieRien() async throws {
        let (c, s) = VNCLoopbackEnd.pair()
        let client = RFBClient(transport: c, configuration: RFBConfiguration(viewOnly: true))
        async let initial = serve38None(s, width: 8, height: 4)
        _ = try await client.connect(credentials: noCredentials)
        _ = try await initial
        client.sendKey(keysym: 0x61, down: true)
        client.sendPointer(x: 1, y: 1, buttons: 1)
        client.sendClipboard("x")
        try await s.send([2])
        _ = await collect(client) { if case .bell = $0 { true } else { false } }
        // Rien d'autre que d'éventuelles demandes de mise à jour : aucun message 4, 5 ou 6.
        await client.disconnect()
        var seen: [UInt8] = []
        while let chunk = try? await s.incoming.pop() { seen += chunk }
        #expect(!seen.contains { [4, 5, 6].contains($0) && seen.first == $0 })
        #expect(seen.isEmpty || seen[0] == 3)
    }

    @Test func coupureDuServeurTermineLeFlux() async throws {
        let (c, s) = VNCLoopbackEnd.pair()
        let client = RFBClient(transport: c)
        async let initial = serve38None(s, width: 8, height: 4)
        _ = try await client.connect(credentials: noCredentials)
        _ = try await initial
        s.close()
        let events = await collect(client) { if case .disconnected = $0 { true } else { false } }
        guard case .disconnected(let err)? = events.last else { Issue.record("pas de déconnexion"); return }
        #expect(err == .connectionClosed)
    }

    @Test func fermetureVoulueNeSignaleAucuneErreur() async throws {
        let (c, s) = VNCLoopbackEnd.pair()
        let client = RFBClient(transport: c)
        async let initial = serve38None(s, width: 8, height: 4)
        _ = try await client.connect(credentials: noCredentials)
        _ = try await initial
        await client.disconnect()
        let events = await collect(client) { if case .disconnected = $0 { true } else { false } }
        guard case .disconnected(let err)? = events.last else { Issue.record("pas de déconnexion"); return }
        #expect(err == nil)
    }

    @Test func messageServeurInconnuEstUneErreurDeProtocole() async throws {
        let (c, s) = VNCLoopbackEnd.pair()
        let client = RFBClient(transport: c)
        async let initial = serve38None(s, width: 8, height: 4)
        _ = try await client.connect(credentials: noCredentials)
        _ = try await initial
        try await s.send([99])
        let events = await collect(client) { if case .disconnected = $0 { true } else { false } }
        guard case .disconnected(let err)? = events.last, case .protocolViolation? = err else { Issue.record("attendu : violation de protocole"); return }
    }

    @Test func rectangleHorsEcranEstRefuse() async throws {
        let (c, s) = VNCLoopbackEnd.pair()
        let client = RFBClient(transport: c)
        async let initial = serve38None(s, width: 8, height: 4)
        _ = try await client.connect(credentials: noCredentials)
        _ = try await initial
        try await s.send(vncUpdate([(RFBRect(x: 6, y: 0, width: 4, height: 1), 0, [UInt8](repeating: 0, count: 16))]))
        let events = await collect(client) { if case .disconnected = $0 { true } else { false } }
        guard case .disconnected(let err)? = events.last, case .protocolViolation? = err else { Issue.record("attendu : violation de protocole"); return }
    }
}
