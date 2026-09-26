import XCTest
final class PairingUI: XCTestCase {
    func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIApplication().screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testAddressKeyboard() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["connection.chooseAddress"].waitForExistence(timeout: 10))
        app.buttons["connection.chooseAddress"].tap()
        let address = app.textFields["connection.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        capture("Combined connection fields")
        address.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        address.typeText("https://example.com")
        XCTAssertEqual(address.value as? String, "https://example.com")
        capture("Address software keyboard")
        app.textFields["Username"].tap()
        app.textFields["Username"].typeText("preview")
        XCTAssertEqual(app.textFields["Username"].value as? String, "preview")
        app.secureTextFields["Password"].tap()
        app.secureTextFields["Password"].typeText("preview-password")
        capture("Password software keyboard")
    }
    func testAddressAlignment() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["connection.chooseCompanion"].waitForExistence(timeout: 10))
        let welcomeY = app.staticTexts["Your Hermes, on your phone"].frame.minY
        let welcomeX = app.staticTexts["Your Hermes, on your phone"].frame.minX
        app.buttons["connection.chooseCompanion"].tap()
        XCTAssertTrue(app.buttons["connection.copyDevicePrompt"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.5)
        let headerY = app.buttons["connection.back"].frame.minY
        XCTAssertFalse(app.staticTexts["Connect Hermes"].exists)
        capture("Install header baseline")
        app.buttons["connection.back"].tap()
        app.buttons["connection.chooseAddress"].tap()
        XCTAssertTrue(app.textFields["connection.address"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(app.buttons["connection.back"].frame.minY, headerY, accuracy: 1)
        XCTAssertFalse(app.staticTexts["Connect Hermes"].exists)
        XCTAssertEqual(app.staticTexts["Connect with an address"].frame.minY, welcomeY, accuracy: 2)
        XCTAssertEqual(app.staticTexts["Connect with an address"].frame.minX, welcomeX, accuracy: 1)
        capture("Address aligned")
        app.swipeUp()
        let connect = app.buttons["connection.connect"]
        XCTAssertTrue(connect.isHittable)
        XCTAssertLessThan(connect.frame.maxY, app.frame.maxY - 20)
        capture("Address bottom after scroll")
    }
    func testPreviewLayout() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["connection.chooseCompanion"].waitForExistence(timeout: 10))
        capture("Welcome bottom actions")
        app.buttons["connection.chooseCompanion"].tap()
        XCTAssertTrue(app.buttons["connection.copyDevicePrompt"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["connection.startWaiting"].exists)
        capture("Install before copy")
        let copy = app.buttons["connection.copyDevicePrompt"]
        let originalSize = copy.frame.size
        copy.tap()
        XCTAssertEqual(copy.frame.width, originalSize.width, accuracy: 1)
        XCTAssertEqual(copy.frame.height, originalSize.height, accuracy: 1)
        let nextStep = app.buttons["connection.startWaiting"]
        XCTAssertTrue(nextStep.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Give prompt to Hermes"].exists)
        capture("Give prompt to Hermes")
        nextStep.tap()
        capture("Waiting centered spinner")
        XCTAssertTrue(app.buttons["connection.confirmCodes"].waitForExistence(timeout: 7))
        Thread.sleep(forTimeInterval: 4)
        XCTAssertFalse(app.staticTexts["You’re connected"].exists)
        XCTAssertEqual(app.buttons["connection.rejectCodes"].frame.width, app.buttons["connection.confirmCodes"].frame.width, accuracy: 1)
        XCTAssertFalse(app.staticTexts["Check that all three groups match."].exists)
        app.buttons["connection.cancelSetup"].tap()
        XCTAssertTrue(app.alerts["Cancel setup?"].waitForExistence(timeout: 3))
        app.alerts.buttons["Keep setting up"].tap()
        XCTAssertTrue(app.buttons["connection.confirmCodes"].exists)
        capture("Pairing code awaits confirmation")
        app.buttons["connection.confirmCodes"].tap()
        XCTAssertTrue(app.staticTexts["You’re connected"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 8)
        XCTAssertTrue(app.buttons["connection.finish"].exists)
        XCTAssertFalse(app.navigationBars["Bots"].exists)
        capture("Success stays open")
    }
}
