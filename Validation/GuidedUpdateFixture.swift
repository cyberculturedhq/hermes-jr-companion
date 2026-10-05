import SwiftUI

@main struct HermesApp: App {
    @State private var store = AppStore()

    init() {
        configureContentNavigationAppearance()
        let address = "http://127.0.0.1:19129"
        try! CredentialStore.save(SavedCredentials(password: "", token: "notification-fixture-token"), account: address)
        let settings = ConnectionSettings(address: address, usesSavedCredentials: true)
        ContentCache().remove(settings)
        UserDefaults.standard.removeObject(forKey: "notifications/" + address + "/preferences")
        UserDefaults.standard.set(try! JSONEncoder().encode(settings), forKey: "hermes.connection.settings.v1")
        UserDefaults.standard.removeObject(forKey: "notifications/" + address + "/update-request")
        try! CredentialStore.saveValue(CompanionEnrollment(deviceID: "11111111-1111-4111-8111-111111111111", deviceToken: "fixture", installationID: "fixture"), account: "notifications/" + address)
        if let reference = PushNotifications.shared.pendingReference { PushNotifications.shared.acknowledgeNotificationOpen(reference) }
    }

    var body: some Scene {
        WindowGroup {
            AppRootView().environment(store).task {
                await store.restoreConnection()
                await store.processPendingNotification()
            }
        }
    }
}
