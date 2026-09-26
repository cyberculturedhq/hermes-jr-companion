import XCTest
@testable import Hermes

@MainActor
final class ContentCacheTests: XCTestCase {
    func testUnreadRepliesRespectVisibilityPersistAndStayScoped() {
        let address = "https://unread-\(UUID().uuidString).example"
        defer { UserDefaults.standard.removeObject(forKey: "notifications/" + address + "/conversation-read-state.v1") }
        let store = AppStore()
        store.settings = ConnectionSettings(address: address)
        store.selectedProfile = BotProfile(id: "research", displayName: "Research", summary: "", model: "", isGatewayRunning: true)
        store.visibleSessionID = "open"
        store.noteAssistantReply(profile: "research", sessionID: "open")
        XCTAssertFalse(store.isSessionUnread("open", profile: "research"))
        store.noteAssistantReply(profile: "research", sessionID: "other")
        XCTAssertTrue(store.isSessionUnread("other", profile: "research"))
        XCTAssertFalse(store.isSessionUnread("other", profile: "default"))
        store.setAppActive(false)
        store.noteAssistantReply(profile: "research", sessionID: "open")
        XCTAssertTrue(store.isSessionUnread("open", profile: "research"))
        let reopened = AppStore()
        reopened.settings = ConnectionSettings(address: address)
        XCTAssertTrue(reopened.isSessionUnread("other", profile: "research"))
        reopened.markSessionRead("other", profile: "research")
        let readAgain = AppStore()
        readAgain.settings = ConnectionSettings(address: address)
        XCTAssertFalse(readAgain.isSessionUnread("other", profile: "research"))
        XCTAssertTrue(readAgain.isSessionUnread("open", profile: "research"))
        readAgain.settings = ConnectionSettings(address: "https://different.example")
        XCTAssertFalse(readAgain.isSessionUnread("open", profile: "research"))
    }

    func testRoundTripIsolationAndRemoval() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ContentCache(directory: directory)
        let first = ConnectionSettings(address: "https://one.example", username: "alice")
        let otherUser = ConnectionSettings(address: first.address, username: "bob")
        let second = ConnectionSettings(address: "https://two.example")
        let date = Date(timeIntervalSince1970: 1000)
        var snapshot = ContentSnapshot()
        snapshot.profiles = CachedContent(value: [BotProfile(id: "research", displayName: "Research", summary: "", model: "", isGatewayRunning: true)], updatedAt: date)
        snapshot.conversations["research"] = ["s": CachedContent(value: [ChatMessage(id: "m", role: "assistant", text: "Saved answer")], updatedAt: date)]
        cache.save(snapshot, for: first)
        let reopened = ContentCache(directory: directory).load(first)
        XCTAssertEqual(reopened.profiles?.value.first?.id, "research")
        XCTAssertEqual(reopened.profiles?.updatedAt, date)
        XCTAssertEqual(reopened.conversations["research"]?["s"]?.value.first?.text, "Saved answer")
        XCTAssertNil(reopened.conversations["default"]?["s"])
        XCTAssertNil(cache.load(second).profiles)
        XCTAssertNil(cache.load(otherUser).profiles)
        cache.remove(first)
        XCTAssertNil(cache.load(first).profiles)
    }

    func testOfflineRestorationAllowsReadingButNotSendingAndRemovalClearsCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let key = "hermes.connection.settings.v1"
        let old = UserDefaults.standard.object(forKey: key)
        defer {
            if let old { UserDefaults.standard.set(old, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            try? FileManager.default.removeItem(at: directory)
        }
        let identity = CompanionConnection(relayURL: "https://relay.example", installationID: UUID().uuidString,
                                           deviceID: UUID().uuidString, hostPublicKey: Data(repeating: 4, count: 32).companionBase64)
        let settings = ConnectionSettings(address: identity.relayURL, companion: identity)
        let profile = BotProfile(id: "research", displayName: "Research", summary: "", model: "", isGatewayRunning: true)
        let session = HermesSession(id: "saved", title: "Saved conversation", preview: "", lastActive: .now, messageCount: 1, source: "cli")
        let cache = ContentCache(directory: directory)
        var snapshot = ContentSnapshot()
        snapshot.profiles = CachedContent(value: [profile], updatedAt: .now)
        snapshot.sessions[profile.id] = CachedContent(value: [session], updatedAt: .now)
        snapshot.conversations[profile.id] = [session.id: CachedContent(value: [ChatMessage(id: "m", role: "assistant", text: "Cached answer")], updatedAt: .now)]
        cache.save(snapshot, for: settings)
        UserDefaults.standard.set(try JSONEncoder().encode(settings), forKey: key)
        // No credentials for this unique pairing: restoration stops without contacting any host.
        let store = AppStore(contentCache: cache)
        await store.restoreConnection()
        XCTAssertEqual(store.phase, .disconnected)
        XCTAssertTrue(store.canBrowseCachedContent)
        XCTAssertEqual(store.profiles, [profile])
        await store.selectProfile(profile)
        XCTAssertEqual(store.sessions, [session])
        await store.openSession(session)
        XCTAssertEqual(store.messages.map(\.text), ["Cached answer"])
        XCTAssertFalse(store.sessionReady)
        let submitted = await store.send("Must not send")
        XCTAssertFalse(submitted)
        XCTAssertEqual(store.messages.count, 1)
        store.forgetSavedConnection()
        XCTAssertNil(cache.load(settings).profiles)
    }

    func testBackDuringInitialHistoryLoadClearsDestination() {
        let store = AppStore()
        store.selectedProfile = BotProfile(id: "default", displayName: "Hermes", summary: "", model: "", isGatewayRunning: true)
        store.selectedSession = HermesSession(id: "loading", title: "Loading", preview: "", lastActive: .now, messageCount: 1, source: "cli")
        store.isLoadingMessages = true
        store.backToSessions()
        XCTAssertNil(store.selectedSession)
        XCTAssertFalse(store.isLoadingMessages)
        XCTAssertNotNil(store.selectedProfile)
        store.isLoadingMessages = true
        store.backToBots()
        XCTAssertNil(store.selectedProfile)
        XCTAssertFalse(store.isLoadingMessages)
    }

    func testStatusUsesLastSuccessfulRefreshTime() {
        let date = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(ContentRefreshStatus(phase: .idle, updatedAt: date).text(now: date), "Updated just now")
        XCTAssertEqual(ContentRefreshStatus(phase: .unavailable, updatedAt: date).text(now: date.addingTimeInterval(1200)), "Offline · Updated 20m ago")
        XCTAssertEqual(ContentRefreshStatus(phase: .checking, updatedAt: date).text(), "Checking for latest data…")
    }
}
