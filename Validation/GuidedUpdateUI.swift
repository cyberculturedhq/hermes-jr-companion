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
}
