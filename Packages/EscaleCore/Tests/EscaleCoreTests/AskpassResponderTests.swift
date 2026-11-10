import Foundation
import Testing
@testable import EscaleCore

/// Double de l'UI : répond selon un script et compte ses appels.
private actor UI {
    private(set) var requests: [AskpassRequest] = []
    private var replies: [AskpassDecision]
    init(_ replies: [AskpassDecision]) { self.replies = replies }
    func answer(_ r: AskpassRequest) -> AskpassDecision {
        requests.append(r)
        return replies.isEmpty ? .cancel : replies.removeFirst()
    }
}

private func pwd(_ attempt: Int = 1) -> AskpassRequest {
    AskpassRequest(kind: .password(userAtHost: "u@h"), text: "u@h's password: ", attempt: attempt)
}

@Suite("Askpass : StoredSecretResponder")
struct AskpassResponderTests {
    private func make(_ auth: HostProfile.Auth, store: InMemorySecretStore, ui: UI) -> StoredSecretResponder {
        StoredSecretResponder(auth: auth, store: store) { await ui.answer($0) }
    }

    @Test func motDePasseDuStoreSansPasserParLUI() async {
        let store = InMemorySecretStore(["acc": Secret("stocké")])
        let ui = UI([])
        let r = make(.keychainPassword(account: "acc"), store: store, ui: ui)
        #expect(await r.respond(to: pwd()) == .secret(Secret("stocké"), remember: false))
        #expect(await ui.requests.isEmpty)
    }

    @Test func secretRefuseNEstJamaisReproposeEnBoucle() async {
        let store = InMemorySecretStore(["acc": Secret("périmé")])
        let ui = UI([.secret(Secret("nouveau"), remember: false), .cancel])
        let r = make(.keychainPassword(account: "acc"), store: store, ui: ui)
        #expect(await r.respond(to: pwd(1)) == .secret(Secret("périmé"), remember: false))
        // ssh repose la même invite : on délègue à l'UI (attempt 2), on ne renvoie pas « périmé ».
        #expect(await r.respond(to: pwd(2)) == .secret(Secret("nouveau"), remember: false))
        #expect(await r.respond(to: pwd(3)) == .cancel)
        #expect(await ui.requests.map(\.attempt) == [2, 3])
    }

    @Test func secretAbsentDelegueALUI() async {
        let ui = UI([.secret(Secret("saisi"), remember: false)])
        let r = make(.keychainPassword(account: "vide"), store: InMemorySecretStore(), ui: ui)
        #expect(await r.respond(to: pwd()) == .secret(Secret("saisi"), remember: false))
        #expect(await ui.requests.count == 1)
    }

    @Test func autreAuthQueKeychainDelegueToutALUI() async {
        let store = InMemorySecretStore(["acc": Secret("stocké")])
        for auth in [HostProfile.Auth.openSSHDefaults, .keyFile(path: "/k")] {
            let ui = UI([.cancel])
            let r = make(auth, store: store, ui: ui)
            #expect(await r.respond(to: pwd()) == .cancel)
            #expect(await ui.requests.count == 1)
        }
    }

    @Test func toutLeResteEstDelegue() async {
        let store = InMemorySecretStore(["acc": Secret("stocké")])
        let ui = UI([.secret(Secret("pp"), remember: false), .secret(Secret("123456"), remember: false), .accept])
        let r = make(.keychainPassword(account: "acc"), store: store, ui: ui)
        let kinds: [AskpassPromptKind] = [
            .passphrase(keyPath: "/k"), .verificationCode(label: "Verification code:"),
            .hostKeyConfirmation(keyType: "ED25519", fingerprint: "SHA256:x", host: "h"),
        ]
        for k in kinds { _ = await r.respond(to: AskpassRequest(kind: k, text: "t", attempt: 1)) }
        #expect(await ui.requests.map(\.kind) == kinds)
    }

    @Test func memorisationSeulementApresSucces() async throws {
        let store = InMemorySecretStore()
        let ui = UI([.secret(Secret("à-retenir"), remember: true)])
        let r = make(.keychainPassword(account: "acc"), store: store, ui: ui)
        _ = await r.respond(to: pwd())
        #expect(try await store.secret(for: "acc") == nil, "rien d'écrit avant la connexion réussie")
        await r.authenticationSucceeded()
        #expect(try await store.secret(for: "acc") == Secret("à-retenir"))
    }

    @Test func memorisationOublieeSiEchec() async throws {
        let store = InMemorySecretStore()
        let r = make(.keychainPassword(account: "acc"), store: store, ui: UI([.secret(Secret("faux"), remember: true)]))
        _ = await r.respond(to: pwd())
        await r.authenticationFailed()
        await r.authenticationSucceeded()   // une connexion ultérieure ne doit pas écrire l'ancien secret
        #expect(try await store.secret(for: "acc") == nil)
    }

    @Test func pasDeMemorisationSansDemandeOuPourUnePhraseDePasse() async throws {
        let store = InMemorySecretStore()
        let ui = UI([.secret(Secret("a"), remember: false), .secret(Secret("b"), remember: true)])
        let r = make(.keychainPassword(account: "acc"), store: store, ui: ui)
        _ = await r.respond(to: pwd())
        _ = await r.respond(to: AskpassRequest(kind: .passphrase(keyPath: "/k"), text: "t"))
        await r.authenticationSucceeded()
        #expect(await store.accounts.isEmpty)
    }

    @Test func memorisationRemplaceUnSecretPerime() async throws {
        let store = InMemorySecretStore(["acc": Secret("périmé")])
        let ui = UI([.secret(Secret("neuf"), remember: true)])
        let r = make(.keychainPassword(account: "acc"), store: store, ui: ui)
        _ = await r.respond(to: pwd(1))                       // renvoie « périmé » (refusé par le serveur)
        _ = await r.respond(to: pwd(2))                       // UI : « neuf », à mémoriser
        await r.authenticationSucceeded()
        #expect(try await store.secret(for: "acc") == Secret("neuf"))
    }

    @Test func erreurDuStoreRetombeSurLUI() async {
        struct Broken: SecretStore {
            func secret(for account: String) async throws -> Secret? { throw SecretStoreError.keychain(status: -25308) }
            func setSecret(_ secret: Secret, for account: String) async throws { throw SecretStoreError.keychain(status: -25308) }
            func removeSecret(for account: String) async throws {}
        }
        let ui = UI([.secret(Secret("saisi"), remember: true)])
        let r = StoredSecretResponder(auth: .keychainPassword(account: "acc"), store: Broken()) { await ui.answer($0) }
        #expect(await r.respond(to: pwd()) == .secret(Secret("saisi"), remember: true))
        await r.authenticationSucceeded()   // l'échec d'écriture ne plante pas
    }
}
