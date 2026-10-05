import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var fallback: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content); return
        }
        // Never display server-supplied text as if it had been authenticated by the host.
        content.title = NotificationPreview.fallbackTitle
        content.body = NotificationPreview.fallbackBody
        content.subtitle = ""
        handler = contentHandler
        fallback = content.mutableCopy() as? UNMutableNotificationContent
        if let preview = try? NotificationPreview.decrypt(userInfo: request.content.userInfo) {
            content.title = preview.title
            content.body = preview.body
        }
        finish(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let fallback { finish(fallback) }
    }

    private func finish(_ content: UNNotificationContent) {
        let completion = handler; handler = nil; fallback = nil
        completion?(content)
    }
}
