import Foundation
import CryptoKit
import Security

/// Shared only by the app and its notification extension. No Hermes login keys live here.
struct NotificationPreviewKey: Codable {
    let keyID: String
    let secret: Data
    var registration: [String: String] { ["key_id": keyID, "secret": NotificationPreview.encode(secret)] }
}

enum NotificationPreview {
    static let fallbackTitle = "Hermes Jr."
    static let fallbackBody = "You have a new notification. Open the app for details."
    static let service = "com.hermesjr.notification-preview.v1"
    enum Failure: Error { case invalid, keychain }

    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ value: String, size: Int) throws -> Data {
        guard value.utf8.count <= 2048,
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let data = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - value.count % 4) % 4)),
              data.count == size, encode(data) == value else { throw Failure.invalid }
        return data
    }
    private static func query(_ account: String) throws -> [String: Any] {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "NotificationKeychainGroup") as? String,
              !group.contains("$("), !group.isEmpty else { throw Failure.keychain }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account, kSecAttrAccessGroup as String: group]
    }
    private static func read(_ account: String) throws -> Data? {
        var q = try query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure.keychain }
        return data
    }
    private static func save(_ data: Data, account: String) throws {
        let q = try query(account)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = q; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Failure.keychain }
        } else if status != errSecSuccess { throw Failure.keychain }
    }
    static func key(account: String) throws -> NotificationPreviewKey {
        let pointer = "account/" + encode(Data(SHA256.hash(data: Data(account.utf8))))
        if let raw = try read(pointer), let id = String(data: raw, encoding: .utf8), let secret = try read("key/" + id) {
            _ = try decode(id, size: 16)
            guard secret.count == 32 else { throw Failure.invalid }
            return NotificationPreviewKey(keyID: id, secret: secret)
        }
        let id = encode(SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) })
        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try save(secret, account: "key/" + id)
        try save(Data(id.utf8), account: pointer)
        return NotificationPreviewKey(keyID: id, secret: secret)
    }
    static func remove(account: String) {
        let pointer = "account/" + encode(Data(SHA256.hash(data: Data(account.utf8))))
        if let raw = try? read(pointer), let id = String(data: raw, encoding: .utf8), let q = try? query("key/" + id) {
            SecItemDelete(q as CFDictionary)
        }
        if let q = try? query(pointer) { SecItemDelete(q as CFDictionary) }
    }
    static func decrypt(userInfo: [AnyHashable: Any], now: Date = .now) throws -> (title: String, body: String) {
        guard let envelope = userInfo["encrypted"] as? [String: Any], let id = envelope["kid"] as? String,
              let secret = try read("key/" + id) else { throw Failure.invalid }
        return try decrypt(userInfo: userInfo, secret: secret, now: now)
    }
    static func decrypt(userInfo: [AnyHashable: Any], secret: Data, now: Date) throws -> (title: String, body: String) {
        guard let envelope = userInfo["encrypted"] as? [String: Any], Set(envelope.keys) == ["v", "kid", "data"],
              let v = envelope["v"] as? Int, v == 1,
              let id = envelope["kid"] as? String, let encoded = envelope["data"] as? String,
              let reference = userInfo["reference"] as? String, secret.count == 32 else { throw Failure.invalid }
        _ = try decode(id, size: 16); _ = try decode(reference, size: 32)
        let combined = try decode(encoded, size: 1052)
        let aad = Data(("hermes-jr/notification/v1\0" + id + "\0" + reference).utf8)
        let raw = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: combined), using: SymmetricKey(data: secret), authenticating: aad)
        guard raw.count == 1024 else { throw Failure.invalid }
        let count = Int(raw[0]) * 256 + Int(raw[1])
        guard count > 0, count <= 1022, raw.dropFirst(count + 2).allSatisfy({ $0 == 0 }),
              let content = try JSONSerialization.jsonObject(with: raw.subdata(in: 2..<(count + 2))) as? [String: Any],
              let kind = content["kind"] as? String, let profile = content["profile"] as? String,
              let conversation = content["conversation"] as? String, let expires = content["expires"] as? Double,
              expires > now.timeIntervalSince1970, expires <= now.timeIntervalSince1970 + 3900,
              !profile.isEmpty, profile.utf8.count <= 120, conversation.utf8.count <= 240,
              (profile + conversation).unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }) else { throw Failure.invalid }
        let title = conversation.isEmpty ? "this conversation" : "“\(conversation)”"
        let body: String
        switch kind {
        case "completed": body = conversation.isEmpty ? "Your agent has replied." : "New reply in \(title)."
        case "error": body = "Something went wrong in \(title). Open for details."
        case "approval": body = conversation.isEmpty ? "Your agent needs your permission to continue." : "\(title) needs your permission to continue."
        case "clarification": body = "Your agent needs an answer in \(title) to continue."
        case "update_completed": body = "Your companion update is complete. Open Hermes Jr. for details."
        default: throw Failure.invalid
        }
        return (profile, body)
    }
}
