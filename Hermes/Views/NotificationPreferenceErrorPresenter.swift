import SwiftUI

struct NotificationPreferenceErrorPresenter: ViewModifier {
    @Environment(AppStore.self) private var store
    let inSettings: Bool

    func body(content: Content) -> some View {
        content.alert("Couldn’t Update Notifications", isPresented: Binding(
            get: { store.showingSettings == inSettings && store.notificationPreference.failure != nil },
            set: { if !$0, store.showingSettings == inSettings { store.notificationPreference.failure = nil } }
        ), presenting: store.notificationPreference.failure) { failure in
            Button("Retry") { store.requestNotificationsEnabled(failure.requestedValue) }
            if !inSettings {
                Button("Open Settings") {
                    store.notificationPreference.failure = nil
                    store.showingSettings = true
                }
            }
            Button("Cancel", role: .cancel) { store.notificationPreference.failure = nil }
        } message: { failure in
            Text(failure.message + "\n\nThe switch shows the last confirmed setting.")
        }
    }
}
