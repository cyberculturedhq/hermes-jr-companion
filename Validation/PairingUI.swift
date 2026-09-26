import XCTest
import Foundation

final class PairingUI: XCTestCase {
    func testOnePromptPairing() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let choose = app.buttons["connection.chooseCompanion"]
        XCTAssertTrue(choose.waitForExistence(timeout: 20))
        choose.tap()
        app.buttons["connection.copyDevicePrompt"].tap()
        let sent = app.buttons["connection.startWaiting"]
        XCTAssertTrue(sent.waitForExistence(timeout: 60))
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: sent)
        waitForExpectations(timeout: 30)
        sent.tap()
        let confirm = app.buttons["connection.confirmCodes"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 1100))
        var agentCode = ""
        for _ in 0..<300 {
            if let data = try? Data(contentsOf: URL(string: "http://127.0.0.1:18139/code")!),
               let code = String(data: data, encoding: .utf8), !code.isEmpty {
                agentCode = code; break
            }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertFalse(agentCode.isEmpty)
        XCTAssertTrue(app.staticTexts["Pairing code " + agentCode].exists,
                      "Never confirm without matching the visible Hermes code")
        let before = XCTAttachment(screenshot: app.screenshot()); before.name = "Matching codes"; before.lifetime = .keepAlways; add(before)
        confirm.tap()
        let finish = app.buttons["connection.finish"]
        if finish.waitForExistence(timeout: 45) { finish.tap() }
        XCTAssertTrue(app.navigationBars["Bots"].waitForExistence(timeout: 45))
        let after = XCTAttachment(screenshot: app.screenshot()); after.name = "Connected profiles"; after.lifetime = .keepAlways; add(after)
    }
}
