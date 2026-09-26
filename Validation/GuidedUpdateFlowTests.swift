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
}
