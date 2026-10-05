import XCTest
final class PairingUI: XCTestCase {
 func capture(_ name: String) {
  let screenshot = XCUIApplication().screenshot()
  let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("HermesUI-" + name + ".png")
  try? screenshot.pngRepresentation.write(to: output)
  print("UI_ARTIFACT " + output.path)
  let attachment = XCTAttachment(screenshot: screenshot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
 }
 func testOnboardingHeaderAndSuccess() {
  let app = XCUIApplication(); app.launch()
  XCTAssertTrue(app.buttons["connection.chooseCompanion"].waitForExistence(timeout: 20))
  capture("Welcome paused")
  Thread.sleep(forTimeInterval: 2); capture("Still paused")
  app.buttons["connection.chooseCompanion"].tap()
  XCTAssertTrue(app.buttons["connection.copyDevicePrompt"].waitForExistence(timeout: 5))
  capture("Install header")
  app.buttons["connection.back"].tap()
  XCTAssertTrue(app.buttons["connection.chooseAddress"].waitForExistence(timeout: 5))
  app.buttons["connection.chooseAddress"].tap()
  XCTAssertTrue(app.textFields["connection.address"].waitForExistence(timeout: 5))
  capture("Address fixed header")
  app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.6))
   .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.6)))
  XCTAssertTrue(app.buttons["connection.chooseCompanion"].waitForExistence(timeout: 5))
  app.buttons["connection.chooseCompanion"].tap()
  XCTAssertTrue(app.buttons["connection.copyDevicePrompt"].waitForExistence(timeout: 5))
  app.buttons["fixture.action"].tap()
  XCTAssertTrue(app.staticTexts["You’re connected"].waitForExistence(timeout: 5))
  Thread.sleep(forTimeInterval: 2); capture("Success playing")
  Thread.sleep(forTimeInterval: 7)
  XCTAssertTrue(app.staticTexts["You’re connected"].exists)
  XCTAssertFalse(app.navigationBars["Bots"].exists)
  app.buttons["connection.finish"].tap()
  XCTAssertTrue(app.navigationBars["Bots"].waitForExistence(timeout: 5))
 }
 func testFirstMessageStaysAtTopWithKeyboard() {
  let app = XCUIApplication(); app.launchArguments = ["fixture-chat"]; app.launch()
  let field = app.textFields["Message"]
  XCTAssertTrue(field.waitForExistence(timeout: 20)); field.tap(); field.typeText("Hi")
  app.buttons["fixture.action"].tap()
  let first = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "You: U there?")).firstMatch
  XCTAssertTrue(first.waitForExistence(timeout: 5))
  Thread.sleep(forTimeInterval: 1)
  let nav = app.navigationBars.firstMatch
  XCTAssertLessThan(first.frame.minY - nav.frame.maxY, 65)
  XCTAssertGreaterThanOrEqual(first.frame.minY, nav.frame.maxY)
  capture("First message with keyboard")
 }
 func testLongConversationKeepsLatestVisibleWithKeyboard() {
  let app = XCUIApplication(); app.launchArguments = ["fixture-chat", "fixture-long"]; app.launch()
  let field = app.textFields["Message"]
  XCTAssertTrue(field.waitForExistence(timeout: 20)); field.tap(); field.typeText("Hi")
  app.buttons["fixture.action"].tap()
  let latest = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "You: U there?")).firstMatch
  XCTAssertTrue(latest.waitForExistence(timeout: 5))
  Thread.sleep(forTimeInterval: 1)
  XCTAssertTrue(latest.isHittable)
  XCTAssertLessThan(latest.frame.maxY, field.frame.minY)
  capture("Long conversation follows latest")
 }

}
