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

    func testAcceptsHTTPSAddresses() throws {
        for address in ["https://localhost:9119", "https://192.168.1.8:9119", "https://hermes.example.com/hermes"] {
            XCTAssertNoThrow(try HermesClient.validatedURL(address), address)
        }
    }

    func testRejectsCredentialURLsAndAllInsecureHosts() {
        for address in ["example.com", "file:///tmp/hermes", "http://example.com", "http://172.32.0.1:9119", "http://100.63.255.255:9119", "http://100.128.0.1:9119", "http://10.foo.0.0.1", "http://10.0.0.1.attacker.example", "https://user:secret@example.com", "https://example.com?token=secret", "https://example.com#fragment"] {
            XCTAssertThrowsError(try HermesClient.validatedURL(address), address)
        }
        for address in ["http://localhost:9119", "http://127.0.0.1:9119", "http://192.168.1.8:9119", "http://10.0.0.1:9119", "http://172.16.0.1:9119", "http://100.64.0.1:9119", "http://100.127.255.254:9119", "http://mac.local:9119", "http://[::1]:9119", "http://[fd00::1]:9119"] {
            XCTAssertThrowsError(try HermesClient.validatedURL(address), address)
        }
    }

    func testSavedHTTPConnectionShowsMigrationAndKeepsCredentials() async throws {
        let key = "hermes.connection.settings.v1", prior = UserDefaults.standard.object(forKey: "hermes.connection.settings.v1")
        let address = "http://127.0.0.1:1"
        defer {
            CredentialStore.delete(account: address)
            if let prior { UserDefaults.standard.set(prior, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let saved = ConnectionSettings(address: address, username: "fixture", usesSavedCredentials: true)
        let data = try JSONEncoder().encode(saved)
        UserDefaults.standard.set(data, forKey: key)
        try CredentialStore.save(SavedCredentials(password: "fixture", token: ""), account: address)
        let store = AppStore()
        await store.restoreConnection()
        XCTAssertEqual(store.phase, .disconnected)
        XCTAssertEqual(store.connectionNotice, .secureConnectionRequired)
        XCTAssertFalse(store.connectionNotice!.canRetry)
        XCTAssertTrue(store.connectionNotice!.message.contains("HTTPS"))
        XCTAssertEqual(UserDefaults.standard.data(forKey: key), data)
        XCTAssertEqual(try CredentialStore.read(account: address)?.password, "fixture")
    }

}
