import XCTest

final class PairingCardPreviewUI: XCTestCase {
    func testInlineCardAndBothChoices() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-pairing-card"]
        app.launch()
        let confirm = app.buttons["connection.confirmCodes"]
        let reject = app.buttons["connection.rejectCodes"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["Hermes is ready"].exists)
        XCTAssertTrue(app.staticTexts["Hermes preview"].exists)
        XCTAssertTrue(app.buttons["connection.cancelSetup"].isHittable)
        let code = app.staticTexts["Pairing code 123 456 789"]
        XCTAssertTrue(code.exists)
        XCTAssertEqual(code.frame.midX, app.frame.midX, accuracy: 2)
        XCTAssertEqual(confirm.frame.width, reject.frame.width, accuracy: 1)
        XCTAssertTrue(confirm.isHittable)
        XCTAssertTrue(reject.isHittable)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Inline pairing confirmation"
        capture.lifetime = .keepAlways
        add(capture)
        reject.tap()
        XCTAssertTrue(app.buttons["connection.copyDevicePrompt"].waitForExistence(timeout: 5))
        XCTAssertFalse(confirm.exists)
        app.buttons["connection.copyDevicePrompt"].tap()
        XCTAssertTrue(app.buttons["connection.startWaiting"].waitForExistence(timeout: 5))
        app.buttons["connection.startWaiting"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 7))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["You’re connected"].waitForExistence(timeout: 5))
        XCTAssertFalse(reject.exists)
    }
}
