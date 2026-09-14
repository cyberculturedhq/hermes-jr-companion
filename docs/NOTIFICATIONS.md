# Notification wording

The plugin chooses the event and reads the conversation title locally. It encrypts those details for each phone. The Cloudflare service forwards ciphertext plus generic fallback text. The iPhone notification extension decrypts the details and supplies the final wording.

The title is **only the Hermes profile name**, such as **Research**. With a conversation called **Weekend trip**, the bodies are:

| Event | Body |
| --- | --- |
| Completed | New reply in “Weekend trip”. |
| Error | Something went wrong in “Weekend trip”. Open for details. |
| Approval | “Weekend trip” needs your permission to continue. |
| Clarification | Your agent needs an answer in “Weekend trip” to continue. |

Without a conversation title, completion reads “Your agent has replied.” and approval reads “Your agent needs your permission to continue.” Error and clarification use “this conversation”. No message excerpts are included.

If the phone cannot decrypt, or the installation does not support encrypted previews:

**Title:** Hermes Jr.

**Body:** You have a new notification. Open the app for details.

All alerts use the default notification sound. Only opened/followed conversations qualify, notifications must be enabled, and active conversation presence suppresses alerts (a stale lease lasts up to 45 seconds). Alerts share a collapse identifier and expire after one hour, so iOS may replace an earlier pending alert.

The rich wording lives in the iOS app’s `SharedNotifications/NotificationPreview.swift`; the generic fallback also lives in [`RelayService/src/apns.ts`](../RelayService/src/apns.ts). The iPhone’s companion-update notice is an in-app notice, not a push.

See the [notification encryption design](../Protocol/NOTIFICATIONS.md) for key management, metadata, and limitations.
