import XCTest
@testable import Hermes

@MainActor
final class ContentCacheTests: XCTestCase {
    func testExistingProfileCacheStillDecodesWithoutBotMetadata() throws {
        let data = Data(#"{"id":"research","displayName":"Research","summary":"Profile description","model":"test","isGatewayRunning":true}"#.utf8)
        let profile = try JSONDecoder().decode(BotProfile.self, from: data)
        XCTAssertEqual(profile.summary, "Profile description")
        XCTAssertNil(profile.botSession)
    }

    func testTranscriptWindowMovesThroughLoadedHistoryWithoutRenderingEveryRow() {
        let store = AppStore()
        store.messages = (0..<230).map { ChatMessage(id: "\($0)", role: "assistant", text: "Message \($0)") }
        XCTAssertEqual(store.visibleWindowMessages.count, 40)
        XCTAssertEqual(store.visibleWindowMessages.first?.id, "0")
        XCTAssertEqual(store.visibleWindowMessages.last?.id, "39")
        XCTAssertTrue(store.hasNewerLoadedMessages)
        XCTAssertEqual(store.showNewerLoadedMessages(), "39")
        XCTAssertEqual(store.visibleWindowMessages.first?.id, "30")
        XCTAssertEqual(store.visibleWindowMessages.last?.id, "69")
        XCTAssertTrue(store.hasNewerLoadedMessages)
        XCTAssertEqual(store.showNewerLoadedMessages(), "69")
        XCTAssertEqual(store.visibleWindowMessages.first?.id, "60")
        XCTAssertEqual(store.showEarlierLoadedMessages(), "60")
        XCTAssertEqual(store.visibleWindowMessages.first?.id, "30")
        XCTAssertEqual(store.showEarlierLoadedMessages(), "30")
        XCTAssertEqual(store.visibleWindowMessages.first?.id, "0")
    }

    func testUnreadBoundarySurvivesRelaunchUntilEarlierMessagesAreSeen() {
        let address = "https://unread-boundary-\(UUID().uuidString).example"
        defer { UserDefaults.standard.removeObject(forKey: "notifications/" + address + "/conversation-read-state.v1") }
        let profile = BotProfile(id: "research", displayName: "Research", summary: "", model: "", isGatewayRunning: true)
        let session = HermesSession(id: "saved", title: "Saved", preview: "", lastActive: .now, messageCount: 1, source: "cli")
        let store = AppStore()
        store.settings = ConnectionSettings(address: address)
        store.selectedProfile = profile
        store.selectedSession = session
        store.messages = [ChatMessage(id: "last-seen", role: "assistant", text: "Seen")]
        store.markSessionRead(session.id, profile: profile.id)
        store.noteAssistantReply(profile: profile.id, sessionID: session.id)
        XCTAssertEqual(store.unreadBoundary(profile: profile.id, sessionID: session.id), "last-seen")

        let reopened = AppStore()
        reopened.settings = ConnectionSettings(address: address)
        XCTAssertTrue(reopened.isSessionUnread(session.id, profile: profile.id))
        XCTAssertEqual(reopened.unreadBoundary(profile: profile.id, sessionID: session.id), "last-seen")
        reopened.selectedProfile = profile
        reopened.selectedSession = session
        reopened.messages = [ChatMessage(id: "new-reply", role: "assistant", text: "New")]
        reopened.markSessionRead(session.id, profile: profile.id)
        XCTAssertFalse(reopened.isSessionUnread(session.id, profile: profile.id))
    }

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

    func testConversationCacheKeepsLatestRowsWithoutRuntimeOrPhotoData() {
        let photo = DraftPhoto(data: Data([1, 2, 3]), filename: "photo.jpg")
        let rows = (0..<230).map {
            ChatMessage(id: "\($0)", role: "assistant", text: "Message \($0)", isStreaming: true, photos: [photo])
        }
        let cached = ContentCache.conversationRows(rows)
        XCTAssertEqual(cached.count, 200)
        XCTAssertEqual(cached.first?.id, "30")
        XCTAssertEqual(cached.last?.id, "229")
        XCTAssertTrue(cached.allSatisfy { !$0.isStreaming && $0.photos.isEmpty })
        XCTAssertTrue(rows.allSatisfy { $0.isStreaming && $0.photos == [photo] })
    }

    func testConversationCacheEnforcesEncodedByteLimit() throws {
        let rows = (0..<200).map {
            ChatMessage(id: "\($0)", role: "assistant", text: String(repeating: "\"é\n", count: 20_000))
        }
        let cached = ContentCache.conversationRows(rows)
        XCTAssertFalse(cached.isEmpty)
        XCTAssertLessThan(cached.count, rows.count)
        XCTAssertEqual(cached, Array(rows.suffix(cached.count)))
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(cached).count, 750_000)
        XCTAssertGreaterThan(try JSONEncoder().encode(Array(rows.suffix(cached.count + 1))).count, 750_000)
    }

    func testConversationCacheAcceptsExactByteLimitAndRejectsOversizedLatestRow() throws {
        var row = ChatMessage(id: "latest", role: "assistant", text: "")
        let overhead = try JSONEncoder().encode([row]).count
        row.text = String(repeating: "x", count: 750_000 - overhead)
        XCTAssertEqual(try JSONEncoder().encode([row]).count, 750_000)
        XCTAssertEqual(ContentCache.conversationRows([row]), [row])
        row.text.append("x")
        XCTAssertTrue(ContentCache.conversationRows([ChatMessage(id: "older", role: "user", text: "Keep reading order"), row]).isEmpty)
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

    func testLeavingConversationClearsHistoryPagination() async {
        let profile = BotProfile(id: "research", displayName: "Research", summary: "", model: "", isGatewayRunning: true)
        for destination in ["sessions", "bots", "profile"] {
            let store = AppStore()
            store.selectedProfile = profile
            store.selectedSession = HermesSession(id: "old", title: "Old", preview: "", lastActive: .now, messageCount: 80, source: "cli")
            store.messages = (0..<80).map { ChatMessage(id: "\($0)", role: "assistant", text: "Message \($0)") }
            store.messageWindowStart = 40
            store.hasOlderMessages = true
            store.isLoadingOlderMessages = true
            switch destination {
            case "sessions": store.backToSessions()
            case "bots": store.backToBots()
            default: await store.selectProfile(profile, refresh: false)
            }
            XCTAssertEqual(store.messageWindowStart, 0, destination)
            XCTAssertFalse(store.hasOlderMessages, destination)
            XCTAssertFalse(store.isLoadingOlderMessages, destination)
            store.messages = [ChatMessage(id: "new", role: "user", text: "New conversation")]
            XCTAssertEqual(store.visibleWindowMessages.map(\.id), ["new"], destination)
        }
    }

    func testCanceledProfileSelectionDoesNotReplaceDestination() async {
        let store = AppStore()
        let profile = BotProfile(id: "research", displayName: "Research", summary: "", model: "", isGatewayRunning: true)
        let current = BotProfile(id: "current", displayName: "Current", summary: "", model: "", isGatewayRunning: true)
        store.selectedProfile = current
        store.isLoadingOlderMessages = true
        let selection = Task { await store.selectProfile(profile, refresh: false) }
        selection.cancel()
        await selection.value
        XCTAssertEqual(store.selectedProfile, current)
        XCTAssertTrue(store.isLoadingOlderMessages, "A canceled selection must not invalidate the current history load.")
    }

    func testStatusUsesLastSuccessfulRefreshTime() {
        let date = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(ContentRefreshStatus(phase: .idle, updatedAt: date).text(now: date), "Updated just now")
        XCTAssertEqual(ContentRefreshStatus(phase: .unavailable, updatedAt: date).text(now: date.addingTimeInterval(1200)), "Offline · Updated 20m ago")
        XCTAssertEqual(ContentRefreshStatus(phase: .checking, updatedAt: date).text(), "Checking for latest data…")
    }
}
