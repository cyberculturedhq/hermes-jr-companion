import Foundation
import CryptoKit
import DeviceCheck

@MainActor
protocol AppVerifying {
    func proof(service: String, phoneKey: String, network: any SetupNetworking) async throws -> Data
    func didIssueTicket(service: String) throws
}
extension AppVerifying { func didIssueTicket(service: String) throws {} }

@MainActor
final class AppAttestClient: AppVerifying {
    private struct SavedKey: Codable { let id: String; var attested: Bool }
    private struct PendingProof: Codable { let phoneKey: String; let created: Double; let body: Data }
    private struct PendingChallenge: Codable { let keyID: String; let phoneKey: String; let created: Double; let challenge: String }
    private let attest = DCAppAttestService.shared

    func proof(service: String, phoneKey: String, network: any SetupNetworking) async throws -> Data {
        guard attest.isSupported else {
            throw HermesError.message("This device cannot verify the official app for new setup. Use a supported iPhone or iPad. Existing connections remain available.")
        }
        let account = "app-attest/" + service
        if let pending = try CredentialStore.readValue(PendingProof.self, account: account + "/pending"),
           pending.phoneKey == phoneKey, Date.now.timeIntervalSince1970 - pending.created < 240 {
            return pending.body
        }
        var key = try CredentialStore.readValue(SavedKey.self, account: account)
        if key == nil {
            key = SavedKey(id: try await attest.generateKey(), attested: false)
            try CredentialStore.saveValue(key!, account: account)
        }
        var saved = key!
        struct Challenge: Decodable { let challenge: String; let attested: Bool }
        func challenge(_ id: String) async throws -> Challenge {
            let bytes = try await network.request(service: service, path: "/v1/app-attest/challenges", method: "POST",
                body: JSONEncoder().encode(["key_id": id, "phone_public_key": phoneKey]), token: nil, ticket: nil)
            return try JSONDecoder().decode(Challenge.self, from: bytes)
        }
        guard let rawID = Data(base64Encoded: saved.id), rawID.count == 32 else { throw CompanionCryptoError.invalidHandshake }
        var keyID = rawID.companionBase64
        let cached = try CredentialStore.readValue(PendingChallenge.self, account: account + "/challenge")
        var request: Challenge
        if !saved.attested, let cached, cached.keyID == keyID, cached.phoneKey == phoneKey,
           Date.now.timeIntervalSince1970 - cached.created < 900 {
            request = Challenge(challenge: cached.challenge, attested: false)
        } else { request = try await challenge(keyID) }
        if saved.attested && !request.attested {
            // The server can remove unused verification state. Never reuse a lost association.
            saved = SavedKey(id: try await attest.generateKey(), attested: false)
            try CredentialStore.saveValue(saved, account: account)
            guard let fresh = Data(base64Encoded: saved.id), fresh.count == 32 else { throw CompanionCryptoError.invalidHandshake }
            keyID = fresh.companionBase64
            request = try await challenge(keyID)
        }
        _ = try SetupCrypto.decode(request.challenge, count: 32)
        let data = Data("hermes-jr/admission/v1\n\(service)\n\(request.challenge)\n\(keyID)\n\(phoneKey)\n".utf8)
        let digest = Data(SHA256.hash(data: data))
        let proof: Data
        if request.attested {
            proof = try await attest.generateAssertion(saved.id, clientDataHash: digest)
        } else {
            try CredentialStore.saveValue(PendingChallenge(keyID: keyID, phoneKey: phoneKey,
                created: cached?.challenge == request.challenge ? cached!.created : Date.now.timeIntervalSince1970, challenge: request.challenge), account: account + "/challenge")
            proof = try await attest.attestKey(saved.id, clientDataHash: digest)
            // Keep the same key if Apple or the relay is temporarily unavailable.
            saved.attested = true
            try CredentialStore.saveValue(saved, account: account)
        }
        let body = try JSONSerialization.data(withJSONObject: ["phone_public_key": phoneKey, "key_id": keyID,
            "challenge": request.challenge, "proof": proof.companionBase64, "assertion": request.attested])
        try CredentialStore.saveValue(PendingProof(phoneKey: phoneKey, created: Date.now.timeIntervalSince1970, body: body), account: account + "/pending")
        return body
    }

    func didIssueTicket(service: String) throws {
        CredentialStore.delete(account: "app-attest/" + service + "/pending")
        CredentialStore.delete(account: "app-attest/" + service + "/challenge")
    }
}
