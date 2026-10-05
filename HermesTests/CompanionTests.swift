import XCTest
import Security
@testable import Hermes

@MainActor
final class CompanionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func invitation(overrides: [String: Any] = [:]) throws -> String {
        var fields: [String: Any] = [
            "v": 1,
            "relay_url": "https://relay.example.com",
            "installation_id": "6e4c8732-3f97-4243-a54a-cc6216039c31",
            "device_id": "49ab9a72-0a29-42b5-922c-c6cb1519e123",
            "device_token": Data(repeating: 1, count: 32).companionBase64,
            "host_public_key": try CompanionCrypto.publicKey(for: CompanionCrypto.generatePrivateKey()).companionBase64,
            "pairing_secret": Data(repeating: 2, count: 32).companionBase64,
            "expires_at": now.addingTimeInterval(600).timeIntervalSince1970,
        ]
        fields.merge(overrides) { _, new in new }
        return String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
    }

    func testRejectedPairingsOfferPairingAndOfflineFailuresRetainRetry() {
        for code in [401, 403, 404, 410] {
            let error = CompanionConnectionFailure.handshakeFailure(statusCode: code)
            XCTAssertEqual(ConnectionRecovery.companionFailure(error), .pairAgain)
            XCTAssertFalse(ConnectionRecovery.companionFailure(error).canRetry)
        }
        // Offline hosts (409), server outages, and unknown transport errors do not prove revocation.
        for code: Int? in [409, nil] {
            let error = CompanionConnectionFailure.handshakeFailure(statusCode: code)
            XCTAssertEqual(ConnectionRecovery.companionFailure(error), .unavailable)
            XCTAssertTrue(ConnectionRecovery.companionFailure(error).canRetry)
        }
        XCTAssertEqual(ConnectionRecovery.companionFailure(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(ConnectionRecovery.companionFailure(CompanionConnectionFailure.handshakeFailure(statusCode: 503)), .serviceUnavailable)
        XCTAssertEqual(ConnectionRecovery.companionFailure(CompanionConnectionFailure.handshakeFailure(statusCode: 429)), .serviceUnavailable)
        XCTAssertEqual(CompanionConnectionFailure.handshakeFailure(statusCode: nil, underlying: URLError(.notConnectedToInternet)), .offline)
    }

    func testCredentialRecoveryDistinguishesAccessFromInvalidData() {
        let access = ConnectionRecovery.credentialFailure(CredentialReadError.accessFailed(errSecInteractionNotAllowed))
        XCTAssertEqual(access, .credentialsUnavailable)
        XCTAssertTrue(access.canRetry)
        let invalid = ConnectionRecovery.credentialFailure(CredentialReadError.invalidData)
        XCTAssertEqual(invalid, .credentialsInvalid)
        XCTAssertFalse(invalid.canRetry)
    }

    func testUnreadableSavedCredentialsRequireNewSetup() async throws {
        let key = "hermes.connection.settings.v1"
        let previous = UserDefaults.standard.object(forKey: key)
        let address = "https://credentials-" + UUID().uuidString + ".example.com"
        defer {
            CredentialStore.delete(account: address)
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        // Valid Keychain bytes with the wrong schema must not be treated as a transient access failure.
        try CredentialStore.saveValue("incompatible saved data", account: address)
        let saved = ConnectionSettings(address: address, usesSavedCredentials: true)
        UserDefaults.standard.set(try JSONEncoder().encode(saved), forKey: key)
        let store = AppStore()
        await store.restoreConnection()
        XCTAssertEqual(store.connectionNotice, .credentialsInvalid)
        XCTAssertEqual(store.phase, .disconnected)
        XCTAssertEqual(store.settings, saved)
        XCTAssertNotNil(UserDefaults.standard.data(forKey: key))
        await store.retrySavedConnection()
        XCTAssertEqual(store.connectionNotice, .credentialsInvalid)
    }

    func testMissingSavedPairingReturnsToSetupWithoutAnAlert() async throws {
        let key = "hermes.connection.settings.v1"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        var identity = try CompanionInvitation.parse(invitation(), now: now).connection
        identity.deviceID = UUID().uuidString
        let saved = ConnectionSettings(address: identity.relayURL, companion: identity)
        UserDefaults.standard.set(try JSONEncoder().encode(saved), forKey: key)
        let store = AppStore()
        await store.restoreConnection()
        XCTAssertEqual(store.phase, .disconnected)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.connectionNotice, .pairAgain)
        XCTAssertFalse(store.connectionNotice?.canRetry ?? true)
        await store.retrySavedConnection()
        XCTAssertEqual(store.phase, .disconnected)
        XCTAssertEqual(store.settings?.companion, identity, "Retain saved details; a failed restore must not erase credentials.")
    }

    func testRemovingSavedPairingClearsCredentialsAndReturnsToFreshOnboarding() async throws {
        let key = "hermes.connection.settings.v1"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let identity = try CompanionInvitation.parse(invitation(), now: now).connection
        let saved = ConnectionSettings(address: identity.relayURL, companion: identity)
        let credentials = CompanionCredentials(deviceToken: "fixture", privateKey: CompanionCrypto.generatePrivateKey())
        try CredentialStore.saveValue(credentials, account: identity.keychainAccount)
        defer { CredentialStore.delete(account: identity.keychainAccount) }
        UserDefaults.standard.set(try JSONEncoder().encode(saved), forKey: key)
        let store = AppStore()
        store.settings = saved
        store.phase = .disconnected
        store.connectionNotice = .pairAgain
        store.forgetSavedConnection()
        XCTAssertNil(store.settings)
        XCTAssertNil(store.connectionNotice)
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
        XCTAssertNil(try CredentialStore.readValue(CompanionCredentials.self, account: identity.keychainAccount))
        await store.retrySavedConnection()
        XCTAssertEqual(store.phase, .disconnected)
        let relaunched = AppStore()
        await relaunched.restoreConnection()
        XCTAssertEqual(relaunched.phase, .disconnected)
        XCTAssertNil(relaunched.connectionNotice)
        XCTAssertNil(relaunched.settings)
    }

    func testStaleRecoveryRemovalCannotEraseAnActiveConnection() {
        let store = AppStore()
        store.settings = ConnectionSettings(address: "https://new-connection.example")
        store.phase = .connected
        store.forgetSavedConnection()
        XCTAssertEqual(store.settings?.address, "https://new-connection.example")
        XCTAssertEqual(store.phase, .connected)
    }

    func testNotificationTapWaitsForForegroundRecovery() async {
        let notifications = PushNotifications.shared
        let previous = notifications.pendingReference
        let reference = Data(repeating: 9, count: 32).companionBase64
        defer {
            notifications.acknowledgeNotificationOpen(reference)
            if let previous { notifications.rememberNotificationOpen(previous) }
        }
        let store = AppStore()
        store.phase = .connected
        store.setAppActive(false)
        store.enterBackground()
        notifications.rememberNotificationOpen(reference)
        await store.processPendingNotification()
        XCTAssertEqual(notifications.pendingReference, reference)
        XCTAssertNil(store.notificationStatus, "Do not try to resolve a tap over the suspended connection.")
        XCTAssertNil(store.errorMessage)
        await Task.yield()
    }

    func testRefreshingCurrentConversationPreservesVisibleTranscriptOnFailure() async {
        let store = AppStore()
        let session = HermesSession(id: "existing", title: "Conversation", preview: "", lastActive: Date(), messageCount: 1, source: "cli")
        store.phase = .connected
        store.selectedProfile = BotProfile(id: "default", displayName: "Hermes", summary: "", model: "", isGatewayRunning: true)
        store.selectedSession = session
        store.messages = [ChatMessage(id: "visible", role: "assistant", text: "Already loaded")]
        // An unavailable connection must not blank an already displayed transcript.
        await store.openSession(session)
        XCTAssertEqual(store.messages.map(\.text), ["Already loaded"])
        XCTAssertFalse(store.isLoadingMessages)
    }

    func testFreshLaunchNeedsNoConnectionError() async {
        let key = "hermes.connection.settings.v1"
        let previous = UserDefaults.standard.object(forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } }
        UserDefaults.standard.removeObject(forKey: key)
        let store = AppStore()
        await store.restoreConnection()
        XCTAssertEqual(store.phase, .disconnected)
        XCTAssertNil(store.errorMessage)
        store.enterBackground()
        store.returnToForeground()
        XCTAssertNil(store.errorMessage)
    }

    func testCompanionUpdateNoticeUsesTrustedLinksAndNewerVersions() {
        let payload: [String: Any] = ["update": ["available": true, "version": "0.4.0", "installed": "0.3.0", "url": "https://untrusted.example"]]
        let notice = CompanionUpdateNotice(capabilities: payload)
        XCTAssertEqual(notice?.version, "0.4.0")
        XCTAssertEqual(notice?.releaseURL.absoluteString, "https://github.com/cyberculturedhq/hermes-jr-companion/releases/tag/v0.4.0")
        XCTAssertFalse(notice?.installPrompt.contains("untrusted") ?? true)
    }

    func testCompanionUpdateNoticeRejectsMalformedAndOldVersions() {
        for value in ["../evil", "0.4.0?redirect=x", "0.4.0-beta", "99999999999999999999999999999999999.0.0", "0.3.0", "0.2.0"] {
            XCTAssertNil(CompanionUpdateNotice(capabilities: ["update": ["available": true, "version": value, "installed": "0.3.0"]]))
        }
        XCTAssertNil(CompanionUpdateNotice(capabilities: [:]))
        XCTAssertNil(CompanionUpdateNotice(capabilities: ["update": ["available": false, "version": "0.4.0", "installed": "0.3.0"]]))
    }

    func testDisconnectClearsCompanionNotice() {
        let store = AppStore()
        store.companionUpdate = CompanionUpdateNotice(capabilities: ["update": ["available": true, "version": "0.4.0", "installed": "0.3.0"]])
        store.disconnect()
        XCTAssertNil(store.companionUpdate)
    }

    func testEnrollmentRejectsLegacyPairingLinks() throws {
        let json = try invitation()
        XCTAssertNoThrow(try CompanionInvitation.parse(json, now: now))
        XCTAssertThrowsError(try CompanionInvitation.parse("hermes-jr://pair#" + Data(json.utf8).companionBase64, now: now))
    }

    func testRejectsExpiredMalformedAndOversizedInvitations() throws {
        for changes: [String: Any] in [
            ["v": 2], ["installation_id": "not-a-uuid"], ["device_id": "not-a-uuid"],
            ["host_public_key": Data(repeating: 1, count: 31).companionBase64],
            ["pairing_secret": Data(repeating: 1, count: 33).companionBase64],
            ["pairing_secret": "secret"], ["device_token": ""],
            ["expires_at": now.timeIntervalSince1970],
            ["expires_at": now.addingTimeInterval(3601).timeIntervalSince1970],
        ] {
            XCTAssertThrowsError(try CompanionInvitation.parse(invitation(overrides: changes), now: now), "Accepted \(changes.keys)")
        }
        XCTAssertThrowsError(try CompanionInvitation.parse(String(repeating: "x", count: 8193), now: now))
        XCTAssertThrowsError(try CompanionInvitation.parse("hermes-jr://pair#!!!", now: now))
    }

    func testRelayOriginDisallowsCredentialAndRedirectTargets() {
        for address in [
            "http://public.example", "http://127.0.0.1.attacker.example", "http://10.0.0.1", "file:///tmp/relay",
            "https://user:secret@example.com", "https://example.com/prefix", "https://example.com?token=secret",
            "https://example.com#fragment", "wss://example.com", "https://",
        ] {
            XCTAssertThrowsError(try CompanionInvitation.validatedRelayURL(address), address)
        }
        for address in ["https://relay.example.com", "https://relay.example.com/", "http://localhost:8787", "http://127.0.0.1:8787", "http://[::1]:8787"] {
            XCTAssertNoThrow(try CompanionInvitation.validatedRelayURL(address), address)
        }
    }

    func testSavedPublicConnectionContainsNoSecrets() throws {
        let invite = try CompanionInvitation.parse(invitation(), now: now)
        let json = String(decoding: try JSONEncoder().encode(invite.connection), as: UTF8.self)
        XCTAssertFalse(json.contains(invite.device_token))
        XCTAssertFalse(json.contains(invite.pairing_secret))
        XCTAssertTrue(json.contains(invite.host_public_key))
    }

    func testCredentialAccountIsBoundToRelayAndPinnedHostIdentity() throws {
        let original = try CompanionInvitation.parse(invitation(), now: now).connection
        var otherRelay = original
        otherRelay.relayURL = "https://different-relay.example.com"
        var otherHost = original
        otherHost.hostPublicKey = try CompanionCrypto.publicKey(for: CompanionCrypto.generatePrivateKey()).companionBase64
        XCTAssertNotEqual(original.keychainAccount, otherRelay.keychainAccount,
                          "A different relay must not receive credentials saved for the original relay.")
        XCTAssertNotEqual(original.keychainAccount, otherHost.keychainAccount,
                          "Changing the pinned host identity must require its own credential entry.")
        var normalized = original
        normalized.relayURL = "https://RELAY.example.com:443/"
        normalized.installationID = original.installationID.uppercased()
        normalized.deviceID = original.deviceID.uppercased()
        XCTAssertEqual(original.keychainAccount, normalized.keychainAccount)
    }

    func testColdLaunchNotificationIsBufferedUntilARealConnectionIsReady() async {
        let notifications = PushNotifications.shared
        let previous = notifications.pendingReference
        let reference = Data(repeating: 7, count: 32).companionBase64
        defer {
            notifications.acknowledgeNotificationOpen(reference)
            if let previous { notifications.rememberNotificationOpen(previous) }
        }
        notifications.rememberNotificationOpen(reference)
        let store = AppStore()
        XCTAssertEqual(store.phase, .restoring)
        await store.processPendingNotification()
        XCTAssertEqual(notifications.pendingReference, reference)
        XCTAssertNil(store.notificationDestination)
        store.phase = .disconnected
        await store.processPendingNotification()
        XCTAssertEqual(notifications.pendingReference, reference)
        XCTAssertNil(store.notificationDestination)
        notifications.acknowledgeNotificationOpen("different-reference")
        XCTAssertEqual(notifications.pendingReference, reference)
        notifications.acknowledgeNotificationOpen(reference)
        XCTAssertNil(notifications.pendingReference)
    }

    func testCompanionCredentialsKeychainRoundTrip() throws {
        let account = "companion-test-" + UUID().uuidString
        defer { CredentialStore.delete(account: account) }
        var credentials = CompanionCredentials(deviceToken: "test-token", privateKey: CompanionCrypto.generatePrivateKey(), pairingSecret: "test-secret")
        try CredentialStore.saveValue(credentials, account: account)
        let first = try XCTUnwrap(CredentialStore.readValue(CompanionCredentials.self, account: account))
        XCTAssertEqual(first.privateKey, credentials.privateKey)
        XCTAssertEqual(first.pairingSecret, credentials.pairingSecret)
        credentials.pairingSecret = nil
        try CredentialStore.saveValue(credentials, account: account)
        let paired = try XCTUnwrap(CredentialStore.readValue(CompanionCredentials.self, account: account))
        XCTAssertEqual(paired.privateKey, first.privateKey)
        XCTAssertEqual(paired.deviceToken, first.deviceToken)
        XCTAssertNil(paired.pairingSecret)
    }

    func testFailedNotificationCleanupPreservesCredentialsUntilExplicitLocalRemoval() async throws {
        let address = "https://disconnect-test-\(UUID().uuidString).invalid"
        let notificationAccount = "notifications/" + address
        let preferencesKey = notificationAccount + "/preferences"
        let connectionKey = "hermes.connection.settings.v1"
        let previousConnection = UserDefaults.standard.object(forKey: connectionKey)
        defer {
            CredentialStore.delete(account: address)
            CredentialStore.delete(account: notificationAccount)
            UserDefaults.standard.removeObject(forKey: preferencesKey)
            if let previousConnection { UserDefaults.standard.set(previousConnection, forKey: connectionKey) }
            else { UserDefaults.standard.removeObject(forKey: connectionKey) }
        }
        try CredentialStore.save(SavedCredentials(password: "fixture-password", token: ""), account: address)
        let enrollment = CompanionEnrollment(deviceID: UUID().uuidString, deviceToken: "fixture-local-token", installationID: UUID().uuidString)
        try CredentialStore.saveValue(enrollment, account: notificationAccount)
        UserDefaults.standard.set(["enabled": true], forKey: preferencesKey)
        UserDefaults.standard.set(Data("fixture-settings".utf8), forKey: connectionKey)
        let store = AppStore()
        store.settings = ConnectionSettings(address: address)
        store.phase = .connected
        store.notificationsEnabled = true
        // No client connection is opened: cleanup fails immediately without network I/O.
        guard case .needsLocalRemoval(let confirmation) = await store.disconnectWithNotifications() else {
            return XCTFail("Failed server cleanup must offer explicit local removal.")
        }
        XCTAssertEqual(store.phase, .connected)
        XCTAssertTrue(store.notificationsEnabled)
        XCTAssertEqual(try CredentialStore.read(account: address)?.password, "fixture-password")
        XCTAssertNotNil(try CredentialStore.readValue(CompanionEnrollment.self, account: notificationAccount))
        XCTAssertNotNil(UserDefaults.standard.object(forKey: preferencesKey))
        XCTAssertNotNil(UserDefaults.standard.object(forKey: connectionKey))

        XCTAssertTrue(store.removeLocalConnection(confirmation))
        XCTAssertEqual(store.phase, .disconnected)
        XCTAssertFalse(store.notificationsEnabled)
        XCTAssertNil(try CredentialStore.read(account: address))
        XCTAssertNil(try CredentialStore.readValue(CompanionEnrollment.self, account: notificationAccount))
        XCTAssertNil(UserDefaults.standard.object(forKey: preferencesKey))
        XCTAssertNil(UserDefaults.standard.object(forKey: connectionKey))
        XCTAssertFalse(store.removeLocalConnection(confirmation), "A consumed confirmation must not remove another connection.")
    }

    func testLocalRemovalConfirmationCannotRemoveAChangedConnection() async {
        let store = AppStore()
        store.settings = ConnectionSettings(address: "https://old-disconnect-fixture.invalid")
        store.phase = .connected
        store.notificationsEnabled = true
        guard case .needsLocalRemoval(let confirmation) = await store.disconnectWithNotifications() else {
            return XCTFail("Expected a local removal choice for failed cleanup.")
        }
        store.settings = ConnectionSettings(address: "https://new-disconnect-fixture.invalid")
        XCTAssertFalse(store.removeLocalConnection(confirmation))
        XCTAssertEqual(store.phase, .connected)
        XCTAssertEqual(store.settings?.address, "https://new-disconnect-fixture.invalid")
        XCTAssertTrue(store.notificationsEnabled)
    }

    func testDisconnectDoesNotOfferRemovalDuringAnExistingNotificationOperation() async {
        let store = AppStore()
        store.phase = .connected
        store.notificationsEnabled = true
        store.notificationBusy = true
        guard case .canceled = await store.disconnectWithNotifications() else {
            return XCTFail("An existing notification operation must finish before disconnect starts.")
        }
        XCTAssertEqual(store.phase, .connected)
        XCTAssertTrue(store.notificationsEnabled)
    }
}
