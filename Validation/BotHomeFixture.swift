import SwiftUI

@main struct HermesApp: App {
    @State private var store = AppStore()

    init() {
        configureContentNavigationAppearance()
        let address = "http://127.0.0.1:19119/hermes"
        try! CredentialStore.save(SavedCredentials(password: "", token: "fixture-dashboard-token"), account: address)
        let settings = ConnectionSettings(address: address, usesSavedCredentials: true)
        ContentCache().remove(settings)
        UserDefaults.standard.set(try! JSONEncoder().encode(settings), forKey: "hermes.connection.settings.v1")
        if !ProcessInfo.processInfo.arguments.contains("preserve-home-mode") {
            UserDefaults.standard.removeObject(forKey: "hermes.home.mode.v1")
        }
    }

    var body: some Scene {
        WindowGroup {
            AppRootView().environment(store).task { await store.restoreConnection() }
        }
    }
}
