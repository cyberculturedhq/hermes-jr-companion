import Foundation
import CryptoKit

/// Authorized VM test: pairs a temporary Swift client; never sends a model prompt or reads conversations.
@main
struct VMSetupSmoke {
    struct Saved: Codable {
        let connection: CompanionConnection
        let credentials: CompanionCredentials
    }

    @MainActor
    static func features(_ client: HermesClient) async throws {
        let capability = try await client.companionAPI("capabilities")
        precondition(capability["file_upload"] as? Int == 1)
        let scope = try await client.companionAPI("devices/self/notification-scope", method: "PUT", body: ["all_sessions": true])
        precondition(scope["all_sessions"] as? Bool == true)
        let data = Data(repeating: 106, count: 600_000), uploadID = UUID().uuidString.lowercased()
        for offset in stride(from: 0, to: data.count, by: 512 * 1024) {
            let end = min(data.count, offset + 512 * 1024)
            let result = try await client.companionAPI("uploads", method: "PUT", body: [
                "upload_id": uploadID, "filename": "recovery-fixture.txt", "offset": offset,
                "total": data.count, "content_base64": data.subdata(in: offset..<end).base64EncodedString()])
            precondition(result["offset"] as? Int == end)
            precondition(result["complete"] as? Bool == (end == data.count))
        }
        for _ in 0..<10 {
            let profiles = try await client.profiles()
            precondition(!profiles.isEmpty)
            try await Task.sleep(for: .milliseconds(500))
        }
        print("PASS: encrypted multi-chunk upload, notification scope, and repeated real profile reads")
    }

    @MainActor
    static func main() async throws {
        if ["--reconnect", "--expect-offline"].contains(CommandLine.arguments[1]) {
            let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
            let client = HermesClient()
            defer { client.disconnect() }
            if CommandLine.arguments[1] == "--expect-offline" {
                do {
                    _ = try await client.connect(companion: saved.connection, credentials: saved.credentials)
                } catch {
                    print("PASS: unavailable host fails connection without re-pairing or sending a prompt")
                    return
                }
                preconditionFailure("Offline host unexpectedly connected")
            }
            let profiles = try await client.connect(companion: saved.connection, credentials: saved.credentials)
            precondition(!profiles.isEmpty)
            let scope = try await client.companionAPI("devices/self/notification-scope")
            precondition(scope["all_sessions"] as? Bool == true)
            try await features(client)
            print("PASS: saved phone key reconnects and preferences survive recovery")
            return
        }
        let service = CommandLine.arguments[1], codeFile = CommandLine.arguments[2]
        let promptFile = CommandLine.arguments[3], deviceFile = CommandLine.arguments[4]
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
        struct Created: Decodable { let ticket: String; let owner_token: String; let prompt: String }
        let created = try JSONDecoder().decode(Created.self, from: await request("POST", "/v1/pairing/intents", ["phone_public_key": phonePublic]))
        let setup = try SetupTicket.verify(created.ticket, publicKey: issuer["public_key"]!, service: service)
        precondition(setup.phonePublicKey == phonePublic)
        ticket = created.ticket; owner = created.owner_token
        try created.prompt.write(toFile: promptFile, atomically: true, encoding: .utf8)
        print("Setup prompt written; waiting for VM host")
        fflush(stdout)
        let path = "/v1/pairing/" + setup.intentID
        struct Snapshot: Decodable { let claims: [SetupClaim] }
        var claim: SetupClaim?
        for _ in 0..<1100 {
            claim = try JSONDecoder().decode(Snapshot.self, from: await request("GET", path)).claims.first
            if claim != nil { break }
            try await Task.sleep(for: .seconds(1))
        }
        guard let initial = claim else { throw URLError(.timedOut) }
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
        for _ in 0..<3000 {
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
        precondition(!profiles.isEmpty)
        if CommandLine.arguments.count > 5 {
            try await features(client)
            let saved = Saved(connection: invitation.connection,
                              credentials: CompanionCredentials(deviceToken: invitation.device_token, privateKey: phonePrivate, pairingSecret: nil))
            let path = CommandLine.arguments[5]
            try JSONEncoder().encode(saved).write(to: URL(fileURLWithPath: path), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
        try invitation.device_id.write(toFile: deviceFile, atomically: true, encoding: .utf8)
        print("PASS: numeric pairing completes the real HPKE connection with the original phone key")
        client.disconnect()
        _ = try await request("POST", path + "/complete", [:])
        print("PASS: VM profile discovery and setup cleanup; no conversations read")
    }
}
