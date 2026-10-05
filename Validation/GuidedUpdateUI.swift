import XCTest
final class GuidedUpdateUI: XCTestCase {
    @MainActor func testUpdateSheetAndDefaultConversation() async throws {
        continueAfterFailure = false
        var request = URLRequest(url: URL(string: "http://127.0.0.1:19129/control")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["reset":true,"updates":true,"tracked":false,"hold_history":false])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await URLSession.shared.data(for: request)
        let app = XCUIApplication(); app.launch()
        let update = app.buttons.containing(.staticText, identifier: "Companion update available").firstMatch
        XCTAssertTrue(update.waitForExistence(timeout: 20)); update.tap()
        XCTAssertTrue(app.buttons["companion.update-with-hermes"].waitForExistence(timeout: 5))
        let sheet = XCTAttachment(screenshot: app.screenshot()); sheet.name = "Update choices and model allowance"; sheet.lifetime = .keepAlways; add(sheet)
        app.buttons["companion.update-with-hermes"].tap()
        XCTAssertTrue(app.textFields["chat.composer"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.navigationBars.staticTexts["Default"].exists)
        let chat = XCTAttachment(screenshot: app.screenshot()); chat.name = "Dedicated default-profile update conversation"; chat.lifetime = .keepAlways; add(chat)
        app.terminate()
    }

    @MainActor func testFailedUpdateOffersInlineRetryAndKeepsPromptReadable() async throws {
        continueAfterFailure = false
        func control(_ body: [String: Any]) async throws -> [String: Any] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:19129/control")!)
            request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, _) = try await URLSession.shared.data(for: request)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        _ = try await control(["reset": true, "updates": true, "tracked": false, "hold_history": false,
                               "turn_status": "error"])
        let app = XCUIApplication(); app.launch()
        let update = app.buttons.containing(.staticText, identifier: "Companion update available").firstMatch
        XCTAssertTrue(update.waitForExistence(timeout: 20)); update.tap()
        app.buttons["companion.update-with-hermes"].tap()
        let hasRetry = app.buttons["companion.update-retry"].waitForExistence(timeout: 15)
        let recovery = XCTAttachment(screenshot: app.screenshot())
        recovery.name = "Nonblocking failed update with Try again"; recovery.lifetime = .keepAlways; add(recovery)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Recovery accessibility hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        XCTAssertTrue(hasRetry)
        XCTAssertFalse(app.alerts["Unable to Continue"].exists)
        XCTAssertTrue(app.textFields["chat.composer"].exists)
        _ = try await control(["turn_status": "complete"])
        app.buttons["companion.update-retry"].tap()
        var stats = try await control([:])
        for _ in 0..<100 {
            if stats["prompts"] as? Int == 2 { break }
            try await Task.sleep(for: .milliseconds(50)); stats = try await control([:])
        }
        XCTAssertEqual(stats["creates"] as? Int, 1)
        XCTAssertEqual(stats["prompts"] as? Int, 2)
        app.terminate()
    }
}
