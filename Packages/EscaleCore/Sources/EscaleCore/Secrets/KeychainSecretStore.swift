import Foundation
import Security

/// Mots de passe génériques du Keychain. `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, jamais synchronisé iCloud,
/// et aucune fenêtre d'autorisation : si le Keychain exigerait une interaction, l'opération échoue (OSStatus -25308).
public struct KeychainSecretStore: SecretStore {
    public let service: String
    /// `true` : trousseau « data protection » (app signée avec ses droits Keychain). `false` : trousseau de session (défaut ;
    /// c'est le seul utilisable par un binaire non signé, comme `swift test`).
    public let useDataProtectionKeychain: Bool

    public init(service: String = "com.attila-krb.Escale", useDataProtectionKeychain: Bool = false) {
        self.service = service
        self.useDataProtectionKeychain = useDataProtectionKeychain
    }

    public func secret(for account: String) async throws -> Secret? { try read(account) }
    public func setSecret(_ secret: Secret, for account: String) async throws { try write(secret, account) }
    public func removeSecret(for account: String) async throws { try delete(account) }

    // Opérations synchrones (appels SecItem rapides, sans fenêtre) : aussi utilisées par la sonde des tests.
    func read(_ account: String) throws -> Secret? {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status: status) }
        guard let data = out as? Data else { throw SecretStoreError.invalidData }
        return Secret(data: data)
    }

    func write(_ secret: Secret, _ account: String) throws {
        var add = baseQuery(account)
        add[kSecValueData as String] = secret.data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return }
        guard status == errSecDuplicateItem else { throw SecretStoreError.keychain(status: status) }
        let update: [String: Any] = [
            kSecValueData as String: secret.data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let u = SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary)
        guard u == errSecSuccess else { throw SecretStoreError.keychain(status: u) }
    }

    func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.keychain(status: status) }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            // Jamais de fenêtre d'autorisation : on échoue plutôt que d'interroger l'utilisateur.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        if useDataProtectionKeychain { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }
}
