import Foundation
import Security

struct GoogleDriveSession: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var userEmail: String?
}

private struct GoogleDriveVault: Codable, Equatable, Sendable {
    var session: GoogleDriveSession?
    var clientSecret: String?
}

enum KeychainStore {
    private static let service = "com.taninahmed.snapfeather.googledrive"
    private static let vaultAccount = "oauth_vault"
    private static let legacySessionAccount = "oauth_session"
    private static let legacyClientSecretAccount = "oauth_client_secret"

    private static let lock = NSLock()
    private static nonisolated(unsafe) var hasLoadedVault = false
    private static nonisolated(unsafe) var cachedVault = GoogleDriveVault()

    static func saveSession(_ session: GoogleDriveSession) throws {
        var vault = loadVault()
        if vault.session == session {
            return
        }
        vault.session = session
        try saveVault(vault)
    }

    static func loadSession() -> GoogleDriveSession? {
        loadVault().session
    }

    static func deleteSession() {
        var vault = loadVault()
        guard vault.session != nil else { return }
        vault.session = nil
        if (vault.clientSecret ?? "").isEmpty {
            deleteItem(account: vaultAccount)
            lock.lock()
            cachedVault = GoogleDriveVault()
            hasLoadedVault = true
            lock.unlock()
        } else {
            try? saveVault(vault)
        }
    }

    static func saveClientSecret(_ secret: String) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: String? = trimmed.isEmpty ? nil : trimmed
        var vault = loadVault()
        if vault.clientSecret == normalized {
            return
        }
        vault.clientSecret = normalized
        if vault.session == nil && vault.clientSecret == nil {
            deleteItem(account: vaultAccount)
            lock.lock()
            cachedVault = GoogleDriveVault()
            hasLoadedVault = true
            lock.unlock()
        } else {
            try saveVault(vault)
        }
    }

    static func loadClientSecret() -> String {
        loadVault().clientSecret ?? ""
    }

    private static func loadVault() -> GoogleDriveVault {
        lock.lock()
        if hasLoadedVault {
            let current = cachedVault
            lock.unlock()
            return current
        }
        lock.unlock()

        var loaded = GoogleDriveVault()
        if let data = loadData(account: vaultAccount),
           let decoded = try? JSONDecoder().decode(GoogleDriveVault.self, from: data) {
            loaded = decoded
        } else {
            // Migrate any legacy split items into a single vault item once
            var migrated = false
            if let legacySessionData = loadData(account: legacySessionAccount),
               let legacySession = try? JSONDecoder().decode(GoogleDriveSession.self, from: legacySessionData) {
                loaded.session = legacySession
                migrated = true
            }
            if let legacySecretData = loadData(account: legacyClientSecretAccount),
               let legacySecret = String(data: legacySecretData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !legacySecret.isEmpty {
                loaded.clientSecret = legacySecret
                migrated = true
            }
            if migrated {
                try? writeVaultToKeychain(loaded)
                deleteItem(account: legacySessionAccount)
                deleteItem(account: legacyClientSecretAccount)
            }
        }

        lock.lock()
        cachedVault = loaded
        hasLoadedVault = true
        lock.unlock()
        return loaded
    }

    private static func saveVault(_ vault: GoogleDriveVault) throws {
        try writeVaultToKeychain(vault)
        lock.lock()
        cachedVault = vault
        hasLoadedVault = true
        lock.unlock()
    }

    private static func writeVaultToKeychain(_ vault: GoogleDriveVault) throws {
        let data = try JSONEncoder().encode(vault)
        try saveData(data, account: vaultAccount)
    }

    private static func saveData(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(
                    domain: NSOSStatusErrorDomain,
                    code: Int(addStatus),
                    userInfo: [NSLocalizedDescriptionKey: "Failed to save credentials to Keychain (OSStatus \(addStatus))."]
                )
            }
        } else if status != errSecSuccess {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Failed to update credentials in Keychain (OSStatus \(status))."]
            )
        }
    }

    private static func loadData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return data
    }

    private static func deleteItem(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
