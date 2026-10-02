import XCTest
import CryptoKit
@testable import Hermes

@MainActor
private final class SetupFixtureBroker: SetupNetworking {
    let signer = Curve25519.Signing.PrivateKey()
    let host = Curve25519.KeyAgreement.PrivateKey()
    let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    let intent = Data(repeating: 3, count: 32).companionBase64
    let owner = Data(repeating: 4, count: 32).companionBase64
    var phoneKey = ""
    var ticket = ""
    var promptPrefix: String? = "Server wording: connect this phone.\n\nTicket:\n"
    var promptOverride: String?
    var claim: SetupClaim?
    var selected: String?
    var status = "pending"
    var nextReadError: Error?
    var pauseNextRead = false
    var pausedRead: CheckedContinuation<Void, Never>?
    var confirmations = 0
    var phoneKeys: [String] = []
    let service = "https://relay.test"

    func request(service: String, path: String, method: String, body: Data?, token: String?, ticket: String?) async throws -> Data {
        func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
        let fields = try body.map { try JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        if path.hasSuffix("/key") && path == "/v1/pairing/key" {
            return try json(["public_key": signer.publicKey.rawRepresentation.companionBase64])
        }
        if path == "/v1/pairing/intents" {
            phoneKey = fields["phone_public_key"]!
            let now = Int(Date.now.timeIntervalSince1970)
            let payload = try json([1, intent, phoneKey, now, now + 1200, service]).companionBase64
            let unsigned = "HJ1." + payload
            self.ticket = unsigned + "." + (try signer.signature(for: Data(unsigned.utf8))).companionBase64
            let id = UUID().uuidString.lowercased(), installation = UUID().uuidString.lowercased()
            let context = try SetupCrypto.context(ticket: self.ticket, claimID: id, installationID: installation,
                hostKey: host.publicKey.rawRepresentation.companionBase64, hostName: "Fixture Hermes")
            claim = SetupClaim(claim_id: id, installation_id: installation, host_public_key: host.publicKey.rawRepresentation.companionBase64,
                host_name: "Fixture Hermes", commitment: SetupCrypto.commitment(context: context, hostEphemeral: ephemeral.publicKey.rawRepresentation).companionBase64)
            var response = ["ticket": self.ticket, "owner_token": owner]
            if let promptPrefix { response["prompt"] = promptOverride ?? (promptPrefix + self.ticket) }
            return try json(response)
        }
        XCTAssertEqual(token, owner); XCTAssertEqual(ticket, self.ticket)
        if method == "GET" {
            if let error = nextReadError { nextReadError = nil; throw error }
            if pauseNextRead {
                pauseNextRead = false
                await withCheckedContinuation { pausedRead = $0 }
            }
            var value: [String: Any] = ["status": status, "claims": try claim.map { [try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))] } ?? []]
            if let selected { value["selected"] = selected }
            return try json(value)
        }
        if path.hasSuffix("/key") {
            let phone = fields["phone_ephemeral"]!
            phoneKeys.append(phone)
            claim?.phone_ephemeral = phone
            claim?.host_ephemeral = ephemeral.publicKey.rawRepresentation.companionBase64
        } else if path.hasSuffix("/confirm") {
            let c = claim!
            let transcript = SetupCrypto.transcript(context: try c.context(ticket: self.ticket), hostEphemeral: ephemeral.publicKey.rawRepresentation,
                phoneEphemeral: try SetupCrypto.decode(c.phone_ephemeral!, count: 32))
            XCTAssertEqual(fields["confirmation"], try SetupCrypto.confirmation(privateKey: ephemeral.rawRepresentation,
                peer: SetupCrypto.decode(c.phone_ephemeral!, count: 32), transcript: transcript))
            confirmations += 1
            claim?.confirmation = fields["confirmation"]; selected = c.id
            let invitation: [String: Any] = ["v": 1, "relay_url": service, "installation_id": c.installation_id,
                "device_id": UUID().uuidString.lowercased(), "device_token": Data(repeating: 6, count: 32).companionBase64,
                "pairing_secret": Data(repeating: 7, count: 32).companionBase64, "host_public_key": c.host_public_key,
                "expires_at": Date.now.timeIntervalSince1970 + 240]
            var sender = try HPKE.Sender(recipientKey: Curve25519.KeyAgreement.PublicKey(rawRepresentation: SetupCrypto.decode(phoneKey, count: 32)),
                ciphersuite: .Curve25519_SHA256_ChachaPoly, info: SetupCrypto.domain + Data("enrollment\0".utf8) + transcript, authenticatedBy: host)
            let ciphertext = try sender.seal(json(invitation), authenticating: transcript)
            claim?.envelope = (sender.encapsulatedKey + ciphertext).companionBase64
        } else if path.hasSuffix("/cancel") { status = "cancelled" }
        else if path.hasSuffix("/complete") { status = "complete" }
        return try json(["status": "ok"])
    }
}

@MainActor
final class SetupPairingTests: XCTestCase {
    private var account = ""
    override func setUp() { account = "setup-test/" + UUID().uuidString }
    override func tearDown() { CredentialStore.delete(account: account) }

    private func ready(_ broker: SetupFixtureBroker) async -> SetupPairing {
        let pairing = SetupPairing(network: broker, account: account, service: broker.service)
        await pairing.prepare(); await pairing.refresh(); await pairing.refresh()
        XCTAssertNil(pairing.error)
        XCTAssertEqual(pairing.comparisons.count, 1)
        return pairing
    }

    func testFailedSavedSetupReadPreservesCredentialsAndBlocksReplacement() async throws {
        let saved = "Saved setup data with an unsupported schema"
        try CredentialStore.saveValue(saved, account: account)
        let broker = SetupFixtureBroker()
        let pairing = SetupPairing(network: broker, account: account, service: broker.service)
        XCTAssertNotNil(pairing.error)
        XCTAssertEqual(pairing.failure, .verification)
        XCTAssertEqual(try CredentialStore.readValue(String.self, account: account), saved)

        await pairing.prepare()
        XCTAssertNotNil(pairing.error)
        XCTAssertFalse(pairing.hasAttempt)
        XCTAssertTrue(broker.ticket.isEmpty, "A failed read must not create another setup attempt.")
        XCTAssertEqual(try CredentialStore.readValue(String.self, account: account), saved)

        // Explicit cancellation permits a new attempt.
        pairing.cancel()
        await pairing.prepare()
        XCTAssertNil(pairing.error)
        XCTAssertTrue(pairing.hasAttempt)
        XCTAssertFalse(broker.ticket.isEmpty)
    }

    func testSavedSetupReadCanRecoverWithoutReplacingTheAttempt() async throws {
        let broker = SetupFixtureBroker()
        let original = await ready(broker)
        let ticket = broker.ticket
        try CredentialStore.saveValue("unreadable setup", account: account)
        let restored = SetupPairing(network: broker, account: account, service: broker.service)
        XCTAssertNotNil(restored.error)
        // The original flow still has its saved keys and can persist them again.
        original.connectionFailed()
        await restored.prepare()
        XCTAssertNil(restored.error)
        XCTAssertEqual(restored.prompt, original.prompt)
        XCTAssertTrue(restored.needsConnectionRetry)
        XCTAssertEqual(broker.ticket, ticket)
    }

    func testServerPromptIsUsedVerbatimAndSurvivesRelaunch() async throws {
        let broker = SetupFixtureBroker(), pairing = await ready(broker)
        let expected = try XCTUnwrap(broker.promptPrefix) + broker.ticket
        XCTAssertEqual(pairing.prompt, expected)
        broker.promptPrefix = "Changed server wording for the next attempt: "
        let restored = SetupPairing(network: broker, account: account, service: broker.service)
        await restored.prepare()
        await restored.refresh()
        XCTAssertEqual(restored.prompt, expected)
        XCTAssertEqual(restored.comparisons.first?.code, pairing.comparisons.first?.code)
    }

    func testOlderServerAndSavedAttemptKeepLegacyPrompt() async {
        let broker = SetupFixtureBroker()
        broker.promptPrefix = nil
        let pairing = await ready(broker)
        let expected = HermesCompanionSetup.prompt(ticket: broker.ticket)
        XCTAssertEqual(pairing.prompt, expected)
        let restored = SetupPairing(network: broker, account: account, service: broker.service)
        XCTAssertTrue(restored.hasAttempt)
        XCTAssertEqual(restored.prompt, expected)
    }

    func testInvalidServerPromptIsNotExposedForCopyOrShare() async {
        for text in ["", "Wrong ticket: HJ1.other", String(repeating: "x", count: 8193)] {
            let broker = SetupFixtureBroker()
            broker.promptOverride = text
            let pairing = SetupPairing(network: broker, account: account, service: broker.service)
            await pairing.prepare()
            XCTAssertNotNil(pairing.error)
            XCTAssertNil(pairing.prompt)
            XCTAssertFalse(pairing.hasAttempt)
        }
    }

    func testServerPromptCannotExposeOwnerTokenOrExceedSizeLimit() async {
        for oversized in [false, true] {
            let broker = SetupFixtureBroker()
            broker.promptPrefix = oversized ? String(repeating: "x", count: 8193) : broker.owner
            let pairing = SetupPairing(network: broker, account: account, service: broker.service)
            await pairing.prepare()
            XCTAssertNotNil(pairing.error)
            XCTAssertNil(pairing.prompt)
            XCTAssertFalse(pairing.hasAttempt)
        }
    }

    func testReadinessAndRepeatedRefreshNeverAuthorizeWithoutTheTap() async throws {
        let broker = SetupFixtureBroker(), pairing = await ready(broker)
        await pairing.refresh(); await pairing.refresh()
        XCTAssertFalse(pairing.hasSelection)
        XCTAssertEqual(broker.confirmations, 0)
        XCTAssertNil(try pairing.enrollment())
        XCTAssertTrue(pairing.prompt?.contains(broker.ticket) == true)
        XCTAssertFalse(pairing.prompt?.contains(broker.owner) == true)
    }

    func testConfirmationDecryptsEnrollmentUsingOriginalPhoneKey() async throws {
        let broker = SetupFixtureBroker(), pairing = await ready(broker)
        await pairing.confirm(pairing.comparisons[0].id)
        await pairing.refresh()
        let (invitation, privateKey) = try XCTUnwrap(pairing.enrollment())
        XCTAssertEqual(try CompanionCrypto.publicKey(for: privateKey).companionBase64, broker.phoneKey)
        XCTAssertEqual(invitation.host_public_key, broker.host.publicKey.rawRepresentation.companionBase64)
        XCTAssertEqual(broker.confirmations, 1)
        await pairing.confirm(pairing.comparisons[0].id)
        XCTAssertEqual(broker.confirmations, 1)
    }

    func testConfirmationDuringPollingIsAcceptedOnceAfterPollFinishes() async {
        let broker = SetupFixtureBroker(), pairing = await ready(broker)
        let id = pairing.comparisons[0].id
        broker.pauseNextRead = true
        let poll = Task { await pairing.refresh() }
        for _ in 0..<1000 { if broker.pausedRead != nil { break }; await Task.yield() }
        XCTAssertNotNil(broker.pausedRead)
        let tap = Task { await pairing.confirm(id) }
        for _ in 0..<1000 { if pairing.confirming { break }; await Task.yield() }
        XCTAssertTrue(pairing.confirming)
        XCTAssertEqual(broker.confirmations, 0)
        broker.pausedRead?.resume(); broker.pausedRead = nil
        await poll.value; await tap.value
        XCTAssertTrue(pairing.hasSelection)
        XCTAssertFalse(pairing.confirming)
        XCTAssertEqual(broker.confirmations, 1)
    }

    func testCancelWhileConfirmationWaitsForPollingNeverAuthorizes() async {
        let broker = SetupFixtureBroker(), pairing = await ready(broker)
        let id = pairing.comparisons[0].id
        broker.pauseNextRead = true
        let poll = Task { await pairing.refresh() }
        for _ in 0..<1000 { if broker.pausedRead != nil { break }; await Task.yield() }
        let tap = Task { await pairing.confirm(id) }
        for _ in 0..<1000 { if pairing.confirming { break }; await Task.yield() }
        XCTAssertTrue(pairing.confirming)
        pairing.cancel()
        broker.pausedRead?.resume(); broker.pausedRead = nil
        await poll.value; await tap.value
        XCTAssertFalse(pairing.hasSelection)
        XCTAssertFalse(pairing.hasAttempt)
        XCTAssertEqual(broker.confirmations, 0)
    }

    func testRelaunchKeepsTheSameEphemeralKeyAndStillRequiresConfirmation() async throws {
        let broker = SetupFixtureBroker(), first = await ready(broker)
        let original = first.comparisons[0].code
        let restored = SetupPairing(network: broker, account: account, service: broker.service)
        await restored.refresh()
        XCTAssertEqual(restored.comparisons.first?.code, original)
        XCTAssertEqual(Set(broker.phoneKeys).count, 1)
        XCTAssertEqual(broker.confirmations, 0)
        XCTAssertNil(try restored.enrollment())
    }

    func testChangedHostKeyFailsClosedAndCannotBeConfirmed() async {
        let broker = SetupFixtureBroker(), pairing = await ready(broker)
        let id = pairing.comparisons[0].id
        broker.claim?.host_ephemeral = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.companionBase64
        await pairing.refresh(); await pairing.confirm(id)
        XCTAssertTrue(pairing.isFailed); XCTAssertTrue(pairing.comparisons.isEmpty)
        XCTAssertEqual(broker.confirmations, 0)
    }

    func testBrokerCannotSelectAHostForThePhone() async {
        let broker = SetupFixtureBroker(), pairing = await ready(broker)
        broker.selected = broker.claim?.id
        await pairing.refresh()
        XCTAssertTrue(pairing.isFailed)
        XCTAssertFalse(pairing.hasSelection)
        XCTAssertEqual(broker.confirmations, 0)
    }

    func testCancelRemovesPendingKeysAndIgnoresFurtherReadiness() async throws {
        let broker = SetupFixtureBroker(), pairing = await ready(broker)
        pairing.cancel(); await pairing.refresh()
        XCTAssertFalse(pairing.hasAttempt); XCTAssertTrue(pairing.comparisons.isEmpty)
        let restored = SetupPairing(network: broker, account: account, service: broker.service)
        XCTAssertFalse(restored.hasAttempt)
        XCTAssertEqual(broker.confirmations, 0)
    }

    func testExpiredAndCancelledAttemptsHaveDistinctPersistedFailures() async {
        for (status, expected) in [("expired", SetupFailure.expired), ("cancelled", .cancelled)] {
            let broker = SetupFixtureBroker(), pairing = await ready(broker)
            broker.status = status
            await pairing.refresh()
            XCTAssertEqual(pairing.failure, expected)
            XCTAssertTrue(pairing.comparisons.isEmpty)
            let restored = SetupPairing(network: broker, account: account, service: broker.service)
            XCTAssertEqual(restored.failure, expected)
            pairing.cancel()
        }
    }

    func testTemporaryNetworkFailureRetainsCodesAndResumes() async {
        let broker = SetupFixtureBroker(), pairing = await ready(broker)
        let code = pairing.comparisons.first?.code
        broker.nextReadError = URLError(.notConnectedToInternet)
        await pairing.refresh()
        XCTAssertFalse(pairing.isFailed)
        XCTAssertEqual(pairing.comparisons.first?.code, code)
        XCTAssertNotNil(pairing.error)
        await pairing.refresh()
        XCTAssertNil(pairing.error)
        XCTAssertEqual(pairing.comparisons.first?.code, code)
    }

    func testMissingAttemptIsNotReportedAsNetworkOutage() async {
        let broker = SetupFixtureBroker(), pairing = await ready(broker)
        broker.nextReadError = SetupHTTPError(status: 404)
        await pairing.refresh()
        XCTAssertEqual(pairing.failure, .unavailable)
        XCTAssertTrue(pairing.isFailed)
    }

    func testConnectionFailureWaitsForExplicitRetryAcrossRelaunch() async {
        let broker = SetupFixtureBroker(), pairing = await ready(broker)
        await pairing.confirm(pairing.comparisons[0].id)
        pairing.connectionFailed()
        let restored = SetupPairing(network: broker, account: account, service: broker.service)
        XCTAssertTrue(restored.needsConnectionRetry)
        XCTAssertTrue(restored.hasSelection)
        restored.retryConnection()
        XCTAssertFalse(restored.needsConnectionRetry)
        XCTAssertEqual(broker.confirmations, 1)
    }

    func testTicketSignatureDoesNotAllowPhoneOrServiceSubstitution() throws {
        let signer = Curve25519.Signing.PrivateKey()
        let now = Int(Date.now.timeIntervalSince1970)
        let values: [Any] = [1, Data(repeating: 1, count: 32).companionBase64, Data(repeating: 2, count: 32).companionBase64, now, now+1200, "https://relay.test"]
        let payload = try JSONSerialization.data(withJSONObject: values).companionBase64
        let unsigned = "HJ1." + payload
        let ticket = unsigned + "." + (try signer.signature(for: Data(unsigned.utf8))).companionBase64
        let pub = signer.publicKey.rawRepresentation.companionBase64
        XCTAssertNoThrow(try SetupTicket.verify(ticket, publicKey: pub, service: "https://relay.test"))
        XCTAssertThrowsError(try SetupTicket.verify(ticket, publicKey: pub, service: "https://attacker.test"))
        XCTAssertThrowsError(try SetupTicket.verify(ticket, publicKey: pub, service: "https://relay.test", now: Date(timeIntervalSince1970: Double(now+1201))))
        XCTAssertThrowsError(try SetupTicket.verify(ticket, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.companionBase64, service: "https://relay.test"))
    }
}
