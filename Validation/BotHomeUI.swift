import XCTest

@MainActor final class BotHomeUI: XCTestCase {
    override func setUp() async throws {
        try await configureBot()
    }

    func testProfileSessionSearchStaysAtTheBottomThroughCloseAndBack() {
        continueAfterFailure = false
        let app = XCUIApplication()
        for fromHomeSearch in [false, true] {
            app.launch()
            XCTAssertTrue(app.buttons["profile.research"].waitForExistence(timeout: 15))
            if fromHomeSearch {
                app.tabBars.buttons["Search"].tap()
                let homeSearch = app.searchFields["Search Profiles"]
                XCTAssertTrue(homeSearch.waitForExistence(timeout: 5))
                homeSearch.typeText("Research profile")
            }
            app.buttons["profile.research"].tap()
            XCTAssertTrue(app.buttons["session.saved-0"].waitForExistence(timeout: 10))
            let search = app.searchFields["Search"]
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            XCTAssertEqual(app.searchFields.count, 1)
            XCTAssertGreaterThan(search.frame.minY, app.frame.height * 0.7)
            XCTAssertFalse(app.tabBars.element.exists)
            XCTAssertTrue(app.buttons["sessions.new"].isHittable)
            saveScreenshot(app, name: "Profile sessions with bottom Search, home search: \(fromHomeSearch)")

            search.tap()
            search.typeText("Session 0")
            XCTAssertTrue(app.buttons["session.saved-0"].exists)
            XCTAssertFalse(app.buttons["session.saved-1"].exists)
            let close = app.buttons["close"]
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            close.tap()
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            XCTAssertGreaterThan(search.frame.minY, app.frame.height * 0.7)
            XCTAssertTrue(app.buttons["session.saved-1"].exists)
            saveScreenshot(app, name: "Profile sessions after closing Search")

            search.tap()
            search.typeText("Session 0")
            app.buttons["session.saved-0"].tap()
            XCTAssertTrue(app.staticTexts["You: Message 500"].waitForExistence(timeout: 10))
            XCTAssertFalse(search.exists)
            XCTAssertTrue(app.textFields["chat.composer"].isHittable)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons["session.saved-0"].waitForExistence(timeout: 5))
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            XCTAssertGreaterThan(search.frame.minY, app.frame.height * 0.7)
            saveScreenshot(app, name: "Profile sessions after Back from a conversation")
            if close.exists { close.tap() }
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons["profile.research"].waitForExistence(timeout: 5))
            XCTAssertFalse(search.exists)
            XCTAssertFalse(app.searchFields["Search Profiles"].exists)
            app.terminate()
        }
    }

    func testClosingSearchRestoresTheListWithoutAHeaderSearchField() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["profile.research"].waitForExistence(timeout: 15))

        for mode in ["Profiles", "Bots"] {
            app.tabBars.buttons[mode].tap()
            for query in ["", mode == "Profiles" ? "Research profile" : "continuous"] {
                app.tabBars.buttons["Search"].tap()
                let field = app.searchFields["Search \(mode)"]
                XCTAssertTrue(field.waitForExistence(timeout: 5))
                XCTAssertEqual(app.searchFields.count, 1)
                XCTAssertGreaterThan(field.frame.minY, app.frame.height * 0.7)
                if !query.isEmpty { field.typeText(query) }
                app.buttons["Close"].tap()
                saveScreenshot(app, name: "\(mode) after closing Search")
                XCTAssertTrue(app.searchFields.firstMatch.waitForNonExistence(timeout: 5))
                XCTAssertTrue(app.tabBars.buttons[mode].isSelected)
                let row = mode == "Profiles" ? "profile.default" : "bot.default"
                XCTAssertTrue(app.buttons[row].exists)
            }
        }
    }

    func testBotSearchKeepsItsFieldOutOfTheConversationHeader() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["profile.research"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Bots"].tap()
        app.tabBars.buttons["Search"].tap()
        let field = app.searchFields["Search Bots"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("continuous")
        app.buttons["bot.research"].tap()
        XCTAssertTrue(app.staticTexts["Existing continuous bot conversation"].waitForExistence(timeout: 10))
        saveScreenshot(app, name: "Bot conversation opened from Search")
        XCTAssertFalse(app.tabBars.element.exists)
        XCTAssertFalse(field.exists)
        XCTAssertTrue(app.textFields["chat.composer"].isHittable)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["bot.research"].waitForExistence(timeout: 5))
        if field.exists {
            XCTAssertGreaterThan(field.frame.minY, app.frame.height * 0.7)
            app.buttons["Close"].tap()
        }
        XCTAssertTrue(app.searchFields.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Bots"].isSelected)
    }

    func testBottomTabsAndSearchUseTheSelectedList() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["profile.research"].waitForExistence(timeout: 15))
        let profiles = app.tabBars.buttons["Profiles"]
        let bots = app.tabBars.buttons["Bots"]
        let search = app.tabBars.buttons["Search"]
        XCTAssertTrue(profiles.isSelected)
        XCTAssertFalse(app.segmentedControls.element.exists)
        for control in [profiles, bots, search] {
            XCTAssertTrue(control.isHittable)
            XCTAssertGreaterThanOrEqual(control.frame.width, 44)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
            XCTAssertGreaterThan(control.frame.minY, app.frame.height * 0.75)
        }
        saveScreenshot(app, name: "Profiles with bottom tabs and separate search")
        bots.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.8)).tap()
        XCTAssertTrue(app.buttons["bot.research"].waitForExistence(timeout: 5))
        XCTAssertTrue(bots.isSelected)
        saveScreenshot(app, name: "Bots with bottom tabs and separate search")

        search.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.8)).tap()
        let botSearch = app.searchFields["Search Bots"]
        XCTAssertTrue(botSearch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 5))
        botSearch.typeText("continuous")
        XCTAssertTrue(app.buttons["bot.research"].exists)
        XCTAssertFalse(app.buttons["bot.default"].exists)
        saveScreenshot(app, name: "Search the bot conversation previews")
        app.buttons["Close"].tap()
        XCTAssertTrue(bots.waitForExistence(timeout: 5))
        profiles.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.8)).tap()
        XCTAssertTrue(app.buttons["profile.default"].waitForExistence(timeout: 5))
        XCTAssertTrue(profiles.isSelected)

        search.tap()
        let profileSearch = app.searchFields["Search Profiles"]
        XCTAssertTrue(profileSearch.waitForExistence(timeout: 5))
        profileSearch.typeText("Research profile")
        XCTAssertTrue(app.buttons["profile.research"].exists)
        XCTAssertFalse(app.buttons["profile.default"].exists)
        app.buttons["profile.research"].tap()
        XCTAssertTrue(app.buttons["session.saved-0"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.element.exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["profile.research"].waitForExistence(timeout: 5))
    }

    func testBottomTabsRememberTheLastListAfterRelaunch() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["profile.research"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Bots"].tap()
        XCTAssertTrue(app.buttons["bot.research"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["preserve-home-mode"]
        app.launch()
        XCTAssertTrue(app.buttons["bot.research"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.tabBars.buttons["Bots"].isSelected)
    }

    func testProfilesKeepSessionsAndBotsOpenTheExistingConversationDirectly() async throws {
        let baseline = try await fixtureRequests().count
        let app = XCUIApplication()
        app.launch()
        let profile = app.buttons["profile.research"]
        XCTAssertTrue(profile.waitForExistence(timeout: 15))
        XCTAssertTrue(profile.staticTexts["Research profile"].exists)
        XCTAssertTrue(app.tabBars.buttons["Profiles"].isSelected)
        saveScreenshot(app, name: "Profiles home")
        profile.tap()
        XCTAssertTrue(app.buttons["session.saved-0"].waitForExistence(timeout: 10))
        app.buttons["session.saved-0"].tap()
        XCTAssertTrue(app.staticTexts["You: Message 500"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.element.exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.tabBars.buttons["Bots"].tap()
        XCTAssertTrue(app.buttons["bot.research"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["bot.research"].staticTexts["Existing continuous bot conversation"].exists)
        XCTAssertFalse(app.buttons["bot.research"].staticTexts["Research profile"].exists)
        XCTAssertFalse(app.staticTexts["Separate profile session message"].exists)
        saveScreenshot(app, name: "Bots home")
        app.buttons["bot.research"].tap()
        XCTAssertTrue(app.staticTexts["Existing continuous bot conversation"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.element.exists)
        XCTAssertTrue(app.staticTexts["chat.headerStatus"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Bot Chat"].exists)
        saveScreenshot(app, name: "Existing Bot Chat")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["bot.research"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Bots"].isSelected)
        app.buttons["bot.research"].tap()
        XCTAssertTrue(app.staticTexts["Existing continuous bot conversation"].waitForExistence(timeout: 10))

        let requests = Array((try await fixtureRequests()).dropFirst(baseline))
        let resumes = requests.filter { $0["method"] as? String == "session.resume" }
        XCTAssertEqual(resumes.filter { ($0["params"] as? [String: Any])?["session_id"] as? String == "bot-tip" }.count, 2)
        XCTAssertFalse(requests.contains { ["session.create", "prompt.submit"].contains($0["method"] as? String ?? "") })
    }

    func testMissingBotShowsRecoveryInDetails() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["profile.default"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Bots"].tap()
        app.buttons["bot.default"].tap()
        let alert = app.alerts["Unable to Continue"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.staticTexts["No Bot Chat is available for this profile. Open this bot in Hermes, then try again."].exists)
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Hermes"].exists)
        XCTAssertFalse(app.buttons["bot.research"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["bot.research"].exists)
        app.tabBars.buttons["Profiles"].tap()
        XCTAssertTrue(app.buttons["profile.research"].exists)
    }

    func testDelayedBotLoadsInTheDetailTitleAndUpdatesTheRowPreview() async throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["profile.research"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Bots"].tap()
        try await configureBot(lookupDelay: 4, messageDelay: 4, preview: "Latest bot reply")
        app.buttons["bot.research"].tap()
        XCTAssertTrue(app.navigationBars["Research"].waitForExistence(timeout: 2))
        let status = app.staticTexts["chat.headerStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 2))
        XCTAssertEqual(status.label, "Checking for latest data…")
        XCTAssertFalse(app.buttons["bot.research"].exists)
        XCTAssertFalse(app.staticTexts["Latest bot reply"].exists)
        XCTAssertFalse(app.otherElements["chat.loading"].exists)
        XCTAssertFalse(app.staticTexts["Loading conversation…"].exists)
        saveScreenshot(app, name: "Bot loading in detail title")
        XCTAssertTrue(app.staticTexts["Latest bot reply"].waitForExistence(timeout: 15))
        XCTAssertTrue(status.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Bot Chat"].exists)
        saveScreenshot(app, name: "Bot details without placeholder subtitle")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["bot.research"].staticTexts["Latest bot reply"].waitForExistence(timeout: 5))
        saveScreenshot(app, name: "Bots with latest conversation preview")
    }

    func testBackDuringBotLoadingDoesNotOpenALateConversation() async throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["profile.research"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Bots"].tap()
        let baseline = try await fixtureRequests().count
        try await configureBot(lookupDelay: 4)
        app.buttons["bot.research"].tap()
        XCTAssertTrue(app.navigationBars["Research"].waitForExistence(timeout: 2))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["bot.research"].waitForExistence(timeout: 2))
        try await Task.sleep(for: .seconds(5))
        XCTAssertTrue(app.buttons["bot.research"].exists)
        XCTAssertTrue(app.buttons["bot.research"].isEnabled)
        let cancelledRequests = Array((try await fixtureRequests()).dropFirst(baseline))
        XCTAssertFalse(cancelledRequests.contains { $0["method"] as? String == "session.resume" })

        try await configureBot(messageDelay: 5)
        app.buttons["bot.research"].tap()
        XCTAssertTrue(app.navigationBars["Research"].waitForExistence(timeout: 2))
        try await Task.sleep(for: .seconds(1))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["bot.research"].waitForExistence(timeout: 2))
        try await configureBot()
        app.buttons["bot.research"].tap()
        XCTAssertTrue(app.staticTexts["Existing continuous bot conversation"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.alerts.element.exists)
    }

    func testReplyToBotUsesItsOwnerWithoutTheMoveSessionAlert() async throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["profile.research"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Bots"].tap()
        app.buttons["bot.research"].tap()
        XCTAssertTrue(app.staticTexts["Existing continuous bot conversation"].waitForExistence(timeout: 10))
        let baseline = try await fixtureRequests().count
        let field = app.textFields["chat.composer"]
        field.tap()
        field.typeText("Testing")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.staticTexts["Bot replied to Testing"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.alerts.element.exists)
        XCTAssertFalse(app.staticTexts["Move session here?"].exists)
        let requests = Array((try await fixtureRequests()).dropFirst(baseline))
        XCTAssertEqual(requests.filter { $0["method"] as? String == "bot.reply.put" }.count, 1)
        XCTAssertFalse(requests.contains { ["prompt.submit", "session.create", "session.interrupt"].contains($0["method"] as? String ?? "") })
        saveScreenshot(app, name: "Bot reply without session transfer")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["bot.research"].staticTexts["Bot replied to Testing"].waitForExistence(timeout: 10))
        saveScreenshot(app, name: "Bots with sent reply preview")
    }

    private func configureBot(lookupDelay: Double = 0, messageDelay: Double = 0,
                              preview: String = "Existing continuous bot conversation") async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:19119/hermes/api/fixture/bot")!)
        request.httpMethod = "POST"
        request.setValue("Bearer fixture-dashboard-token", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["mode": "available", "lookup_delay": lookupDelay,
                                                                      "message_delay": messageDelay, "preview": preview])
        _ = try await URLSession.shared.data(for: request)
    }

    private func fixtureRequests() async throws -> [[String: Any]] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:19119/hermes/api/fixture/stats")!)
        request.setValue("Bearer fixture-dashboard-token", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try JSONSerialization.jsonObject(with: data) as! [String: Any])["requests"] as! [[String: Any]]
    }

    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
