import Foundation
import Security

struct GoogleDriveSession: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var userEmail: String?
}

enum KeychainStore {
    private static let service = "com.taninahmed.snapfeather.googledrive"
    private static let sessionAccount = "oauth_session"
    private static let clientSecretAccount = "oauth_client_secret"

    static func saveSession(_ session: GoogleDriveSession) throws {
        let data = try JSONEncoder().encode(session)
        try saveData(data, account: sessionAccount)
    }

    static func loadSession() -> GoogleDriveSession? {
        guard let data = loadData(account: sessionAccount) else { return nil }
        return try? JSONDecoder().decode(GoogleDriveSession.self, from: data)
    }

    static func deleteSession() {
        deleteItem(account: sessionAccount)
    }

    static func saveClientSecret(_ secret: String) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            deleteItem(account: clientSecretAccount)
            return
        }
        try saveData(Data(trimmed.utf8), account: clientSecretAccount)
    }

    static func loadClientSecret() -> String {
        guard let data = loadData(account: clientSecretAccount),
              let secret = String(data: data, encoding: .utf8) else {
            return ""
        }
        return secret
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
