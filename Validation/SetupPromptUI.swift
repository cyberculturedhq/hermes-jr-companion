import XCTest
final class SetupPromptUI: XCTestCase {
    func testUnavailableRemovalConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-recovery-unavailable"]
        app.launch()
        let remove = app.buttons["recovery.remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(remove.frame.midY, app.frame.height * 0.8)
        remove.tap()
        let dialog = app.alerts["Remove this saved connection?"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 3))
        XCTAssertTrue(dialog.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "This removes its sign-in details from this device.")).firstMatch.exists)
        XCTAssertTrue(dialog.buttons["Remove connection"].exists)
        dialog.buttons["Cancel"].tap()
        XCTAssertTrue(remove.exists)
    }

    func testRequiredRemovalHasNoCancel() {
        let app = XCUIApplication()
        for state in ["--preview-recovery-credentials-invalid", "--preview-recovery-pair-again"] {
            app.launchArguments = [state]
            app.launch()
            let remove = app.buttons["recovery.remove"]
            XCTAssertTrue(remove.waitForExistence(timeout: 10))
            remove.tap()
            let dialog = app.alerts["Remove this saved connection?"]
            XCTAssertTrue(dialog.waitForExistence(timeout: 3))
            XCTAssertTrue(dialog.buttons["Remove connection"].exists)
            XCTAssertFalse(dialog.buttons["Cancel"].exists)
            app.terminate()
        }
    }

    func testRestoringInsideBots() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-restoring"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Bots"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.otherElements["bots.restoring"].exists || app.staticTexts["Connecting to Hermes…"].exists)
        XCTAssertFalse(app.staticTexts["No Bots"].exists)
        XCTAssertFalse(app.buttons["Settings"].isEnabled)
        XCTAssertFalse(app.buttons["bots.cancelRestoration"].exists)
        XCTAssertFalse(app.buttons["Cancel"].exists)
    }

    func testAddressSignInMethods() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-address"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Use a dashboard address"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["Username"].exists)
        XCTAssertTrue(app.secureTextFields["Password"].exists)
        let methods = app.segmentedControls["connection.signInMethod"]
        methods.buttons["Access token"].tap()
        XCTAssertTrue(app.secureTextFields["Access token"].exists)
        XCTAssertFalse(app.textFields["Username"].exists)
        XCTAssertFalse(app.secureTextFields["Password"].exists)
        methods.buttons["Username and password"].tap()
        XCTAssertTrue(app.textFields["Username"].exists)
        XCTAssertFalse(app.secureTextFields["Access token"].exists)
    }

    func testConfirmedConnection() {
        let app = XCUIApplication()
        for multiple in [false, true] {
            app.launchArguments = [multiple ? "--preview-multiple" : "--preview-pairing-card"]
            app.launch()
            let confirm = app.buttons["connection.confirmCodes"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 10))
            if multiple {
                app.buttons.containing(.staticText, identifier: "Hermes preview").firstMatch.tap()
                app.swipeUp()
            }
            confirm.tap()
            expectation(for: NSPredicate(format: "label == %@", "Connecting to Hermes…"), evaluatedWith: confirm)
            waitForExpectations(timeout: 3)
            XCTAssertTrue(app.staticTexts["Your Hermes Agent is ready to open."].waitForExistence(timeout: 20))
            XCTAssertTrue(app.buttons["connection.finish"].exists)
            app.terminate()
        }
    }

    func testCopyAndShare() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview-install"]
        app.launch()
        let copy = app.buttons["connection.copyDevicePrompt"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        copy.tap()
        XCTAssertTrue(copy.label.contains("Creating setup prompt…"))
        expectation(for: NSPredicate(format: "label CONTAINS %@", "Copied"), evaluatedWith: copy)
        waitForExpectations(timeout: 3)
        expectation(for: NSPredicate(format: "label CONTAINS %@", "Taking you to next step"), evaluatedWith: copy)
        waitForExpectations(timeout: 3)
        let handoff = app.staticTexts["Give prompt to Hermes"]
        XCTAssertTrue(handoff.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["After you send the prompt to Hermes, continue here."].exists)
        app.buttons["connection.back"].tap()
        app.buttons["Share setup prompt"].tap()
        let sheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 15))
        close.tap()
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        XCTAssertFalse(handoff.exists)
        app.buttons["Share setup prompt"].tap()
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        let shareCopy = sheet.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Copy")).firstMatch
        XCTAssertTrue(shareCopy.waitForExistence(timeout: 15), app.debugDescription)
        shareCopy.tap()
        // Poll frequently enough to observe the brief feedback after native dismissal.
        let advancing = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Taking you to next step")).firstMatch
        let deadline = Date().addingTimeInterval(4)
        var sawAdvancing = false
        while Date() < deadline {
            if advancing.exists { sawAdvancing = true; break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(sawAdvancing)
        XCTAssertTrue(handoff.waitForExistence(timeout: 5))
        app.buttons["connection.startWaiting"].tap()
        XCTAssertTrue(app.buttons["connection.confirmCodes"].waitForExistence(timeout: 8))
    }
}
