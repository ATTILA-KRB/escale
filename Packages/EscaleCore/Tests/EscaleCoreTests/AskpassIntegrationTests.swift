import Foundation
import Testing
@testable import EscaleCore

// Ce que le sshd local non privilégié (UsePAM no, sans root) permet de tester :
//  - phrase de passe d'une clé cliente (publickey) : bout en bout réel (ssh → escale-askpass → socket → responder) ;
//  - confirmation / refus d'une clé d'hôte inconnue, clé d'hôte modifiée : bout en bout réel ;
//  - invite de mot de passe : ssh la pose réellement (PasswordAuthentication yes), mais sshd ne peut jamais VALIDER un mot de passe
//    sans PAM/root : on teste donc l'envoi du secret du store, la non-répétition et les erreurs, JAMAIS une connexion réussie ;
//  - clavier-interactif / 2FA : sans PAM, sshd n'envoie aucune invite ; avec UsePAM yes l'invite « (user@host) Password: » existe
//    (observée à la main) mais l'issue dépendrait du vrai mot de passe du compte : non testé automatiquement.

private func askpassTransport(
    _ d: LocalSSHD, profile: HostProfile? = nil, ssh: OpenSSHOptions? = nil,
    responder: any AskpassResponder, limits: AskpassServer.Limits = .init()
) -> OpenSSHTransport {
    OpenSSHTransport(
        profile: profile ?? d.profile(auth: .keyFile(path: d.passphraseKey)),
        configuration: .init(
            ssh: ssh ?? d.sshOptions(), masterReadyTimeout: 20,
            askpass: AskpassConfiguration(executablePath: askpassExecutablePath(), responder: responder, limits: limits)))
}

/// Erreur levée par `connect()` (nil si connecté) ; déconnecte toujours à la fin.
private func connectOutcome(_ t: OpenSSHTransport) async -> Error? {
    do { try await t.connect(); return nil } catch { return error }
}

private func opts(_ d: LocalSSHD, knownHosts: String, strict: OpenSSHOptions.StrictHostKeyChecking, extra: [String] = []) -> OpenSSHOptions {
    var o = d.sshOptions(extra: extra)
    o.userKnownHostsFile = knownHosts
    o.strictHostKeyChecking = strict
    return o
}

private func passphraseScript(_ good: String = LocalSSHD.passphrase) -> ScriptedResponder.Script {
    { r in
        if case .passphrase = r.kind { return .secret(Secret(good), remember: false) }
        if case .hostKeyConfirmation = r.kind { return .accept }
        return .cancel
    }
}

private func fingerprint(of pubFile: String) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: LocalSSHD.keygenPath)
    p.arguments = ["-l", "-f", pubFile]
    let o = Pipe(); p.standardOutput = o
    try p.run()
    let out = String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return String(out.split(separator: " ")[1])   // « 256 SHA256:… comment (ED25519) »
}

@Suite("Askpass + OpenSSHTransport (sshd local)", .enabled(if: LocalSSHD.isAvailable, "sshd local non privilégié indisponible sur cet hôte"), .serialized)
struct AskpassIntegrationTests {
    // MARK: Phrase de passe

    @Test func phraseDePasseCorrecteBoutEnBout() async throws {
        try await LocalSSHD.with { d in
            let responder = ScriptedResponder(passphraseScript())
            let t = askpassTransport(d, responder: responder)
            do {
                #expect(await connectOutcome(t) == nil)
                #expect(await t.isAlive())
                #expect(d.acceptedAuthenticationCount() == 1)
                let reqs = await responder.requests
                #expect(reqs.count == 1)
                #expect(reqs.first?.kind == .passphrase(keyPath: d.passphraseKey))
                #expect(reqs.first?.text == "Enter passphrase for key '\(d.passphraseKey)': ")
                #expect(await responder.succeeded == 1)
                #expect(await responder.failed == 0)

                // Le serveur askpass vit pendant la connexion : socket 0600 dans un dossier 0700.
                let sock = try #require(await t.askpassSocketPath)
                #expect(sock.utf8.count < 100)
                let dir = (sock as NSString).deletingLastPathComponent
                let sockMode = (try FileManager.default.attributesOfItem(atPath: sock)[.posixPermissions] as? NSNumber)?.intValue
                let dirMode = (try FileManager.default.attributesOfItem(atPath: dir)[.posixPermissions] as? NSNumber)?.intValue
                #expect(sockMode == 0o600 && dirMode == 0o700)

                // Les clients secondaires n'ont besoin d'aucun askpass et ne ré-authentifient pas.
                let sc = try await t.shellCommand(remoteCommand: "echo askpass-ok")
                #expect(!sc.environment.keys.contains("ESCALE_ASKPASS_TOKEN") && !sc.environment.keys.contains("SSH_ASKPASS"))
                #expect(sc.arguments.contains("ControlMaster=no") && sc.arguments.contains("ProxyCommand=/usr/bin/false"))
                let r = await OpenSSHProcessRunner.run(executable: sc.executable, arguments: sc.arguments, environment: sc.environment, timeout: 10)
                #expect(r.status == 0 && r.stdout.contains("askpass-ok"), "stderr : \(r.stderr)")
                let ch = try await t.openSFTPChannel()
                await ch.close()
                #expect(d.acceptedAuthenticationCount() == 1)
                #expect(!(await t.masterJournal()).contains(LocalSSHD.passphrase), "le secret ne doit jamais apparaître dans le journal")

                await t.disconnect()
                #expect(!FileManager.default.fileExists(atPath: sock))
                #expect(!FileManager.default.fileExists(atPath: dir))
                #expect(await t.askpassSocketPath == nil)
            } catch { await t.disconnect(); throw error }
            #expect(askpassPgrep("escale-askpass").isEmpty)
        }
    }

    @Test func mauvaisePhrasePuisDelegationReussit() async throws {
        try await LocalSSHD.with { d in
            // 1er passage : mauvaise phrase ; 2e passage (même invite, attempt 2) : la bonne.
            let responder = ScriptedResponder { r in
                .secret(Secret(r.attempt == 1 ? "mauvaise-phrase" : LocalSSHD.passphrase), remember: false)
            }
            let t = askpassTransport(d, responder: responder)
            do {
                #expect(await connectOutcome(t) == nil)
                #expect(await responder.requests.map(\.attempt) == [1, 2])
                #expect(d.acceptedAuthenticationCount() == 1)
                await t.disconnect()
            } catch { await t.disconnect(); throw error }
        }
    }

    @Test func phraseToujoursFausseDonneWrongSecretSansBoucle() async throws {
        try await LocalSSHD.with { d in
            let responder = ScriptedResponder { _ in .secret(Secret("toujours-faux"), remember: true) }
            let t = askpassTransport(d, responder: responder)
            let started = Date()
            let err = await connectOutcome(t)
            guard case SSHAuthenticationError.wrongSecret(let msg)? = err else {
                Issue.record("wrongSecret attendu, obtenu : \(String(describing: err))"); await t.disconnect(); return
            }
            #expect(msg.contains("Permission denied"))
            #expect(Date().timeIntervalSince(started) < 10)
            #expect(await responder.requests.count == 3, "ssh abandonne après 3 invites")   // NumberOfPasswordPrompts
            #expect(await responder.failed == 1)
            #expect(await responder.succeeded == 0)
            #expect(await t.isAlive() == false)
            await t.disconnect()
        }
    }

    @Test func annulationDeLaPhraseDonneCancelled() async throws {
        try await LocalSSHD.with { d in
            let responder = ScriptedResponder { _ in .cancel }
            let t = askpassTransport(d, responder: responder)
            let err = await connectOutcome(t)
            #expect(err as? SSHAuthenticationError == .cancelled, "obtenu : \(String(describing: err))")
            #expect(await responder.failed == 1)
            #expect(await t.askpassSocketPath == nil, "le serveur est arrêté après l'échec")
            await t.disconnect()
        }
    }

    @Test func delaiDepasseDonneTimedOut() async throws {
        try await LocalSSHD.with { d in
            let responder = ScriptedResponder(delay: .seconds(10)) { _ in .secret(Secret(LocalSSHD.passphrase), remember: false) }
            let t = askpassTransport(d, responder: responder, limits: .init(responseTimeout: 0.5))
            let started = Date()
            let err = await connectOutcome(t)
            #expect(err as? SSHAuthenticationError == .timedOut, "obtenu : \(String(describing: err))")
            #expect(Date().timeIntervalSince(started) < 10)
            await t.disconnect()
        }
    }

    // MARK: Clé d'hôte

    @Test func cleDHoteInconnueAccepteeEcritDansLeKnownHostsDeTest() async throws {
        try await LocalSSHD.with { d in
            let known = try d.makeKnownHosts(named: "known_vide")
            let responder = ScriptedResponder(passphraseScript())
            let t = askpassTransport(d, ssh: opts(d, knownHosts: known, strict: .ask), responder: responder)
            do {
                #expect(await connectOutcome(t) == nil)
                let reqs = await responder.requests
                let hk = try #require(reqs.first)
                guard case .hostKeyConfirmation(let type, let fp, let host) = hk.kind else {
                    Issue.record("confirmation de clé d'hôte attendue : \(hk.kind)"); return
                }
                #expect(type == "ED25519")
                let expectedFP = try fingerprint(of: "\(d.directory)/hostkey.pub")
                #expect(fp == expectedFP, "empreinte extraite ≠ ssh-keygen -l")
                #expect(host?.contains("127.0.0.1") == true)
                #expect(hk.text.hasPrefix("The authenticity of host '[127.0.0.1]:\(d.port)"))
                #expect(reqs.dropFirst().first?.kind == .passphrase(keyPath: d.passphraseKey))
                let written = try String(contentsOfFile: known, encoding: .utf8)
                let keyBody = String(try d.hostPublicKeyFields().split(separator: " ")[1])
                #expect(written.contains("[127.0.0.1]:\(d.port)") && written.contains(keyBody))
                await t.disconnect()
            } catch { await t.disconnect(); throw error }
        }
    }

    @Test func cleDHoteInconnueRefuseeEchoueProprement() async throws {
        try await LocalSSHD.with { d in
            let known = try d.makeKnownHosts(named: "known_vide")
            let responder = ScriptedResponder { r in
                if case .hostKeyConfirmation = r.kind { return .cancel }
                return .secret(Secret(LocalSSHD.passphrase), remember: false)
            }
            let t = askpassTransport(d, ssh: opts(d, knownHosts: known, strict: .ask), responder: responder)
            let err = await connectOutcome(t)
            #expect(err as? SSHAuthenticationError == .hostKeyRejected, "obtenu : \(String(describing: err))")
            let writtenAfterRefusal = try String(contentsOfFile: known, encoding: .utf8)
            #expect(writtenAfterRefusal.isEmpty, "rien ne doit être écrit")
            #expect(await responder.requests.count == 1, "aucune phrase de passe n'est demandée à un hôte refusé")
            #expect(d.acceptedAuthenticationCount() == 0)
            #expect(await responder.failed == 1)
            await t.disconnect()
        }
    }

    @Test(arguments: [OpenSSHOptions.StrictHostKeyChecking.ask, .yes])
    func cleDHoteModifieeRefuseeAvecErreurDediee(strict: OpenSSHOptions.StrictHostKeyChecking) async throws {
        try await LocalSSHD.with { d in
            let known = try d.makeKnownHosts(named: "known_autre_cle", withChangedHostKey: true)
            let before = try String(contentsOfFile: known, encoding: .utf8)
            let responder = ScriptedResponder { _ in .accept }   // même un « oui » universel ne doit rien changer
            let t = askpassTransport(d, ssh: opts(d, knownHosts: known, strict: strict), responder: responder)
            let err = await connectOutcome(t)
            guard case SSHAuthenticationError.hostKeyChanged(let msg)? = err else {
                Issue.record("hostKeyChanged attendu, obtenu : \(String(describing: err))"); await t.disconnect(); return
            }
            #expect(msg.lowercased().contains("changed"))
            #expect(await responder.requests.isEmpty, "une clé modifiée n'est jamais soumise à l'utilisateur")
            let after = try String(contentsOfFile: known, encoding: .utf8)
            #expect(after == before)
            #expect(d.acceptedAuthenticationCount() == 0)
            #expect(await responder.failed == 1)
            await t.disconnect()
        }
    }

    // MARK: Mot de passe (invite réelle ; sshd sans PAM ne peut pas le valider)

    @Test func motDePasseDuStoreEnvoyeUneSeuleFoisPuisDelegue() async throws {
        try await LocalSSHD.with(.init(passwordAuthentication: true)) { d in
            let store = InMemorySecretStore(["acc": Secret("pas-le-bon")])
            let ui = ScriptedResponder { _ in .secret(Secret("autre-mauvais"), remember: false) }
            let responder = StoredSecretResponder(auth: .keychainPassword(account: "acc"), store: store) { await ui.respond(to: $0) }
            let profile = d.profile(auth: .keychainPassword(account: "acc"))
            let t = askpassTransport(d, profile: profile, ssh: d.sshOptions(extra: ["PubkeyAuthentication=no"]), responder: responder)
            let err = await connectOutcome(t)
            guard case SSHAuthenticationError.wrongSecret? = err else {
                Issue.record("wrongSecret attendu, obtenu : \(String(describing: err))"); await t.disconnect(); return
            }
            // 1re invite → store (UI non appelée) ; invites suivantes → UI, jamais « pas-le-bon » en boucle.
            let uiReqs = await ui.requests
            #expect(!uiReqs.isEmpty && uiReqs.allSatisfy { $0.attempt >= 2 }, "requêtes UI : \(uiReqs.map(\.attempt))")
            #expect(uiReqs.count <= 2)
            #expect(uiReqs.allSatisfy { if case .password(let u) = $0.kind { return u == "\(d.user)@127.0.0.1" } else { return false } })
            #expect(uiReqs.first?.text == "\(d.user)@127.0.0.1's password: ")
            #expect(d.log().components(separatedBy: "Failed password").count - 1 >= 2, "sshd a bien reçu les mots de passe")
            let kept = try await store.secret(for: "acc")
            #expect(kept == Secret("pas-le-bon"), "un secret refusé n'est pas écrasé sans succès")
            await t.disconnect()
        }
    }

    @Test func motDePasseAnnuleDansLUIDonneCancelled() async throws {
        try await LocalSSHD.with(.init(passwordAuthentication: true)) { d in
            let store = InMemorySecretStore(["acc": Secret("pas-le-bon")])
            let ui = ScriptedResponder { _ in .cancel }
            let responder = StoredSecretResponder(auth: .keychainPassword(account: "acc"), store: store) { await ui.respond(to: $0) }
            let t = askpassTransport(d, profile: d.profile(auth: .keychainPassword(account: "acc")),
                                     ssh: d.sshOptions(extra: ["PubkeyAuthentication=no"]), responder: responder)
            let err = await connectOutcome(t)
            #expect(err as? SSHAuthenticationError == .cancelled, "obtenu : \(String(describing: err))")
            await t.disconnect()
        }
    }

    // MARK: Compatibilité

    @Test func sansAskpassLeComportementBatchModeResteInchange() async throws {
        try await LocalSSHD.with { d in
            let t = OpenSSHTransport(
                profile: d.profile(auth: .keyFile(path: d.passphraseKey)),
                configuration: .init(ssh: d.sshOptions(), masterReadyTimeout: 10))
            let started = Date()
            do { try await t.connect(); Issue.record("la clé à phrase de passe ne peut pas se connecter en BatchMode") }
            catch SSHTransportError.masterFailed(let m) { #expect(m.contains("Permission denied"), "message : \(m)") }
            catch { Issue.record("masterFailed attendu : \(error)") }
            #expect(Date().timeIntervalSince(started) < 5)
            #expect(await t.askpassSocketPath == nil)
            await t.disconnect()
        }
    }

    @Test func reconnexionUtiliseUnNouveauServeurEtUnNouveauJeton() async throws {
        try await LocalSSHD.with { d in
            let t = askpassTransport(d, responder: ScriptedResponder(passphraseScript()))
            do {
                try await t.connect()
                let first = try #require(await t.askpassSocketPath)
                await t.disconnect()
                #expect(!FileManager.default.fileExists(atPath: first))
                try await t.connect()
                let second = try #require(await t.askpassSocketPath)
                #expect(first != second)
                #expect(d.acceptedAuthenticationCount() == 2)
                await t.disconnect()
            } catch { await t.disconnect(); throw error }
            #expect(askpassPgrep("escale-askpass").isEmpty)
        }
    }
}
