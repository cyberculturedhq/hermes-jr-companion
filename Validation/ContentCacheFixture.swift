import SwiftUI

@main struct HermesApp: App {
    @State private var store = AppStore()
    @State private var activityStep = 0

    init() { configureContentNavigationAppearance() }
    private let mode = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("cache-") } ?? "cache-conversation"
    private let profile = BotProfile(id: "research", displayName: "Research", summary: "Saved research profile", model: "Hermes", isGatewayRunning: true)
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Group {
                    if mode == "cache-profiles" { BotListView() }
                    else if mode == "cache-sessions" || mode == "cache-sessions-active" { SessionListView(profile: profile) }
                    else { ChatView(sessionID: "saved") }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Finish refresh") {
                            if mode == "cache-sessions-active" {
                                let key = FollowedConversation(profile: profile.id, sessionID: "saved")
                                store.sessionActivities[key] = activityStep == 0 ? "Writing…" : nil
                                activityStep += 1
                                return
                            }

                            if mode == "cache-send-animation" {
                                let id = UUID().uuidString
                                store.messages.append(ChatMessage(id: id, role: "user", text: "Animated message", timestamp: .now, delivery: .sending))
                                Task { @MainActor in
                                    try? await Task.sleep(for: .seconds(1))
                                    if let index = store.messages.firstIndex(where: { $0.id == id }) { store.messages[index].delivery = .delivered }
                                }
                                return
                            }
                            if mode == "cache-receipts" {
                                store.messages[0].delivery = .delivered
                                return
                            }
                            if mode == "cache-activity", activityStep < 3 {
                                store.isSending = true
                                store.activity = ["Thinking…", "Using terminal", "Writing…"][activityStep]
                                if activityStep == 0 { store.messages.append(ChatMessage(id: "pending", role: "assistant", text: "", isStreaming: true)) }
                                if activityStep == 2 { store.messages[store.messages.count - 1].text = "The answer is arriving." }
                                activityStep += 1
                                return
                            }
                            store.isSending = false
                            store.activity = nil
                            store.phase = .connected
                            store.profileRefresh = ContentRefreshStatus(phase: .idle, updatedAt: .now)
                            store.sessionRefresh = ContentRefreshStatus(phase: .idle, updatedAt: .now)
                            store.conversationRefresh = ContentRefreshStatus(phase: .idle, updatedAt: .now)
                            store.sessionReady = true
                        }.accessibilityIdentifier("fixture.refresh")
                    }
                }
            }
            .environment(store).preferredColorScheme(.dark)
            .onAppear {
                store.phase = .restoring
                store.settings = ConnectionSettings(address: "https://fixture.example")
                store.profiles = [profile]
                let session = HermesSession(id: "saved", title: "Research notes", preview: "Saved conversation", lastActive: .now, messageCount: 40, source: "cli")
                store.sessions = [session]
                if mode != "cache-profiles" { store.selectedProfile = profile }
                if mode == "cache-conversation" || mode == "cache-activity" { store.selectedSession = session }
                store.messages = (0..<40).map { ChatMessage(id: "m-\($0)", role: "assistant", text: "Message \($0). Saved conversation content remains readable while Hermes reconnects and checks for newer messages.") }
                store.profileRefresh = ContentRefreshStatus(phase: .connecting, updatedAt: .now.addingTimeInterval(-1200))
                store.sessionRefresh = ContentRefreshStatus(phase: .checking, updatedAt: .now.addingTimeInterval(-1200))
                store.conversationRefresh = store.sessionRefresh
                if mode == "cache-sessions-active" {
                    store.phase = .connected; store.selectedSession = session; store.isSending = true
                    store.sessions.append(HermesSession(id: "older", title: "Older chat", preview: "Previous message", lastActive: .now.addingTimeInterval(-3600), messageCount: 2, source: "cli"))
                    let key = FollowedConversation(profile: profile.id, sessionID: "saved")
                    store.sentPreviews[key] = "Please research this topic"
                    store.sessionActivities[key] = "Thinking…"
                }
                if mode == "cache-handoff" || mode == "cache-handoff-confirm" {
                    store.phase = .connected; store.sessionReady = true; store.selectedSession = session
                    store.conversationRefresh = ContentRefreshStatus(phase: .idle)
                    store.messages = [ChatMessage(id: "saved-message", role: "assistant", text: "Your saved conversation stays here.")]
                    if mode == "cache-handoff-confirm" {
                        store.pendingSessionHandoff = AppStore.SessionHandoff(ticket: "fixture", profileID: profile.id,
                                                                             session: session, generation: 0)
                        store.errorMessage = "This will close the Hermes CLI chat on your other device and interrupt any reply or tool still running there. Saved messages will be loaded here. Unsent text in that terminal will not transfer."
                    } else {
                        store.errorMessage = "This chat is open in another Hermes window/terminal. Use it there, or start a new chat here.\nDetails: session saved opened by cli 1m ago."
                    }
                }
                if mode == "cache-send-animation" {
                    store.phase = .connected; store.sessionReady = true; store.selectedSession = session
                    store.conversationRefresh = ContentRefreshStatus(phase: .idle)
                    store.messages = []
                }
                if mode == "cache-receipts" {
                    store.phase = .connected; store.sessionReady = true; store.selectedSession = session
                    store.conversationRefresh = ContentRefreshStatus(phase: .idle)
                    store.messages = [ChatMessage(id: "outgoing", role: "user", text: "Hello", timestamp: .now, delivery: .sending)]
                }
            }
        }
    }
}
