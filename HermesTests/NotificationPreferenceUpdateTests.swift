import XCTest
@testable import Hermes

@MainActor
final class NotificationPreferenceUpdateTests: XCTestCase {
    private final class Server {
        var calls: [Bool] = []
        var replies: [CheckedContinuation<String?, Never>] = []
        func apply(_ value: Bool) async -> String? {
            calls.append(value)
            return await withCheckedContinuation { replies.append($0) }
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Update did not settle")
    }

    func testImmediateChoiceAndRollbackAfterFailure() async {
        let update = NotificationPreferenceUpdate()
        let server = Server()
        update.request(true) { await server.apply($0) }
        XCTAssertEqual(update.requestedValue, true)
        XCTAssertTrue(update.isSaving)
        await waitUntil { server.replies.count == 1 }
        server.replies.removeFirst().resume(returning: "Offline")
        await waitUntil { !update.isSaving }
        XCTAssertNil(update.requestedValue, "Fall back to the store's confirmed value")
        XCTAssertEqual(update.failure?.requestedValue, true)
        XCTAssertEqual(update.failure?.message, "Offline")
    }

    func testRapidChangesAreSerializedAndStaleFailureIsIgnored() async {
        let update = NotificationPreferenceUpdate()
        let server = Server()
        update.request(true) { await server.apply($0) }
        await waitUntil { server.replies.count == 1 }
        update.request(false) { await server.apply($0) }
        XCTAssertEqual(update.requestedValue, false)
        XCTAssertEqual(server.calls, [true])
        server.replies.removeFirst().resume(returning: "Old request failed")
        await waitUntil { server.calls.count == 2 && !server.replies.isEmpty }
        XCTAssertEqual(server.calls, [true, false])
        XCTAssertNil(update.failure)
        XCTAssertEqual(update.requestedValue, false)
        server.replies.removeFirst().resume(returning: nil)
        await waitUntil { !update.isSaving }
        XCTAssertNil(update.requestedValue)
        XCTAssertNil(update.failure)
    }

    func testResetDiscardsAnOldConnectionResponse() async {
        let update = NotificationPreferenceUpdate()
        let server = Server()
        update.request(true) { await server.apply($0) }
        await waitUntil { server.replies.count == 1 }
        update.reset()
        update.request(false) { await server.apply($0) }
        await waitUntil { server.calls.count == 2 && !server.replies.isEmpty }
        server.replies.removeFirst().resume(returning: "Old connection failed")
        await Task.yield()
        XCTAssertEqual(update.requestedValue, false)
        XCTAssertTrue(update.isSaving)
        XCTAssertNil(update.failure)
        server.replies.removeFirst().resume(returning: nil)
        await waitUntil { !update.isSaving }
        XCTAssertNil(update.failure)
    }

    func testRetryClearsFailureAndSavesAgain() async {
        let update = NotificationPreferenceUpdate()
        update.request(true) { _ in "Offline" }
        await waitUntil { !update.isSaving }
        let desired = update.failure!.requestedValue
        update.request(desired) { _ in nil }
        XCTAssertNil(update.failure)
        XCTAssertEqual(update.requestedValue, true)
        await waitUntil { !update.isSaving }
        XCTAssertNil(update.failure)
    }
}
