import XCTest
@testable import Hermes

/// Run through prepare-notification-tests.py with notification_navigation_fixture.py.
@MainActor
final class NotificationNavigationTests: XCTestCase {
    private let address = "http://127.0.0.1:19129"
    private let reference = Data(repeating: 7, count: 32).companionBase64
    private var store: AppStore!
    private var savedSettings: Any?
    private var savedReference: String?

    override func setUp() async throws {
        savedSettings = UserDefaults.standard.object(forKey: "hermes.connection.settings.v1")
        savedReference = PushNotifications.shared.pendingReference
        if let savedReference { PushNotifications.shared.acknowledgeNotificationOpen(savedReference) }
        store = AppStore(contentCache: ContentCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        _ = try await control(["reset": true])
    }

    override func tearDown() async throws {
        _ = try await control(["release_history": true, "release_lookup": true])
        store.disconnect()
        if let pending = PushNotifications.shared.pendingReference { PushNotifications.shared.acknowledgeNotificationOpen(pending) }
        if let savedReference { PushNotifications.shared.rememberNotificationOpen(savedReference) }
        if let savedSettings { UserDefaults.standard.set(savedSettings, forKey: "hermes.connection.settings.v1") }
        else { UserDefaults.standard.removeObject(forKey: "hermes.connection.settings.v1") }
    }

    private func connect() async {
        await store.connect(address: address, username: "", password: "", token: "notification-fixture-token")
        XCTAssertEqual(store.phase, .connected, store.errorMessage ?? "No connection error")
    }

    private func control(_ body: [String: Any] = [:]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: address + "/control")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate(), file: file, line: line)
    }

    func testColdTapRoutesBeforeHistoryWithoutListingOrDuplicateResume() async throws {
        PushNotifications.shared.rememberNotificationOpen(reference)
        let task = Task { await self.connect() }
        try await waitUntil { self.store.notificationDestination != nil }
        XCTAssertEqual(store.notificationDestination, FollowedConversation(profile: "research", sessionID: "saved"))
        XCTAssertTrue(store.isLoadingMessages)
        XCTAssertFalse(store.sessionReady)
        XCTAssertNil(PushNotifications.shared.pendingReference)
        // Reproduce root-view callbacks while the initial history is still blocked.
        await store.processPendingNotification()
        await store.openSession(try XCTUnwrap(store.selectedSession))
        _ = try await control(["release_history": true])
        await task.value
        XCTAssertTrue(store.sessionReady)
        XCTAssertEqual(store.messages.map(\.text), ["Reply from research"])
        let stats = try await control()
        XCTAssertEqual(stats["lookups"] as? Int, 1)
        XCTAssertEqual(stats["resumes"] as? Int, 1)
        XCTAssertEqual(stats["histories"] as? Int, 1)
        XCTAssertEqual(stats["lists"] as? Int, 0)
    }

    func testColdTapRestoresEnrollmentAndNotificationPreferencesBeforeOpening() async throws {
        let account = "notifications/" + address
        try CredentialStore.saveValue(CompanionEnrollment(deviceID: "fixture-device", deviceToken: "fixture-enrollment-token", installationID: "fixture-installation"), account: account)
        let key = account + "/preferences"
        let old = UserDefaults.standard.object(forKey: key)
        defer {
            CredentialStore.delete(account: account)
            if let old { UserDefaults.standard.set(old, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(["enabled": true, "allSessions": true], forKey: key)
        _ = try await control(["reset": true, "require_enrollment": true])
        PushNotifications.shared.rememberNotificationOpen(reference)
        let task = Task { await self.connect() }
        try await waitUntil { self.store.notificationDestination != nil }
        XCTAssertTrue(store.notificationsEnabled)
        XCTAssertTrue(store.allSessionNotifications)
        _ = try await control(["release_history": true])
        await task.value
        XCTAssertTrue(store.sessionReady)
        XCTAssertEqual(UserDefaults.standard.dictionary(forKey: key)?["enabled"] as? Bool, true)
        XCTAssertEqual(UserDefaults.standard.dictionary(forKey: key)?["allSessions"] as? Bool, true)
    }

    func testCachedChatAppearsWhileHistoryLoadsAndBackIsRespected() async throws {
        await connect()
        store.phase = .disconnected
        await store.selectProfile(try XCTUnwrap(store.profiles.first { $0.id == "research" }))
        let session = HermesSession(id: "saved", title: "Cached chat", preview: "", lastActive: .now, messageCount: 1, source: "cli")
        await store.openSession(session)
        store.messages = [ChatMessage(id: "cached", role: "assistant", text: "Cached reply")]
        store.phase = .connected
        let task = Task { await self.store.openNotification(reference: self.reference) }
        try await waitUntil { self.store.notificationDestination != nil }
        XCTAssertEqual(store.messages.map(\.text), ["Cached reply"])
        store.backToBots()
        _ = try await control(["release_history": true])
        await task.value
        XCTAssertNil(store.notificationDestination)
        XCTAssertNil(store.selectedSession)
        XCTAssertTrue(store.messages.isEmpty)
    }

    func testSameSessionIDInAnotherProfileDoesNotReuseOldTranscript() async throws {
        await connect()
        store.phase = .disconnected
        await store.selectProfile(try XCTUnwrap(store.profiles.first { $0.id == "default" }))
        await store.openSession(HermesSession(id: "saved", title: "Other profile", preview: "", lastActive: .now, messageCount: 1, source: "cli"))
        store.messages = [ChatMessage(id: "other", role: "assistant", text: "Private to default")]
        store.phase = .connected
        let task = Task { await self.store.openNotification(reference: self.reference) }
        try await waitUntil { self.store.notificationDestination != nil }
        XCTAssertEqual(store.selectedProfile?.id, "research")
        XCTAssertTrue(store.messages.isEmpty)
        _ = try await control(["release_history": true])
        await task.value
        XCTAssertEqual(store.messages.map(\.text), ["Reply from research"])
    }

    func testLateLookupDoesNotOverrideManualNavigation() async throws {
        await connect()
        _ = try await control(["reset": true, "hold_lookup": true])
        let task = Task { await self.store.openNotification(reference: self.reference) }
        try await waitUntil { self.store.openingNotificationReference != nil }
        store.backToBots()
        _ = try await control(["release_lookup": true])
        await task.value
        XCTAssertNil(store.notificationDestination)
        XCTAssertNil(store.selectedSession)
        XCTAssertNil(PushNotifications.shared.pendingReference)
        await store.processPendingNotification()
        let stats = try await control()
        XCTAssertEqual(stats["resumes"] as? Int, 0)
    }

    func testHistoryFailureKeepsDestinationAndAllowsRetry() async throws {
        await connect()
        _ = try await control(["reset": true, "hold_history": false, "failure": true])
        await store.openNotification(reference: reference)
        XCTAssertEqual(store.notificationDestination?.sessionID, "saved")
        XCTAssertEqual(store.conversationRefresh.phase, .failed)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(PushNotifications.shared.pendingReference)
        _ = try await control(["reset": true, "hold_history": false])
        await store.openSession(try XCTUnwrap(store.selectedSession))
        XCTAssertTrue(store.sessionReady)
        XCTAssertNil(store.errorMessage)
    }
}
