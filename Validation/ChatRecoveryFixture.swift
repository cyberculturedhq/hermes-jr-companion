import SwiftUI

@main struct HermesApp: App {
    @State private var store = AppStore()
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ChatView(sessionID: "fixture")
                    .toolbar {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            Button("Stream fixture") {
                                store.isSending = true
                                if ProcessInfo.processInfo.arguments.contains("short-chat") {
                                    store.messages = [ChatMessage(id: "first", role: "user", text: "Sup"), ChatMessage(id: "pending", role: "assistant", text: "", isStreaming: true)]
                                    store.activity = "Thinking…"
                                    return
                                }
                                Task { @MainActor in
                                    for index in 0..<16 {
                                        try? await Task.sleep(for: .milliseconds(150))
                                        store.messages[39].text += "\nStreaming line \(index). The reply keeps growing while we stay at the bottom."
                                    }
                                    store.messages.append(ChatMessage(id: "stream-end", role: "assistant", text: "STREAM END"))
                                }
                            }.accessibilityIdentifier("fixture.stream")
                            Button("Refresh fixture") {
                                store.isLoadingMessages = true
                                Task { @MainActor in
                                    try? await Task.sleep(for: .seconds(2))
                                    store.messages[39].text += " Refreshed."
                                    store.isLoadingMessages = false
                                }
                            }.accessibilityIdentifier("fixture.refresh")
                        }
                    }
            }
            .environment(store)
            .preferredColorScheme(.dark)
            .onAppear {
                store.phase = .connected
                store.selectedProfile = BotProfile(id: "default", displayName: "Hermes", summary: "", model: "", isGatewayRunning: true)
                store.selectedSession = HermesSession(id: "fixture", title: "Recovery layout", preview: "", lastActive: Date(), messageCount: 40, source: "cli")
                if ProcessInfo.processInfo.arguments.contains("short-chat") { store.messages = [ChatMessage(id: "first", role: "user", text: "Sup")]; return }
                store.messages = (0..<40).map { ChatMessage(id: "message-\($0)", role: "assistant", text: "Message \($0). A long conversation to test scrolling with the keyboard and refreshing the transcript.") }
            }
        }
    }
}
