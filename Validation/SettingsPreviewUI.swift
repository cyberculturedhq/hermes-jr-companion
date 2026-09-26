import XCTest

final class SettingsPreviewUI: XCTestCase {
    func openSettings(failing: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-connected"] + (failing ? ["--preview-notification-failure"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.switches["Notify me"].waitForExistence(timeout: 5))
        return app
    }

    func testImmediateToggleAndConnectionDetails() {
        let app = openSettings()
        XCTAssertTrue(app.staticTexts["Connected to Hermes"].exists)
        app.buttons["Connection details"].coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "hermes-preview.example.com")).firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Encrypted")).firstMatch.exists)
        let toggle = app.switches["Notify me"]
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(toggle.isEnabled)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        Thread.sleep(forTimeInterval: 5)
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Settings with preview connection"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testFailureInSettingsCanCancelAndRetry() {
        let app = openSettings(failing: true)
        let toggle = app.switches["Notify me"]
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        let alert = app.alerts["Couldn’t Update Notifications"]
        XCTAssertTrue(alert.waitForExistence(timeout: 6))
        alert.buttons["Cancel"].tap()
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 6))
        alert.buttons["Retry"].tap()
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(alert.waitForExistence(timeout: 6))
        alert.buttons["Cancel"].tap()
        XCTAssertEqual(toggle.value as? String, "0")
    }

    func testFailureAfterLeavingSettingsOffersReturn() {
        let app = openSettings(failing: true)
        app.switches["Notify me"].coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        app.buttons["Done"].tap()
        let alert = app.alerts["Couldn’t Update Notifications"]
        XCTAssertTrue(alert.waitForExistence(timeout: 6))
        XCTAssertTrue(alert.buttons["Retry"].exists)
        XCTAssertTrue(alert.buttons["Cancel"].exists)
        alert.buttons["Open Settings"].tap()
        XCTAssertTrue(app.switches["Notify me"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["Notify me"].value as? String, "0")
    }
}
