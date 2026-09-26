import Foundation
import CryptoKit

struct SetupTicket: Sendable {
    let intentID: String
    let phonePublicKey: String
    let expiresAt: Double

    static func verify(_ ticket: String, publicKey: String, service: String, now: Date = .now) throws -> Self {
        let parts = ticket.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard ticket.utf8.count <= 2048, parts.count == 3, parts[0] == "HJ1" else { throw CompanionCryptoError.invalidHandshake }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: SetupCrypto.decode(publicKey, count: 32))
        guard try key.isValidSignature(SetupCrypto.decode(parts[2], count: 64), for: Data(("HJ1." + parts[1]).utf8)),
              let fields = try JSONSerialization.jsonObject(with: SetupCrypto.decode(parts[1])) as? [Any], fields.count == 6,
              let version = fields[0] as? Int, version == 1, let id = fields[1] as? String,
              let phone = fields[2] as? String, let issued = fields[3] as? Double, let expires = fields[4] as? Double,
              let origin = fields[5] as? String, origin == service,
              issued.isFinite, issued.rounded() == issued, expires.isFinite, expires.rounded() == expires,
              issued <= now.timeIntervalSince1970 + 30, expires > now.timeIntervalSince1970, expires <= issued + 1200 else {
            throw CompanionCryptoError.invalidHandshake
        }
        _ = try SetupCrypto.decode(id, count: 32)
        _ = try SetupCrypto.decode(phone, count: 32)
        return Self(intentID: id, phonePublicKey: phone, expiresAt: expires)
    }
}

struct SetupClaim: Codable, Equatable, Identifiable {
    let claim_id: String
    let installation_id: String
    let host_public_key: String
    let host_name: String
    let commitment: String
    var phone_ephemeral: String?
    var host_ephemeral: String?
    var deadline: Double?
    var confirmation: String?
    var envelope: String?
    var id: String { claim_id }

    func matchesIdentity(_ other: Self) -> Bool {
        claim_id == other.claim_id && installation_id == other.installation_id && host_public_key == other.host_public_key
            && host_name == other.host_name && commitment == other.commitment
    }
    func validate() throws {
        guard UUID(uuidString: claim_id)?.uuidString.lowercased() == claim_id,
              UUID(uuidString: installation_id)?.uuidString.lowercased() == installation_id,
              (1...80).contains(host_name.utf8.count), host_name.utf8.allSatisfy({ (32...126).contains($0) }) else {
            throw CompanionCryptoError.invalidHandshake
        }
        _ = try SetupCrypto.decode(host_public_key, count: 32)
        _ = try SetupCrypto.decode(commitment, count: 32)
    }
    func context(ticket: String) throws -> Data {
        try SetupCrypto.context(ticket: ticket, claimID: id, installationID: installation_id, hostKey: host_public_key, hostName: host_name)
    }
}

struct SetupComparison: Identifiable {
    let id: String
    let name: String
    let code: String
}

