import XCTest

final class NotificationNavigationUI: XCTestCase {
    private func control(_ body: [String: Bool]) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:19129/control")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await URLSession.shared.data(for: request)
    }

    @MainActor
    func testColdTapShowsChatWhileHistoryIsHeldForFiveSeconds() async throws {
        continueAfterFailure = false
        try await control(["reset": true, "hold_lookup": true])
        let app = XCUIApplication()
        app.launch()
        let opening = app.descendants(matching: .any)["notification.opening"]
        XCTAssertTrue(opening.waitForExistence(timeout: 15))
        let start = Date()
        try await control(["release_lookup": true])
        XCTAssertTrue(app.textFields["chat.composer"].waitForExistence(timeout: 4))
        print("Notification route visible after reference release: \(Date().timeIntervalSince(start)) seconds")
        XCTAssertTrue(app.navigationBars.staticTexts["Research"].exists)
        XCTAssertFalse(app.navigationBars["Bots"].exists)
        XCTAssertFalse(app.tabBars.element.exists)
        let loadingStatus = app.staticTexts["chat.headerStatus"]
        XCTAssertTrue(loadingStatus.waitForExistence(timeout: 3))
        XCTAssertEqual(loadingStatus.label, "Checking for latest data…")
        let pending = XCTAttachment(screenshot: app.screenshot())
        pending.name = "Target chat before history arrives"; pending.lifetime = .keepAlways; add(pending)
        try await Task.sleep(for: .seconds(5))
        XCTAssertEqual(loadingStatus.label, "Checking for latest data…")
        XCTAssertFalse(app.staticTexts["Reply from research"].exists)
        XCTAssertFalse(app.navigationBars["Bots"].exists)
        try await control(["release_history": true])
        XCTAssertTrue(app.staticTexts["Reply from research"].waitForExistence(timeout: 8))
        XCTAssertNotEqual(loadingStatus.label, "Checking for latest data…")
        let loaded = XCTAttachment(screenshot: app.screenshot())
        loaded.name = "Notification conversation loaded"; loaded.lifetime = .keepAlways; add(loaded)
        app.terminate()
    }
}
