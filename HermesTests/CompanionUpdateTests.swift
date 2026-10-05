import XCTest
import CryptoKit
@testable import Hermes

final class CompanionUpdateTests: XCTestCase {
    func testSignedFeedBindsVersionAndCommit() throws {
        let release = CompanionRelease(schema: 1, version: "0.15.0", commit: "904b473331a31367f04b18180aa0770b0a71536d",
            signature: "yOmmNudsSSmzNb1LZAtVqyZqggfJOknsLQ/E4eD32cIWTtZ3TPYqMTMDb4yphL3DeyVPy26UzaKIGaxXacV0Aw==")
        XCTAssertEqual(try release.verified().version, "0.15.0")
        XCTAssertThrowsError(try CompanionRelease(schema: 1, version: "0.16.0", commit: release.commit, signature: release.signature).verified())
        XCTAssertThrowsError(try CompanionRelease(schema: 1, version: release.version, commit: String(repeating: "b", count: 40), signature: release.signature).verified())
        XCTAssertNil(CompanionUpdateNotice(installed: "0.16.0", latest: "0.15.0"))
        XCTAssertNil(CompanionUpdateNotice(installed: "0.16.0", latest: "0.16.0"))
        XCTAssertEqual(CompanionUpdateNotice(installed: "0.9.0", latest: "0.16.0")?.version, "0.16.0")
        XCTAssertNil(CompanionUpdateNotice(installed: "0.16.0", latest: "0.17.0-beta"))
    }

    func testReceiptSurvivesAppRestartAndOpaqueShellArgumentRoundTrips() throws {
        let receipt = CompanionUpdateReceipt(id: UUID().uuidString.lowercased(), device_id: UUID().uuidString.lowercased(),
            profile: "default", session_id: "conversation-1", target: "0.16.0", notify: false, created: Date().timeIntervalSince1970)
        let progress = CompanionUpdateProgress(receipt: receipt)
        let restored = try JSONDecoder().decode(CompanionUpdateProgress.self, from: JSONEncoder().encode(progress))
        XCTAssertEqual(restored, progress)
        XCTAssertTrue(restored.pending)
        let prompt = try receipt.prompt
        let token = try XCTUnwrap(prompt.components(separatedBy: "--receipt ").dropFirst().first?.components(separatedBy: "\n").first)
        XCTAssertNotNil(token.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression))
        XCTAssertEqual(try JSONDecoder().decode(CompanionUpdateReceipt.self, from: XCTUnwrap(Data(companionBase64: token))), receipt)
        XCTAssertFalse(try receipt.body["notify"] as! Bool)
        XCTAssertFalse(prompt.contains("raw.githubusercontent.com"))
        XCTAssertFalse(prompt.contains("curl "))
        XCTAssertTrue(prompt.contains("hermes jr update --install --receipt"))
    }

    func testUpdateCompletionPreviewIsEncryptedAndRoutesToItsConversation() throws {
        let key = Data(repeating: 3, count: 32)
        let reference = NotificationPreview.encode(Data(repeating: 7, count: 32))
        let keyID = NotificationPreview.encode(Data(repeating: 5, count: 16))
        let now = Date()
        let content: [String: Any] = ["kind": "update_completed", "profile": "Hermes Jr.", "conversation": "", "expires": now.timeIntervalSince1970 + 3600]
        let raw = try JSONSerialization.data(withJSONObject: content)
        var padded = Data([UInt8(raw.count >> 8), UInt8(raw.count & 255)]) + raw
        padded.append(Data(repeating: 0, count: 1024 - padded.count))
        let aad = Data(("hermes-jr/notification/v1\0" + keyID + "\0" + reference).utf8)
        let encrypted = try ChaChaPoly.seal(padded, using: SymmetricKey(data: key), authenticating: aad)
        let payload: [AnyHashable: Any] = ["reference": reference, "encrypted": ["v": 1, "kid": keyID, "data": NotificationPreview.encode(encrypted.combined)]]
        let preview = try NotificationPreview.decrypt(userInfo: payload, secret: key, now: now)
        XCTAssertEqual(preview.title, "Hermes Jr.")
        XCTAssertEqual(preview.body, "Your companion update is complete. Open Hermes Jr. for details.")
    }
}
