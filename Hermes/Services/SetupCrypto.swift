import Foundation
import CryptoKit

/// Hermes framing around the ZRTP/Matrix SAS commitment pattern. See Protocol/SETUP.md.
enum SetupCrypto {
    static let domain = Data("hermes-jr/setup-sas/v1\0".utf8)

    static func decode(_ value: String, count: Int? = nil) throws -> Data {
        guard value.utf8.count <= 8192, let data = Data(companionBase64: value),
              data.companionBase64 == value, count == nil || data.count == count else {
            throw CompanionCryptoError.invalidHandshake
        }
        return data
    }

    static func context(ticket: String, claimID: String, installationID: String, hostKey: String, hostName: String) throws -> Data {
        let fields = [ticket, claimID, installationID, hostKey, hostName]
        guard fields.allSatisfy({ !$0.contains("\0") }) else { throw CompanionCryptoError.invalidHandshake }
        return domain + Data(fields.joined(separator: "\0").utf8)
    }

    static func commitment(context: Data, hostEphemeral: Data) -> Data {
        Data(SHA256.hash(data: domain + Data("commit\0".utf8) + context + hostEphemeral))
    }

    static func transcript(context: Data, hostEphemeral: Data, phoneEphemeral: Data) -> Data {
        Data(SHA256.hash(data: context + hostEphemeral + phoneEphemeral))
    }

    static func derive(privateKey: Data, peer: Data, transcript: Data, label: String, count: Int = 32) throws -> SymmetricKey {
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        let shared = try key.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer))
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(),
            sharedInfo: domain + Data((label + "\0").utf8) + transcript, outputByteCount: count)
    }

    static func comparisonCode(privateKey: Data, peer: Data, transcript: Data) throws -> String {
        let key = try derive(privateKey: privateKey, peer: peer, transcript: transcript, label: "sas", count: 5)
        let b: [Int] = key.withUnsafeBytes { bytes in bytes.map { Int($0) } }
        let first = (b[0] << 5) | (b[1] >> 3)
        let second = ((b[1] & 7) << 10) | (b[2] << 2) | (b[3] >> 6)
        let third = ((b[3] & 63) << 7) | (b[4] >> 1)
        let values = [first, second, third]
        return values.map { String($0 + 1000) }.joined(separator: " ")
    }

    static func confirmation(privateKey: Data, peer: Data, transcript: Data) throws -> String {
        let key = try derive(privateKey: privateKey, peer: peer, transcript: transcript, label: "confirm")
        return Data(HMAC<SHA256>.authenticationCode(for: domain + Data("phone-confirm\0".utf8) + transcript, using: key)).companionBase64
    }

    static func decryptEnrollment(_ envelope: String, phonePrivate: Data, hostPublic: Data, transcript: Data) throws -> Data {
        let data = try decode(envelope)
        guard data.count >= 48, data.count <= 3072 else { throw CompanionCryptoError.invalidHandshake }
        var recipient = try HPKE.Recipient(privateKey: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: phonePrivate),
            ciphersuite: .Curve25519_SHA256_ChachaPoly, info: domain + Data("enrollment\0".utf8) + transcript,
            encapsulatedKey: data.prefix(32), authenticatedBy: Curve25519.KeyAgreement.PublicKey(rawRepresentation: hostPublic))
        return try recipient.open(data.dropFirst(32), authenticating: transcript)
    }
}
