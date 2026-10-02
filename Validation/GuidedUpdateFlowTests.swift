import XCTest
@testable import Hermes

/// Local fixture only: no model calls, installations, or APNs requests.
@MainActor
final class GuidedUpdateFlowTests: XCTestCase {
    let address = "http://127.0.0.1:19129"
    var store: AppStore!
    var account: String { "notifications/" + address }

    override func setUp() async throws {
        _ = try await control(["reset": true, "updates": true, "tracked": false, "hold_history": false])
        try CredentialStore.saveValue(CompanionEnrollment(deviceID: "11111111-1111-4111-8111-111111111111", deviceToken: "fixture", installationID: "fixture"), account: account)
        UserDefaults.standard.removeObject(forKey: account + "/update-request")
        UserDefaults.standard.removeObject(forKey: account + "/preferences")
        store = AppStore(contentCache: ContentCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        await store.connect(address: address, username: "", password: "", token: "notification-fixture-token")
    }
    override func tearDown() async throws {
        _ = try await control(["release_turn": true, "release_lists": true, "release_follow": true])
        store.disconnect()
        CredentialStore.delete(account: account)
        UserDefaults.standard.removeObject(forKey: account + "/update-request")
        UserDefaults.standard.removeObject(forKey: account + "/preferences")
    }
    func control(_ body: [String: Any] = [:]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: address + "/control")!)
        request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func testOldCompanionUpgradeStartsOnceAndOnlyVerifiedReceiptCompletes() async throws {
        let notice = try XCTUnwrap(store.companionUpdate)
        XCTAssertTrue(store.canStartCompanionUpdate)
        await store.startCompanionUpdate(notice)
        XCTAssertEqual(store.updateDestination, FollowedConversation(profile: "default", sessionID: "update-conversation"))
        XCTAssertTrue(store.updateProgress?.pending == true, "A finished model turn is not installer verification")
        await store.startCompanionUpdate(notice)
        let stats = try await control()
        XCTAssertEqual(stats["creates"] as? Int, 1)
        XCTAssertEqual(stats["prompts"] as? Int, 1)
        XCTAssertEqual((stats["receipt"] as? [String: Any])?["notify"] as? Bool, false)
        // Simulate relaunch after the host has installed the new companion and verified health.
        _ = try await control(["verified": true])
        let restored = AppStore(contentCache: ContentCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        await restored.connect(address: address, username: "", password: "", token: "notification-fixture-token")
        XCTAssertEqual(restored.updateProgress?.status, "completed")
        XCTAssertEqual(restored.updateProgress?.installed, "0.16.0")
        XCTAssertNil(restored.companionUpdate)
        XCTAssertTrue(restored.updateProgress?.message.contains("Restart") == true)
        restored.disconnect()
    }
    func testRefreshNeverStartsAConversationAndMissingDefaultDoesNotSpendTokens() async throws {
        await store.refreshCompanionUpdate()
        let notice = try XCTUnwrap(store.companionUpdate)
        store.profiles.removeAll { $0.id == "default" }
        XCTAssertFalse(store.canStartCompanionUpdate)
        await store.startCompanionUpdate(notice)
        let stats = try await control()
        XCTAssertEqual(stats["creates"] as? Int, 0)
        XCTAssertEqual(stats["prompts"] as? Int, 0)
    }

    func testUpdateOpensAndSubmitsWithoutWaitingForListsOrNotificationFollow() async throws {
        _ = try await control(["reset": true, "updates": true, "tracked": false, "hold_history": false,
                               "hold_lists": true, "hold_follow": true, "hold_turn": true])
        store.notificationsEnabled = true
        let notice = try XCTUnwrap(store.companionUpdate)
        let start = Task { await store.startCompanionUpdate(notice) }
        for _ in 0..<100 {
            if (try await control())["prompts"] as? Int == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let stats = try await control()
        XCTAssertEqual(stats["lists"] as? Int, 0)
        XCTAssertEqual(stats["prompts"] as? Int, 1)
        XCTAssertEqual(store.updateDestination?.sessionID, "update-conversation")
        XCTAssertTrue(store.isSending)
        _ = try await control(["release_turn": true, "release_follow": true, "release_lists": true])
        await start.value
    }

    func testFailedTurnClearsPendingStatePersistsAndRetriesSameReceipt() async throws {
        _ = try await control(["turn_status": "error"])
        let notice = try XCTUnwrap(store.companionUpdate)
        await store.startCompanionUpdate(notice)
        let receipt = try XCTUnwrap(store.updateProgress?.receipt)
        XCTAssertEqual(store.updateProgress?.status, "failed")
        XCTAssertFalse(store.updateProgress?.pending ?? true)
        XCTAssertTrue(store.canRetryCompanionUpdate)
        XCTAssertNil(store.errorMessage, "Update recovery is inline, not a blocking modal")
        XCTAssertFalse(store.messages.contains { $0.role == "assistant" && $0.text.contains("internal error") })
        await store.refreshCompanionUpdate()
        XCTAssertEqual(store.updateProgress?.status, "failed")
        let restored = try JSONDecoder().decode(CompanionUpdateProgress.self,
            from: XCTUnwrap(UserDefaults.standard.data(forKey: account + "/update-request")))
        XCTAssertEqual(restored.status, "failed")
        _ = try await control(["turn_status": "complete"])
        await store.retryCompanionUpdate()
        let stats = try await control()
        XCTAssertEqual(stats["creates"] as? Int, 1)
        XCTAssertEqual(stats["prompts"] as? Int, 2)
        XCTAssertEqual(store.updateProgress?.receipt, receipt)
        XCTAssertTrue(store.updateProgress?.pending == true)
        XCTAssertEqual(store.messages.first?.text, receipt.displayText)
        XCTAssertFalse(store.messages.contains { $0.text.contains("--receipt") })
    }

    func testRunningInstallerTakesPrecedenceOverFailedModelTurnAndBlocksRetry() async throws {
        // A newer companion can report an installer still running independently.
        _ = try await control(["reset": true, "updates": true, "tracked": true, "hold_history": false,
                               "turn_status": "error"])
        _ = try await control(["receipt_status": "running"])
        await store.startCompanionUpdate(try XCTUnwrap(store.companionUpdate))
        XCTAssertEqual(store.updateProgress?.status, "running")
        XCTAssertFalse(store.canRetryCompanionUpdate)
        await store.retryCompanionUpdate()
        let stats = try await control()
        XCTAssertEqual(stats["prompts"] as? Int, 1)
    }

    func testLostConnectionKeepsOutcomeUnconfirmedAndNeverOffersResubmission() async throws {
        _ = try await control(["drop_turn": true])
        await store.startCompanionUpdate(try XCTUnwrap(store.companionUpdate))
        XCTAssertEqual(store.updateProgress?.status, "unconfirmed")
        XCTAssertTrue(store.updateProgress?.pending == true)
        XCTAssertFalse(store.canRetryCompanionUpdate)
        XCTAssertNil(store.errorMessage)
        await store.retryCompanionUpdate()
        let stats = try await control()
        XCTAssertEqual(stats["prompts"] as? Int, 1)
    }

    func testReopeningLegacyStuckRequestRecoversRetainedFailure() async throws {
        _ = try await control(["turn_status": "error"])
        await store.startCompanionUpdate(try XCTUnwrap(store.companionUpdate))
        var legacy = try XCTUnwrap(store.updateProgress)
        legacy.status = "requested"; legacy.error = nil
        UserDefaults.standard.set(try JSONEncoder().encode(legacy), forKey: account + "/update-request")
        store.disconnect()
        await store.connect(address: address, username: "", password: "", token: "notification-fixture-token")
        XCTAssertTrue(store.updateProgress?.pending == true)
        await store.openUpdateConversation()
        XCTAssertEqual(store.updateProgress?.status, "failed")
        XCTAssertTrue(store.canRetryCompanionUpdate)
        XCTAssertNil(store.errorMessage)
        let stats = try await control()
        XCTAssertEqual(stats["prompts"] as? Int, 1)
    }

    func testIdleUntrackedRequestCanRecoverAfterBackendLosesFailureSnapshot() async throws {
        _ = try await control(["reset": true, "updates": true, "tracked": true, "hold_history": false])
        _ = try await control(["receipt_status": "missing"])
        await store.startCompanionUpdate(try XCTUnwrap(store.companionUpdate))
        XCTAssertTrue(store.updateProgress?.pending == true)
        await store.openUpdateConversation()
        XCTAssertEqual(store.updateProgress?.status, "failed")
        XCTAssertTrue(store.canRetryCompanionUpdate)
        let stats = try await control()
        XCTAssertEqual(stats["prompts"] as? Int, 1, "Reconciliation never resubmits automatically")
    }

    func testInterruptedUpdateAllowsRetryWithoutClaimingCompletion() async throws {
        _ = try await control(["turn_status": "interrupted"])
        await store.startCompanionUpdate(try XCTUnwrap(store.companionUpdate))
        XCTAssertEqual(store.updateProgress?.status, "failed")
        XCTAssertFalse(store.updateProgress?.pending ?? true)
        XCTAssertTrue(store.canRetryCompanionUpdate)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.updateProgress?.message.isEmpty ?? true)
    }

    func testLaterChatFailureDoesNotUndoVerifiedUpdateOrHideItsError() async throws {
        await store.startCompanionUpdate(try XCTUnwrap(store.companionUpdate))
        _ = try await control(["verified": true])
        await store.refreshCompanionUpdate()
        XCTAssertEqual(store.updateProgress?.status, "completed")
        _ = try await control(["turn_status": "error"])
        _ = await store.send("A later question in the update conversation")
        XCTAssertEqual(store.updateProgress?.status, "completed")
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.canRetryCompanionUpdate)
    }

    func testSeparateHostUpgradeClearsPersistedFailureAfterRelaunch() async throws {
        _ = try await control(["turn_status": "error"])
        await store.startCompanionUpdate(try XCTUnwrap(store.companionUpdate))
        XCTAssertEqual(store.updateProgress?.status, "failed")
        store.disconnect()
        // The host was upgraded independently, so this request has no receipt.
        _ = try await control(["installed_version": "0.17.3", "tracked": true,
                               "receipt_status": "missing"])
        await store.connect(address: address, username: "", password: "", token: "notification-fixture-token")
        XCTAssertEqual(store.installedCompanionVersion, "0.17.3")
        XCTAssertNil(store.updateProgress)
        XCTAssertNil(store.companionUpdate)
        XCTAssertNil(UserDefaults.standard.data(forKey: account + "/update-request"))
        XCTAssertFalse(store.canRetryCompanionUpdate)
        let stats = try await control()
        XCTAssertEqual(stats["prompts"] as? Int, 1, "Reconciliation must never start another update")
    }

    func testSeparateHostInstallAtExactTargetClearsUnconfirmedAttempt() async throws {
        _ = try await control(["drop_turn": true])
        await store.startCompanionUpdate(try XCTUnwrap(store.companionUpdate))
        XCTAssertEqual(store.updateProgress?.status, "unconfirmed")
        _ = try await control(["installed_version": "0.16.0"])
        await store.refreshCompanionUpdate()
        XCTAssertNil(store.updateProgress, "Matching installed version retires the old attempt without inventing a receipt")
        XCTAssertNil(UserDefaults.standard.data(forKey: account + "/update-request"))
    }

    func testOlderOrInvalidInstalledVersionDoesNotClearFailedAttempt() async throws {
        _ = try await control(["turn_status": "error"])
        await store.startCompanionUpdate(try XCTUnwrap(store.companionUpdate))
        let failed = try XCTUnwrap(store.updateProgress)
        for version in ["0.15.9", "0.16.0-beta", "unknown"] {
            _ = try await control(["installed_version": version])
            await store.refreshCompanionUpdate()
            XCTAssertEqual(store.updateProgress, failed)
            XCTAssertNotNil(UserDefaults.standard.data(forKey: account + "/update-request"))
        }
    }

    func testRunningInstallerAtMatchingVersionStillNeedsVerifiedReceipt() async throws {
        _ = try await control(["tracked": true, "receipt_status": "running"])
        await store.startCompanionUpdate(try XCTUnwrap(store.companionUpdate))
        _ = try await control(["installed_version": "0.16.0"])
        await store.refreshCompanionUpdate()
        XCTAssertEqual(store.updateProgress?.status, "running")
        XCTAssertTrue(store.updateProgress?.pending == true)
        XCTAssertFalse(store.canRetryCompanionUpdate)
        XCTAssertNotNil(UserDefaults.standard.data(forKey: account + "/update-request"))
    }
}
