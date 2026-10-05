import XCTest
@testable import Hermes

@MainActor
final class HermesTests: XCTestCase {
    func testColdLaunchChecksSavedConnectionBeforeShowingWelcome() {
        let store = AppStore()
        XCTAssertEqual(store.phase, .restoring)
    }

    func testKeychainRoundTripAndRemoval() throws {
        let account = "unit-test-\(UUID().uuidString)"
        defer { CredentialStore.delete(account: account) }
        try CredentialStore.save(SavedCredentials(password: "fixture-password", token: ""), account: account)
        XCTAssertEqual(try CredentialStore.read(account: account)?.password, "fixture-password")
        try CredentialStore.save(SavedCredentials(password: "", token: "fixture-token"), account: account)
        XCTAssertEqual(try CredentialStore.read(account: account)?.token, "fixture-token")
        CredentialStore.delete(account: account)
        XCTAssertNil(try CredentialStore.read(account: account))
    }

    func testAcceptsLocalAndHTTPSAddresses() throws {
        for address in ["http://localhost:9119", "http://127.0.0.1:9119", "http://192.168.1.8:9119", "http://10.0.0.1:9119", "http://172.16.0.1:9119", "http://100.64.0.1:9119", "http://100.127.255.254:9119", "http://mac.local:9119", "http://[::1]:9119", "https://example.com/hermes"] {
            XCTAssertNoThrow(try HermesClient.validatedURL(address), address)
        }
    }

    func testRejectsCredentialURLsAndInsecurePublicHosts() {
        for address in ["example.com", "file:///tmp/hermes", "http://example.com", "http://172.32.0.1:9119", "http://100.63.255.255:9119", "http://100.128.0.1:9119", "http://10.foo.0.0.1", "http://10.0.0.1.attacker.example", "https://user:secret@example.com", "https://example.com?token=secret", "https://example.com#fragment"] {
            XCTAssertThrowsError(try HermesClient.validatedURL(address), address)
        }
    }

}
