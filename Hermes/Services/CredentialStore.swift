import Foundation
import Security

struct SavedCredentials: Codable {
    var password: String
    var token: String
}

enum CredentialReadError: LocalizedError {
    case accessFailed(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .accessFailed(let status): "Couldn't access the saved connection in Keychain (\(status))."
        case .invalidData: "The saved sign-in details could not be decoded."
        }
    }
}

enum CredentialStore {
    private static let service = "app.hermes.ios.connection"

    static func save(_ credentials: SavedCredentials, account: String) throws {
        try saveValue(credentials, account: account)
    }

    static func saveValue<T: Encodable>(_ value: T, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let query = baseQuery(account)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(item as CFDictionary, nil)
            guard result == errSecSuccess else { throw failure(result) }
        } else if update != errSecSuccess {
            throw failure(update)
        }
    }

    static func read(account: String) throws -> SavedCredentials? {
        try readValue(SavedCredentials.self, account: account)
    }

    static func readValue<T: Decodable>(_ type: T.Type, account: String) throws -> T? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if status == errSecDecode { throw CredentialReadError.invalidData }
        guard status == errSecSuccess else { throw CredentialReadError.accessFailed(status) }
        guard let data = result as? Data else { throw CredentialReadError.invalidData }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw CredentialReadError.invalidData }
    }

    static func delete(account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func failure(_ status: OSStatus) -> HermesError {
        .message("Couldn't access the saved connection in Keychain (\(status)).")
    }
}
