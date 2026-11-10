import Foundation
import Security
import Testing
@testable import EscaleCore

/// Sonde : le Keychain est-il utilisable ici sans fenêtre ni résidu ? Sinon les tests Keychain sont DÉSACTIVÉS avec la raison.
enum KeychainProbe {
    static let unavailableReason: String? = {
        let store = KeychainSecretStore(service: "com.attila-krb.Escale.tests.probe-\(UUID().uuidString)")
        let account = "probe"
        defer { try? store.delete(account) }
        do {
            try store.write(Secret("probe"), account)
            guard try store.read(account) == Secret("probe") else { return "relecture Keychain incohérente" }
            try store.delete(account)
            return nil
        } catch {
            return "Keychain inutilisable dans ce contexte (\(error)) : accès sans interaction impossible"
        }
    }()
}

@Suite("Secrets")
struct SecretsStoreTests {
    @Test func secretNeSeLitJamaisDansUneDescription() {
        let s = Secret("hunter2-très-secret")
        for text in ["\(s)", String(describing: s), String(reflecting: s), "\(Mirror(reflecting: s).children.count)"] {
            #expect(!text.contains("hunter2"))
        }
        #expect(String(describing: SecretStoreError.keychain(status: -25300)).contains("-25300"))
        #expect(s.string == "hunter2-très-secret")
    }

    @Test func inMemoryEcritLitSupprime() async throws {
        let store = InMemorySecretStore()
        #expect(try await store.secret(for: "a") == nil)
        try await store.setSecret(Secret("un"), for: "a")
        try await store.setSecret(Secret("deux"), for: "a")   // remplace
        #expect(try await store.secret(for: "a") == Secret("deux"))
        try await store.removeSecret(for: "a")
        try await store.removeSecret(for: "a")                 // idempotent
        #expect(try await store.secret(for: "a") == nil)
    }

    @Test(.enabled(if: KeychainProbe.unavailableReason == nil, Comment(rawValue: KeychainProbe.unavailableReason ?? "")))
    func keychainRoundTripSansResidu() async throws {
        let service = "com.attila-krb.Escale.tests.\(UUID().uuidString)"
        let store = KeychainSecretStore(service: service)
        let account = "user@127.0.0.1"
        do {
            #expect(try await store.secret(for: account) == nil)
            try await store.setSecret(Secret("premier"), for: account)
            #expect(try await store.secret(for: account) == Secret("premier"))
            try await store.setSecret(Secret("second"), for: account)       // mise à jour du doublon
            #expect(try await store.secret(for: account) == Secret("second"))
            // Un autre service n'y voit rien.
            let other = KeychainSecretStore(service: service + ".autre")
            #expect(try await other.secret(for: account) == nil)
            try await store.removeSecret(for: account)
            try await store.removeSecret(for: account)                       // idempotent
            #expect(try await store.secret(for: account) == nil)
        } catch {
            try? await store.removeSecret(for: account)
            throw error
        }
    }

    @Test(.enabled(if: KeychainProbe.unavailableReason == nil, Comment(rawValue: KeychainProbe.unavailableReason ?? "")))
    func keychainAttributsDeProtection() async throws {
        let service = "com.attila-krb.Escale.tests.\(UUID().uuidString)"
        let store = KeychainSecretStore(service: service)
        let account = "attrs"
        defer { try? store.delete(account) }
        try await store.setSecret(Secret("x"), for: account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        var out: CFTypeRef?
        #expect(SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess)
        let attrs = try #require(out as? [String: Any])
        // Le trousseau « fichier » (seul accessible sans signature, donc sous `swift test`) ignore kSecAttrAccessible :
        // l'attribut n'est vérifiable que s'il est restitué ; il l'est avec useDataProtectionKeychain (app signée).
        if let accessible = attrs[kSecAttrAccessible as String] as? String {
            #expect(accessible == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        }
        let sync = attrs[kSecAttrSynchronizable as String] as? Bool ?? (attrs[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue
        #expect(sync != true, "l'entrée ne doit pas être synchronisée iCloud")
    }
}
