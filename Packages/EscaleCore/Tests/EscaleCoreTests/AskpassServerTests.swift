import Foundation
import Testing
@testable import EscaleCore

private func permissions(_ path: String) throws -> Int {
    let a = try FileManager.default.attributesOfItem(atPath: path)
    return (a[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

@Suite("Askpass : serveur et protocole du socket", .serialized)
struct AskpassServerTests {
    @Test func demarrageDroitsCheminCourtEtArretPropre() async throws {
        let server = AskpassServer(responder: ScriptedResponder { _ in .cancel })
        let ep = try await server.start()
        let dir = (ep.socketPath as NSString).deletingLastPathComponent
        #expect(ep.socketPath.utf8.count < 100)
        #expect(try permissions(dir) == 0o700)
        #expect(try permissions(ep.socketPath) == 0o600)
        #expect(ep.token.count == 64)
        await #expect(throws: AskpassServer.StartError.alreadyRunning) { try await server.start() }
        await server.stop()
        #expect(!FileManager.default.fileExists(atPath: ep.socketPath))
        #expect(!FileManager.default.fileExists(atPath: dir))
        await server.stop()   // idempotent
    }

    @Test func cheminLongRepliSurTmp() async throws {
        let long = "/tmp/" + String(repeating: "a", count: 120)
        try FileManager.default.createDirectory(atPath: long, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: long) }
        let server = AskpassServer(responder: ScriptedResponder { _ in .cancel }, socketDirectory: long)
        let ep = try await server.start()
        #expect(ep.socketPath.utf8.count < 100)
        await server.stop()
    }

    @Test func jetonsDifferentsParServeur() async throws {
        let a = AskpassServer(responder: ScriptedResponder { _ in .cancel })
        let b = AskpassServer(responder: ScriptedResponder { _ in .cancel })
        let ea = try await a.start(), eb = try await b.start()
        #expect(ea.token != eb.token && ea.socketPath != eb.socketPath)
        await a.stop(); await b.stop()
    }

    @Test func echangeNominalSecretPuisRefus() async throws {
        let responder = ScriptedResponder { r in
            if case .password = r.kind { return .secret(Secret("s3cr3t"), remember: false) }
            return .cancel
        }
        let server = AskpassServer(responder: responder)
        let ep = try await server.start()
        let ok = await askpassRequest(socket: ep.socketPath, token: ep.token, prompt: "rayan@127.0.0.1's password: ")
        #expect(ok == Data("s3cr3t".utf8))
        let no = await askpassRequest(socket: ep.socketPath, token: ep.token, prompt: "Enter passphrase for key 'k': ")
        #expect(no == nil)
        let events = await server.events
        #expect(events == [.answered(.password(userAtHost: "rayan@127.0.0.1")), .cancelled(.passphrase(keyPath: "k"))])
        let seen = await responder.requests
        #expect(seen.map(\.attempt) == [1, 1])
        await server.stop()
    }

    @Test func memeInviteDeuxFoisIncrementeLaTentative() async throws {
        let responder = ScriptedResponder { _ in .secret(Secret("x"), remember: false) }
        let server = AskpassServer(responder: responder)
        let ep = try await server.start()
        for _ in 0..<3 { _ = await askpassRequest(socket: ep.socketPath, token: ep.token, prompt: "u@h's password: ") }
        #expect(await responder.requests.map(\.attempt) == [1, 2, 3])
        await server.stop()
    }

    @Test func jetonInvalideRejeteSansInterrogerLeResponder() async throws {
        let responder = ScriptedResponder { _ in .secret(Secret("fuite"), remember: false) }
        let server = AskpassServer(responder: responder)
        let ep = try await server.start()
        let bad = String(repeating: "0", count: 64)
        #expect(await askpassRequest(socket: ep.socketPath, token: bad, prompt: "p") == nil)
        #expect(await askpassRequest(socket: ep.socketPath, token: "", prompt: "p") == nil)
        #expect(await responder.requests.isEmpty)
        #expect(await server.events == [.rejected(.badToken), .rejected(.badToken)])
        await server.stop()
    }

    @Test func enteteInconnuEtCadreIncoherent() async throws {
        let responder = ScriptedResponder { _ in .secret(Secret("x"), remember: false) }
        let server = AskpassServer(responder: responder)
        let ep = try await server.start()
        func frame(_ s: String) -> [UInt8] { let b = Array(s.utf8); return [0, 0, UInt8(b.count >> 8), UInt8(b.count & 0xff)] + b }
        #expect(await rawAskpassExchange(socket: ep.socketPath, send: frame("AUTRE/9\n\(ep.token)\np"))?.isEmpty == true)
        #expect(await rawAskpassExchange(socket: ep.socketPath, send: frame("ESCALE-ASKPASS/1\n\(ep.token)"))?.isEmpty == true)  // pas d'invite
        #expect(await responder.requests.isEmpty)
        #expect(await server.events == [.rejected(.malformed), .rejected(.malformed)])
        await server.stop()
    }

    @Test func messageTropLongRejete() async throws {
        let responder = ScriptedResponder { _ in .secret(Secret("x"), remember: false) }
        let server = AskpassServer(responder: responder, limits: .init(maxFrameBytes: 256))
        let ep = try await server.start()
        // Annonce de 1 Mio : refusé dès l'en-tête, sans lire le corps.
        let reply = await rawAskpassExchange(socket: ep.socketPath, send: [0, 0x10, 0, 0])
        #expect(reply?.isEmpty == true)
        // Cadre légitime mais au-dessus de la limite.
        #expect(await askpassRequest(socket: ep.socketPath, token: ep.token, prompt: String(repeating: "A", count: 1000)) == nil)
        #expect(await server.events == [.rejected(.tooLarge), .rejected(.tooLarge)])
        #expect(await responder.requests.isEmpty)
        // La limite ne casse pas les requêtes normales.
        #expect(await askpassRequest(socket: ep.socketPath, token: ep.token, prompt: "ok") == Data("x".utf8))
        await server.stop()
    }

    @Test func pairInattenduRejete() async throws {
        let responder = ScriptedResponder { _ in .secret(Secret("x"), remember: false) }
        // Simule un autre uid : le serveur attend un uid différent du nôtre.
        let server = AskpassServer(responder: responder, limits: .init(expectedPeerUID: geteuid() &+ 1))
        let ep = try await server.start()
        #expect(await askpassRequest(socket: ep.socketPath, token: ep.token, prompt: "p") == nil)
        #expect(await responder.requests.isEmpty)
        #expect(await server.events == [.rejected(.badPeer)])
        await server.stop()
    }

    @Test func clientSilencieuxCoupeApresLeDelaiDeLecture() async throws {
        let server = AskpassServer(responder: ScriptedResponder { _ in .cancel }, limits: .init(readTimeout: 0.3))
        let ep = try await server.start()
        let started = Date()
        let reply = await rawAskpassExchange(socket: ep.socketPath, send: [0, 0, 0, 40, 1, 2], readFor: 3)   // cadre annoncé, jamais complété
        #expect(reply?.isEmpty == true)
        #expect(Date().timeIntervalSince(started) < 2, "la connexion doit être coupée vers 0,3 s")
        #expect(await askpassEventually { await server.events == [.rejected(.timeout)] })
        await server.stop()
    }

    @Test func responderTropLentRefuseApresLeDelai() async throws {
        let responder = ScriptedResponder(delay: .seconds(5)) { _ in .secret(Secret("trop-tard"), remember: false) }
        let server = AskpassServer(responder: responder, limits: .init(responseTimeout: 0.3))
        let ep = try await server.start()
        let started = Date()
        let reply = await askpassRequest(socket: ep.socketPath, token: ep.token, prompt: "u@h's password: ")
        #expect(reply == nil)
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(await server.outcome.timedOut)
        #expect(await server.outcome.secretProvided == false)
        await server.stop()
    }

    @Test func arretRefuseLesInvitesEnAttente() async throws {
        let responder = ScriptedResponder(delay: .seconds(30)) { _ in .secret(Secret("x"), remember: false) }
        let server = AskpassServer(responder: responder)
        let ep = try await server.start()
        async let pending = askpassRequest(socket: ep.socketPath, token: ep.token, prompt: "u@h's password: ")
        #expect(await askpassEventually { await server.pendingPromptCount == 1 })
        await server.stop()
        #expect(await pending == nil)
        #expect(!FileManager.default.fileExists(atPath: ep.socketPath))
    }

    @Test func cleDHoteModifieeToujoursRefuseeSansResponder() async throws {
        let responder = ScriptedResponder { _ in .accept }
        let server = AskpassServer(responder: responder)
        let ep = try await server.start()
        let text = "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!\nAre you sure you want to continue connecting (yes/no)? "
        #expect(await askpassRequest(socket: ep.socketPath, token: ep.token, prompt: text) == nil)
        #expect(await responder.requests.isEmpty)
        #expect(await server.outcome.hostKeyChanged)
        await server.stop()
    }

    @Test func confirmationCleDHoteEtDecisionsIncoherentes() async throws {
        let responder = ScriptedResponder { r in
            if case .hostKeyConfirmation = r.kind { return .accept }
            return .accept   // .accept hors clé d'hôte : doit être traité comme un refus
        }
        let server = AskpassServer(responder: responder)
        let ep = try await server.start()
        let hk = "The authenticity of host 'h' can't be established.\nED25519 key fingerprint is: SHA256:abc.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? "
        #expect(await askpassRequest(socket: ep.socketPath, token: ep.token, prompt: hk) == Data("yes".utf8))
        #expect(await askpassRequest(socket: ep.socketPath, token: ep.token, prompt: "u@h's password: ") == nil)
        await server.stop()
    }

    @Test func environnementSshComplet() async throws {
        let server = AskpassServer(responder: ScriptedResponder { _ in .cancel })
        await #expect(throws: AskpassServer.StartError.self) { try await server.environment(askpassExecutable: "/x") }
        let ep = try await server.start()
        let env = try await server.environment(askpassExecutable: "/chemin/escale-askpass")
        #expect(env == ["SSH_ASKPASS": "/chemin/escale-askpass", "SSH_ASKPASS_REQUIRE": "force",
                        "ESCALE_ASKPASS_SOCKET": ep.socketPath, "ESCALE_ASKPASS_TOKEN": ep.token])
        await server.stop()
    }

    // MARK: - Client

    @Test func clientRunSansVariablesNeFaitRien() {
        var out = Data()
        #expect(AskpassClient.run(arguments: ["invite"], environment: [:]) { out.append($0) } == 2)
        #expect(out.isEmpty)
    }

    @Test func clientRunEcritSecretEtNewlineOuRienEnCasDeRefus() async throws {
        let responder = ScriptedResponder { r in r.text.contains("ok") ? .secret(Secret("réponse"), remember: false) : .cancel }
        let server = AskpassServer(responder: responder)
        let ep = try await server.start()
        let env = [AskpassClient.socketVariable: ep.socketPath, AskpassClient.tokenVariable: ep.token]
        let (code, out) = await withCheckedContinuation { (c: CheckedContinuation<(Int32, Data), Never>) in
            DispatchQueue.global().async {
                var d = Data(); let rc = AskpassClient.run(arguments: ["u@h's", "password:", "ok"], environment: env) { d.append($0) }
                c.resume(returning: (rc, d))
            }
        }
        #expect(code == 0)
        #expect(out == Data("réponse\n".utf8))
        let (code2, out2) = await withCheckedContinuation { (c: CheckedContinuation<(Int32, Data), Never>) in
            DispatchQueue.global().async {
                var d = Data(); let rc = AskpassClient.run(arguments: ["refus"], environment: env) { d.append($0) }
                c.resume(returning: (rc, d))
            }
        }
        #expect(code2 == 1 && out2.isEmpty)
        await server.stop()
    }

    @Test func serveurAbsentCodeDeSortieNonNul() {
        var out = Data()
        let env = [AskpassClient.socketVariable: "/tmp/escale-inexistant-\(UUID().uuidString)", AskpassClient.tokenVariable: "t"]
        #expect(AskpassClient.run(arguments: ["p"], environment: env) { out.append($0) } == 1)
        #expect(out.isEmpty)
    }

    @Test func executableEscaleAskpassDeBoutEnBout() async throws {
        let path = askpassExecutablePath()
        #expect(FileManager.default.isExecutableFile(atPath: path), "escale-askpass introuvable : \(path)")
        let responder = ScriptedResponder { r in r.text.hasPrefix("Enter passphrase") ? .secret(Secret("p@ss"), remember: false) : .cancel }
        let server = AskpassServer(responder: responder)
        let ep = try await server.start()
        let env = try await server.environment(askpassExecutable: path)
        let ok = await OpenSSHProcessRunner.run(executable: path, arguments: ["Enter passphrase for key 'k': "], environment: env, timeout: 10)
        #expect(ok.status == 0 && ok.stdout == "p@ss\n" && ok.stderr.isEmpty, "stdout=\(ok.stdout) stderr=\(ok.stderr)")
        let refus = await OpenSSHProcessRunner.run(executable: path, arguments: ["autre"], environment: env, timeout: 10)
        #expect(refus.status == 1 && refus.stdout.isEmpty)
        // Sans variables : sortie 2, rien sur stdout. (L'environnement du test ne contient pas ESCALE_ASKPASS_*.)
        let bare = await OpenSSHProcessRunner.run(executable: path, arguments: ["x"], environment: [AskpassClient.socketVariable: "", AskpassClient.tokenVariable: ""], timeout: 10)
        #expect(bare.status == 2 && bare.stdout.isEmpty)
        _ = ep
        await server.stop()
    }
}
