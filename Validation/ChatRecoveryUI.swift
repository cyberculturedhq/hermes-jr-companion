import XCTest

final class ChatRecoveryUI: XCTestCase {
    func testFirstMessageStaysAtTopWithKeyboard() {
        let app = XCUIApplication(); app.launchArguments = ["short-chat"]; app.launch()
        let field = app.textFields["chat.composer"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let restingY = app.staticTexts["You: Sup"].frame.minY
        app.buttons["fixture.stream"].tap()
        let message = app.staticTexts["You: Sup"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        let top = max(app.scrollViews["chat.transcript"].frame.minY, app.navigationBars.firstMatch.frame.maxY)
        XCTAssertEqual(message.frame.minY, restingY, accuracy: 1)
        XCTAssertLessThan(message.frame.minY - top, 60)
        let settled = expectation(description: "Layout settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { settled.fulfill() }
        wait(for: [settled], timeout: 4)
        XCTAssertEqual(message.frame.minY, restingY, accuracy: 1)
        XCTAssertLessThan(message.frame.minY - top, 60)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "First message top spacing"; shot.lifetime = .keepAlways; add(shot)
    }

    func testStreamingFollowsBottomAndCentersStop() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.textFields["chat.composer"].waitForExistence(timeout: 15))
        app.buttons["fixture.stream"].tap()
        let end = app.staticTexts["STREAM END"]
        XCTAssertTrue(end.waitForExistence(timeout: 8))
        XCTAssertTrue(end.isHittable)
        let stop = app.buttons["chat.stop"]
        XCTAssertTrue(stop.isHittable)
        XCTAssertEqual(stop.frame.midY, app.textFields["chat.composer"].frame.midY, accuracy: 2)
    }

    func testFloatingComposerWithoutKeyboard() {
        let app = XCUIApplication()
        app.launch()
        let field = app.textFields["chat.composer"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        let scroll = app.scrollViews["chat.transcript"]
        scroll.swipeDown()
        XCTAssertTrue(field.isHittable)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Floating composer in dark mode"; shot.lifetime = .keepAlways
        add(shot)
    }

    func testComposerRemainsVisibleAcrossRefreshAndScroll() {
        let app = XCUIApplication()
        app.launch()
        let field = app.textFields["chat.composer"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText("Draft stays here")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["fixture.refresh"].tap()
        XCTAssertFalse(app.staticTexts["Loading conversation…"].exists)
        XCTAssertTrue(field.isHittable)
        // Scroll into older history without dragging the keyboard dismissal edge.
        let scroll = app.scrollViews["chat.transcript"]
        XCTAssertTrue(scroll.exists)
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        start.press(forDuration: 0.05, thenDragTo: end)
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(field.isHittable)
        XCTAssertEqual(field.value as? String, "Draft stays here")
        let latest = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Message 39.")).firstMatch
        XCTAssertFalse(latest.isHittable, "The gesture must actually reveal older messages")
        if app.keyboards.firstMatch.exists {
            XCTAssertLessThanOrEqual(field.frame.maxY, app.keyboards.firstMatch.frame.minY)
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Composer after refresh and scroll"; shot.lifetime = .keepAlways
        add(shot)
    }
}
