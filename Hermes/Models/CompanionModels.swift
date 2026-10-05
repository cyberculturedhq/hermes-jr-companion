import Foundation
import CryptoKit

/// Public identity is separate from secrets so UserDefaults never contains a pairing token.
struct CompanionConnection: Codable, Equatable, Sendable {
    var relayURL: String
    var installationID: String
    var deviceID: String
    var hostPublicKey: String
    var keychainAccount: String {
        var origin = URLComponents(string: relayURL)
        let scheme = origin?.scheme?.lowercased()
        let host = origin?.host?.lowercased()
        origin?.scheme = scheme
        origin?.host = host
        if (origin?.scheme == "https" && origin?.port == 443) || (origin?.scheme == "http" && origin?.port == 80) {
            origin?.port = nil
        }
        origin?.path = ""
        let normalizedKey = Data(companionBase64: hostPublicKey)?.companionBase64 ?? hostPublicKey
        let identity = [origin?.string ?? relayURL, installationID.lowercased(), deviceID.lowercased(), normalizedKey]
            .joined(separator: "\0")
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "companion/" + digest
    }
}

struct CompanionCredentials: Codable {
    var deviceToken: String
    var privateKey: Data
    var pairingSecret: String?
}

struct CompanionInvitation: Decodable {
    let v: Int
    let relay_url: String
    let installation_id: String
    let device_id: String
    let device_token: String
    let host_public_key: String
    let pairing_secret: String
    let expires_at: Double

    static func parse(_ text: String, now: Date = .now) throws -> CompanionInvitation {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 8192 else { throw HermesError.message("The connection details are too large.") }
        let data = Data(trimmed.utf8)
        guard let invite = try? JSONDecoder().decode(Self.self, from: data), invite.v == 1,
              UUID(uuidString: invite.installation_id) != nil, UUID(uuidString: invite.device_id) != nil,
              let key = Data(companionBase64: invite.host_public_key), key.count == 32,
              let secret = Data(companionBase64: invite.pairing_secret), secret.count == 32,
              let token = Data(companionBase64: invite.device_token), token.count == 32,
              token.companionBase64 == invite.device_token,
              invite.expires_at.isFinite, invite.expires_at > now.timeIntervalSince1970,
              invite.expires_at <= now.addingTimeInterval(3600).timeIntervalSince1970 else {
            throw HermesError.message("These connection details are invalid or expired. Start a new setup in Jr.")
        }
        _ = try Self.validatedRelayURL(invite.relay_url)
        return invite
    }

    static func validatedRelayURL(_ address: String) throws -> URL {
        guard let parts = URLComponents(string: address), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", let url = parts.url else {
            throw HermesError.message("The connection details contain an invalid service address.")
        }
        guard parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)) else {
            throw HermesError.message("The relay must use HTTPS. Local development also supports loopback HTTP.")
        }
        return url
    }

    var connection: CompanionConnection {
        CompanionConnection(relayURL: relay_url, installationID: installation_id,
                            deviceID: device_id, hostPublicKey: host_public_key)
    }
}

struct CompanionEnrollment: Codable, Sendable {
    var deviceID: String
    var deviceToken: String
    var installationID: String
}

struct FollowedConversation: Codable, Hashable, Sendable {
    var profile: String
    var sessionID: String
}

extension Data {
    init?(companionBase64 value: String) {
        guard value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 95, 43, 47, 61].contains($0) }) else { return nil }
        let base = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    }
    var companionBase64: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

struct CompanionUpdateNotice: Equatable, Identifiable {
    let version: String
    var id: String { version }

    init?(capabilities: [String: Any]) {
        guard let update = capabilities["update"] as? [String: Any],
              update["available"] as? Bool == true,
              let latest = update["version"] as? String,
              let installed = update["installed"] as? String,
              let target = Self.components(latest), let current = Self.components(installed),
              current.lexicographicallyPrecedes(target) else { return nil }
        version = latest
    }

    init?(installed: String, latest: String) {
        guard let current = Self.components(installed), let target = Self.components(latest),
              current.lexicographicallyPrecedes(target) else { return nil }
        version = latest
    }

    static func components(_ value: String) -> [Int]? {
        guard value.count <= 32,
              value.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil else { return nil }
        let parts = value.split(separator: ".").compactMap { Int($0) }
        return parts.count == 3 ? parts : nil
    }

    var releaseURL: URL {
        URL(string: "https://github.com/cyberculturedhq/hermes-jr-companion/releases/tag/v" + version)!
    }

    var installPrompt: String {
        "Update my Hermes Jr. companion to version \(version) from https://github.com/cyberculturedhq/hermes-jr-companion. Follow UPDATES.md and use the companion's update command with rollback protection. Wait until my active work finishes, preserve my profiles and pairings, and verify the service afterward."
    }
}
