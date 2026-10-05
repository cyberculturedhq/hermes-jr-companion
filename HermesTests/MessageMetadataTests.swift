import XCTest
@testable import Hermes

@MainActor
final class MessageMetadataTests: XCTestCase {
    func testServerTimestampFormatsAndMissingValues() {
        let expected = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(HermesClient.messageDate(1_700_000_000), expected)
        XCTAssertEqual(HermesClient.messageDate(1_700_000_000_000), expected)
        XCTAssertEqual(HermesClient.messageDate("1700000000"), expected)
        XCTAssertEqual(HermesClient.messageDate("2023-11-14T22:13:20Z"), expected)
        XCTAssertNil(HermesClient.messageDate(nil))
        XCTAssertNil(HermesClient.messageDate(true))
        XCTAssertNil(HermesClient.messageDate("unknown"))
    }

    func testLegacyCachedMessagesHaveNoInventedMetadata() throws {
        let data = Data(#"{"id":"old","role":"user","text":"Hello","isStreaming":false,"photos":[]}"#.utf8)
        let message = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertNil(message.timestamp)
        XCTAssertNil(message.delivery)
        let confirmed = ChatMessage(id: "new", role: "user", text: "Hello", timestamp: Date(timeIntervalSince1970: 1700000000), delivery: .delivered)
        XCTAssertEqual(try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(confirmed)), confirmed)
    }
}
