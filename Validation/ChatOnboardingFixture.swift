import SwiftUI
@main struct HermesApp: App {
 @State private var store = AppStore()
 private let chat = ProcessInfo.processInfo.arguments.contains("fixture-chat")
 var body: some Scene {
  WindowGroup {
   Group {
    if chat { NavigationStack { ChatView() } }
    else { AppRootView() }
   }.environment(store)
    .overlay(alignment: .bottomTrailing) {
     Button(chat ? "Fixture send" : "Fixture connect") {
      if chat {
       if ProcessInfo.processInfo.arguments.contains("fixture-long") { store.messages.append(ChatMessage(id: "one", role: "user", text: "U there?")) }
       else { store.messages = [ChatMessage(id: "one", role: "user", text: "U there?")] }
       Task { try? await Task.sleep(for: .milliseconds(400)); store.messages.append(ChatMessage(id: "two", role: "assistant", text: "Yep, I’m here. What can I help you with?")) }
      } else { store.phase = .connected }
     }.buttonStyle(.bordered).accessibilityIdentifier("fixture.action")
    }
    .onAppear {
     store.phase = chat ? .connected : .disconnected
     if ProcessInfo.processInfo.arguments.contains("fixture-long") { store.messages = (0..<40).map { ChatMessage(id: "old-\($0)", role: "assistant", text: "Earlier message \($0). Some conversation history to fill the viewport.") } }
     store.selectedProfile = BotProfile(id: "default", displayName: "Hermes", summary: "", model: "", isGatewayRunning: true)
     store.selectedSession = HermesSession(id: "fixture", title: "Layout test", preview: "", lastActive: Date(), messageCount: 0, source: "cli")
    }
  }
 }
}
