import XCTest
import DeviceCheck
@testable import Hermes

@MainActor
private final class DeviceAttestFixture: DeviceAppAttesting {
    var isSupported = true
    var generated = 0
    var assertionError: Error?
    var attestationError: Error?
    var inputs: [(String, Data)] = []
    func generateKey() async throws -> String {
        generated += 1
        return Data(repeating: UInt8(generated), count: 32).base64EncodedString()
    }
    func attestKey(_ key: String, clientDataHash: Data) async throws -> Data {
        inputs.append((key, clientDataHash))
        if let attestationError { throw attestationError }
        return Data("attestation fixture".utf8)
    }
    func generateAssertion(_ key: String, clientDataHash: Data) async throws -> Data {
        if let assertionError { throw assertionError }
        return Data("assertion fixture".utf8)
    }
}

@MainActor
private final class AttestChallengeFixture: SetupNetworking {
    var knownKeys: Set<String> = []
    var requests = 0
    func request(service: String, path: String, method: String, body: Data?, token: String?, ticket: String?) async throws -> Data {
        XCTAssertEqual(path, "/v1/app-attest/challenges")
        requests += 1
        let fields = try JSONDecoder().decode([String: String].self, from: body!)
        return try JSONSerialization.data(withJSONObject: [
            "challenge": Data(repeating: UInt8(requests), count: 32).companionBase64,
            "attested": knownKeys.contains(fields["key_id"]!)])
    }
}

@MainActor
final class AppAttestClientTests: XCTestCase {
    func testReinstallRecoversAnInvalidSavedKeyWithOneNewKey() async throws {
        let service = "https://" + UUID().uuidString.lowercased() + ".test"
        defer { clear(service) }
        let device = DeviceAttestFixture(), network = AttestChallengeFixture()
        let client = AppAttestClient(attest: device)
        let first = try await client.proof(service: service, phoneKey: "phone", network: network)
        let fields = try JSONSerialization.jsonObject(with: first) as! [String: Any]
        let firstKey = fields["key_id"] as! String
        network.knownKeys.insert(firstKey)
        try client.didIssueTicket(service: service)
        device.assertionError = NSError(domain: DCErrorDomain, code: DCError.Code.invalidKey.rawValue)
        let recovered = try await client.proof(service: service, phoneKey: "phone", network: network)
        let result = try JSONSerialization.jsonObject(with: recovered) as! [String: Any]
        XCTAssertEqual(device.generated, 2)
        XCTAssertNotEqual(result["key_id"] as? String, firstKey)
        XCTAssertEqual(result["assertion"] as? Bool, false)
    }

    func testTemporaryAppleFailureKeepsTheKeyAndChallengeDigest() async throws {
        let service = "https://" + UUID().uuidString.lowercased() + ".test"
        defer { clear(service) }
        let device = DeviceAttestFixture(), network = AttestChallengeFixture()
        let client = AppAttestClient(attest: device)
        device.attestationError = NSError(domain: DCErrorDomain, code: DCError.Code.serverUnavailable.rawValue)
        do {
            _ = try await client.proof(service: service, phoneKey: "phone", network: network)
            XCTFail("The Apple error must remain visible")
        } catch { XCTAssertEqual((error as NSError).code, DCError.Code.serverUnavailable.rawValue) }
        device.attestationError = nil
        _ = try await client.proof(service: service, phoneKey: "phone", network: network)
        XCTAssertEqual(device.generated, 1)
        XCTAssertEqual(network.requests, 1)
        XCTAssertEqual(device.inputs.count, 2)
        XCTAssertEqual(device.inputs[0].0, device.inputs[1].0)
        XCTAssertEqual(device.inputs[0].1, device.inputs[1].1)
    }

    func testRepeatedInvalidKeyStopsAfterOneAutomaticRetry() async {
        let service = "https://" + UUID().uuidString.lowercased() + ".test"
        defer { clear(service) }
        let device = DeviceAttestFixture(), network = AttestChallengeFixture()
        let client = AppAttestClient(attest: device)
        device.attestationError = NSError(domain: DCErrorDomain, code: DCError.Code.invalidKey.rawValue)
        do {
            _ = try await client.proof(service: service, phoneKey: "phone", network: network)
            XCTFail("A repeated invalid key must stop setup")
        } catch { XCTAssertEqual((error as NSError).code, DCError.Code.invalidKey.rawValue) }
        XCTAssertEqual(device.generated, 2)
    }

    private func clear(_ service: String) {
        for suffix in ["", "/pending", "/challenge"] {
            CredentialStore.delete(account: "app-attest/" + service + suffix)
        }
    }
}
