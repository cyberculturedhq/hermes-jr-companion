import Foundation
import Observation
import UIKit
import UserNotifications

extension Notification.Name {
    static let hermesNotificationOpened = Notification.Name("hermes.notification.opened")
    static let hermesSetupOpened = Notification.Name("hermes.setup.opened")
}

enum PushNotificationError: LocalizedError {
    case permissionDenied

    var errorDescription: String? {
        "Notifications are disabled for Hermes Jr. You can enable them in iOS Settings."
    }
}

@MainActor @Observable
final class PushNotifications {
    static let shared = PushNotifications()
    private static let pendingOpenKey = "hermes.notification.pending-reference.v1"
    private var waiter: CheckedContinuation<String, Error>?
    private var timeout: Task<Void, Never>?
    private var currentToken: String?

    private(set) var pendingReference: String? = UserDefaults.standard.string(forKey: pendingOpenKey)

    /// Save before broadcasting, since a cold-launch view may not exist yet.
    func rememberNotificationOpen(_ reference: String) {
        guard (32...64).contains(reference.count), Data(companionBase64: reference) != nil else { return }
        UserDefaults.standard.set(reference, forKey: Self.pendingOpenKey)
        pendingReference = reference
    }

    func acknowledgeNotificationOpen(_ reference: String) {
        guard pendingReference == reference else { return }
        UserDefaults.standard.removeObject(forKey: Self.pendingOpenKey)
        pendingReference = nil
    }

    var environment: String {
        (Bundle.main.object(forInfoDictionaryKey: "HermesAPNSEnvironment") as? String) == "production" ? "production" : "sandbox"
    }

    func requestToken() async throws -> String {
        let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        guard allowed else { throw PushNotificationError.permissionDenied }
        if let currentToken { return currentToken }
        guard waiter == nil else { throw HermesError.message("Notification registration is already in progress.") }
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
            timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(25)) } catch { return }
                self?.failed(HermesError.message("Apple push registration timed out. Check the network and the app’s signing configuration."))
            }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func registered(_ token: Data) {
        let value = token.map { String(format: "%02x", $0) }.joined()
        currentToken = value
        timeout?.cancel(); timeout = nil
        let pending = waiter; waiter = nil
        pending?.resume(returning: value)
    }

    func failed(_ error: Error) {
        timeout?.cancel(); timeout = nil
        let pending = waiter; waiter = nil
        pending?.resume(throwing: error)
    }
}

final class HermesAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushNotifications.shared.registered(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushNotifications.shared.failed(error) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        // A setup push only wakes the pending local flow. It never supplies keys or approval.
        if let intent = response.notification.request.content.userInfo["pairing_ready"] as? String,
           (try? SetupCrypto.decode(intent, count: 32)) != nil {
            Task { @MainActor in NotificationCenter.default.post(name: .hermesSetupOpened, object: intent) }
            completionHandler()
            return
        }
        if let reference = response.notification.request.content.userInfo["reference"] as? String,
           (32...64).contains(reference.count), Data(companionBase64: reference) != nil {
            Task { @MainActor in
                PushNotifications.shared.rememberNotificationOpen(reference)
                NotificationCenter.default.post(name: .hermesNotificationOpened, object: reference)
            }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
