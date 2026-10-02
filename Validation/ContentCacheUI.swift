import XCTest

final class ContentCacheUI: XCTestCase {
    func testActiveSessionListKeepsOtherChatsEnabledAndShowsActivityThenPrompt() {
        let app = XCUIApplication(); app.launchArguments = ["cache-sessions-active"]; app.launch()
        XCTAssertTrue(app.staticTexts["Thinking…"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["session.older"].isEnabled)
        XCTAssertTrue(app.buttons["sessions.new"].isEnabled)
        app.buttons["fixture.refresh"].tap()
        XCTAssertTrue(app.staticTexts["Writing…"].waitForExistence(timeout: 5))
        app.buttons["fixture.refresh"].tap()
        XCTAssertTrue(app.staticTexts["Please research this topic"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["No messages"].exists)
    }

    func testHandoffOffersExplicitChoiceAndCancelPreservesConversation() {
        for mode in ["cache-handoff", "cache-handoff-confirm"] {
            let app = XCUIApplication(); app.launchArguments = [mode]; app.launch()
            let alert = app.alerts.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 15))
            XCTAssertTrue(alert.staticTexts["Move session here?"].exists)
            XCTAssertFalse(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Details: session")).firstMatch.exists)
            if mode == "cache-handoff" {
                XCTAssertTrue(alert.buttons["Continue on iPhone…"].exists)
                XCTAssertFalse(alert.buttons["Close CLI and Continue"].exists)
            } else {
                XCTAssertTrue(alert.buttons["Close CLI and Continue"].exists)
                XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "interrupt any reply")).firstMatch.exists)
            }
            alert.buttons["Cancel"].tap()
            XCTAssertFalse(alert.exists)
            XCTAssertTrue(app.staticTexts["Your saved conversation stays here."].exists)
        }
    }

    func testAnimatedSendsSettleWithoutMovingExistingMessages() {
        let app = XCUIApplication(); app.launchArguments = ["cache-send-animation"]; app.launch()
        let field = app.textFields["chat.composer"]
        XCTAssertTrue(field.waitForExistence(timeout: 15)); field.tap()
        let trigger = app.buttons["fixture.refresh"]
        trigger.tap()
        XCTAssertTrue(app.staticTexts["Delivered"].waitForExistence(timeout: 5))
        let messages = app.staticTexts.matching(identifier: "You: Animated message")
        XCTAssertEqual(messages.count, 1)
        let originalY = messages.element(boundBy: 0).frame.minY
        trigger.tap()
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(app.staticTexts["Delivered"].waitForExistence(timeout: 5))
        XCTAssertEqual(messages.element(boundBy: 0).frame.minY, originalY, accuracy: 1)
        XCTAssertTrue(field.isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Settled outgoing animation"; shot.lifetime = .keepAlways; add(shot)
    }

    func testComposerAndDeliveryLabels() {
        let app = XCUIApplication(); app.launchArguments = ["cache-receipts"]; app.launch()
        XCTAssertTrue(app.staticTexts["Sending…"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["chat.timestamp"].exists)
        app.buttons["fixture.refresh"].tap()
        XCTAssertTrue(app.staticTexts["Delivered"].waitForExistence(timeout: 5))
        let field = app.textFields["chat.composer"]
        field.tap(); field.typeText("Test")
        let plus = app.buttons["chat.add"]
        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.isHittable)
        XCTAssertEqual(plus.frame.midY, send.frame.midY, accuracy: 1)
        XCTAssertEqual(send.frame.width, 50, accuracy: 1)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Composer and delivery labels"; shot.lifetime = .keepAlways; add(shot)
        field.typeText("\nSecond line\nThird line")
        XCTAssertEqual(plus.frame.midY, send.frame.midY, accuracy: 1)
        XCTAssertGreaterThan(send.frame.midY, field.frame.midY)
    }

    func testActivityAppearsInHeaderThenReturnsToConversationTitle() {
        let app = XCUIApplication(); app.launchArguments = ["cache-activity"]; app.launch()
        let next = app.buttons["fixture.refresh"]
        XCTAssertTrue(next.waitForExistence(timeout: 15))
        for label in ["Thinking…", "Using terminal", "Writing…", "Updated just now"] {
            next.tap()
            let header = app.staticTexts["chat.headerStatus"]
            let expected = NSPredicate(format: "label == %@", label)
            expectation(for: expected, evaluatedWith: header)
            waitForExpectations(timeout: 5)
            XCTAssertFalse(app.descendants(matching: .any)["chat.typing"].exists)
        }
        XCTAssertTrue(app.staticTexts["Research notes"].waitForExistence(timeout: 6))
    }

    func testCachedScreensRemainVisibleDuringRefresh() {
        for mode in ["cache-profiles", "cache-sessions", "cache-conversation"] {
            let app = XCUIApplication(); app.launchArguments = [mode]; app.launch()
            let content: XCUIElement
            switch mode {
            case "cache-profiles": content = app.buttons["profile.research"]
            case "cache-sessions": content = app.buttons["session.saved"]
            default: content = app.textFields["chat.composer"]
            }
            XCTAssertTrue(content.waitForExistence(timeout: 15), mode)
            XCTAssertEqual(app.progressIndicators.count, 0, mode)
            let before = XCTAttachment(screenshot: app.screenshot()); before.name = mode + " refreshing"; before.lifetime = .keepAlways; add(before)
            app.buttons["fixture.refresh"].tap()
            XCTAssertTrue(app.staticTexts["Updated just now"].waitForExistence(timeout: 5), mode)
            XCTAssertTrue(content.exists)
            let after = XCTAttachment(screenshot: app.screenshot()); after.name = mode + " updated"; after.lifetime = .keepAlways; add(after)
            if mode == "cache-conversation" {
                let restored = app.staticTexts["Research notes"]
                XCTAssertTrue(restored.waitForExistence(timeout: 6))
                XCTAssertFalse(app.staticTexts["Updated just now"].exists)
            }
            app.terminate()
        }
    }
}
