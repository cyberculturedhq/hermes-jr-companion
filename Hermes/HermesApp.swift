import SwiftUI

@main
struct HermesApp: App {
    @UIApplicationDelegateAdaptor(HermesAppDelegate.self) private var appDelegate
    @State private var store = AppStore()

    init() { configureContentNavigationAppearance() }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(store)
                .task {
                    await store.restoreConnection()
                    await store.processPendingNotification()
                }
        }
    }
}
