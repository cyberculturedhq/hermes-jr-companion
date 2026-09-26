import Foundation
import CryptoKit

/// Local fixture only: compares against the code printed by the actual Python host.
@main
struct SetupSmoke {
    @MainActor
    static func main() async throws {
        let service = CommandLine.arguments[1], codeFile = CommandLine.arguments[2]
        var ticket: String?, owner: String?
        func request(_ method: String, _ path: String, _ body: [String: String]? = nil) async throws -> Data {
            var request = URLRequest(url: URL(string: service + path)!)
            request.httpMethod = method
            if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            if let ticket { request.setValue(ticket, forHTTPHeaderField: "X-Hermes-Setup") }
            if let owner { request.setValue("Bearer " + owner, forHTTPHeaderField: "Authorization") }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
            return data
        }
        let phonePrivate = CompanionCrypto.generatePrivateKey()
        let phonePublic = try CompanionCrypto.publicKey(for: phonePrivate).companionBase64
        let issuer = try JSONDecoder().decode([String: String].self, from: await request("GET", "/v1/pairing/key"))
        struct Created: Decodable { let ticket: String; let owner_token: String }
        let created = try JSONDecoder().decode(Created.self, from: await request("POST", "/v1/pairing/intents", ["phone_public_key": phonePublic]))
        let setup = try SetupTicket.verify(created.ticket, publicKey: issuer["public_key"]!, service: service)
        precondition(setup.phonePublicKey == phonePublic)
        ticket = created.ticket; owner = created.owner_token
        print("TICKET " + created.ticket)
        fflush(stdout)
        let path = "/v1/pairing/" + setup.intentID
        struct Snapshot: Decodable { let claims: [SetupClaim] }
        var claim: SetupClaim?
        for _ in 0..<100 {
            claim = try JSONDecoder().decode(Snapshot.self, from: await request("GET", path)).claims.first
            if claim != nil { break }
            try await Task.sleep(for: .milliseconds(300))
        }
        let initial = claim!
        precondition(initial.host_ephemeral == nil)
        let ephemeral = CompanionCrypto.generatePrivateKey(), ephemPublic = try CompanionCrypto.publicKey(for: ephemeral)
        _ = try await request("PUT", path + "/claims/" + initial.id + "/key", ["phone_ephemeral": ephemPublic.companionBase64])
        for _ in 0..<60 {
            claim = try JSONDecoder().decode(Snapshot.self, from: await request("GET", path)).claims.first
            if claim?.host_ephemeral != nil { break }
            try await Task.sleep(for: .seconds(1))
        }
        let revealed = claim!, hostEphemeral = try SetupCrypto.decode(revealed.host_ephemeral!, count: 32)
        precondition(initial.matchesIdentity(revealed))
        let context = try initial.context(ticket: created.ticket)
        precondition(SetupCrypto.commitment(context: context, hostEphemeral: hostEphemeral).companionBase64 == initial.commitment)
        let transcript = SetupCrypto.transcript(context: context, hostEphemeral: hostEphemeral, phoneEphemeral: ephemPublic)
        let code = try SetupCrypto.comparisonCode(privateKey: ephemeral, peer: hostEphemeral, transcript: transcript)
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: codeFile) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let hostCode = try String(contentsOfFile: codeFile, encoding: .utf8)
        precondition(hostCode == code)
        precondition(revealed.envelope == nil)
        print("PASS: independent Swift/Python codes match; no enrollment exists before confirmation")
        _ = try await request("PUT", path + "/claims/" + initial.id + "/confirm",
            ["confirmation": SetupCrypto.confirmation(privateKey: ephemeral, peer: hostEphemeral, transcript: transcript)])
        for _ in 0..<60 {
            claim = try JSONDecoder().decode(Snapshot.self, from: await request("GET", path)).claims.first
            if claim?.envelope != nil { break }
            try await Task.sleep(for: .seconds(1))
        }
        let data = try SetupCrypto.decryptEnrollment(claim!.envelope!, phonePrivate: phonePrivate,
            hostPublic: SetupCrypto.decode(initial.host_public_key, count: 32), transcript: transcript)
        let invitation = try CompanionInvitation.parse(String(decoding: data, as: UTF8.self))
        precondition(invitation.host_public_key == initial.host_public_key && invitation.installation_id == initial.installation_id && invitation.relay_url == service)
        let client = HermesClient()
        let credentials = CompanionCredentials(deviceToken: invitation.device_token, privateKey: phonePrivate, pairingSecret: invitation.pairing_secret)
        let profiles = try await client.connect(companion: invitation.connection, credentials: credentials)
        precondition(profiles.map(\.id).contains("research"))
        print("PASS: numeric pairing completes the real HPKE connection with the original phone key")
        let messages = try await client.messages(profile: "research", sessionID: "saved-0")
        precondition(messages.count == 501)
        client.disconnect()
        _ = try await request("POST", path + "/complete", [:])
        print("PASS: encrypted conversation access and setup cleanup")
    }
}
