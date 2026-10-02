import SwiftUI

struct SessionListView: View {
    let profile: BotProfile
    @Environment(AppStore.self) private var store
    @State private var searchText = ""
    @State private var creatingSession = false
    @State private var isVisible = false

    private var isSelectedProfile: Bool { store.selectedProfile?.id == profile.id }

    private var sessions: [HermesSession] {
        guard isSelectedProfile else { return [] }
        return store.sessions.filter {
            searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.preview.localizedCaseInsensitiveContains(searchText)
        }.sorted { $0.lastActive > $1.lastActive }
    }

    var body: some View {
        List {
            if #unavailable(iOS 26.0) {
            ContentStatusHeader(status: store.sessionRefresh) { Task { await store.retryContentConnection() } }
                .listRowSeparator(.hidden)
            }
            ForEach(sessions) { session in
            NavigationLink(value: AppRoute.session(session.id)) {
                HStack(alignment: .top, spacing: 12) {
                    ProfileAvatar(profile: profile, address: store.settings?.address ?? "", size: 44)
                        .overlay(alignment: .leading) {
                            if store.isSessionUnread(session.id, profile: profile.id) {
                                Circle().fill(.blue).frame(width: 8, height: 8)
                                    .offset(x: -14, y: 0)
                                    .accessibilityLabel("Unread reply")
                                    .accessibilityIdentifier("session.unread.\(session.id)")
                            }
                        }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(session.name).font(.headline).lineLimit(1)
                            Spacer()
                            Text(session.lastActive, format: dateFormat(for: session.lastActive))
                                .font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize()
                        }
                        Text(store.sessionPreview(session, profile: profile.id).replacingOccurrences(of: "\n", with: " "))
                            .foregroundStyle(.secondary).lineLimit(2)
                            .modifier(ActivityTextShimmer(active: store.sessionActivities[
                                FollowedConversation(profile: profile.id, sessionID: session.id)] != nil))
                    }
                }
                .padding(.vertical, 4)
            }
            .disabled(!isSelectedProfile || store.isLoadingMessages || creatingSession
                || store.isRunningCommand)
            .accessibilityIdentifier("session.\(session.id)")
            .contextMenu {
                
                    let following = store.isFollowing(profile: profile.id, sessionID: session.id)
                    Button(following ? "Unfollow notifications" : "Follow notifications", systemImage: following ? "bell.slash" : "bell") {
                        Task { await store.setFollowing(profile: profile.id, sessionID: session.id, enabled: !following) }
                    }
                
            }
        }
        }
        .listStyle(.plain)
        .modifier(ContentStatusSubtitle(status: store.sessionRefresh))
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "Search")
        .overlay {
            if isSelectedProfile && store.sessionRefresh.phase == .idle && sessions.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No Messages" : "No Results",
                    systemImage: searchText.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass",
                    description: Text(searchText.isEmpty ? "Tap compose to start a session." : "Try another search."))
            }
        }
        .toolbar {
            if #available(iOS 26.0, *) {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
            }
            ToolbarItem(placement: .topBarTrailing) {
                if store.sessionRefresh.phase == .failed || store.sessionRefresh.phase == .unavailable {
                    Button("Retry", systemImage: "arrow.clockwise") { Task { await store.refreshSessions() } }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if creatingSession { ProgressView() }
                else {
                    Button("New Message", systemImage: "square.and.pencil", action: newSession)
                        .disabled(!isSelectedProfile || store.phase != .connected || store.isLoadingMessages || store.isRunningCommand)
                        .accessibilityIdentifier("sessions.new")
                }
            }
        }
        .refreshable {
            guard isSelectedProfile else { return }
            await store.refreshSessions()
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .alert("Couldn’t Load Sessions", isPresented: Binding(
            get: { isVisible && isSelectedProfile && store.errorMessage != nil && store.selectedSession == nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("Try Again") { Task { await store.refreshSessions() } }
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private func dateFormat(for date: Date) -> Date.FormatStyle {
        Calendar.current.isDateInToday(date) ? .dateTime.hour().minute() : .dateTime.month(.defaultDigits).day()
    }

    private func newSession() {
        guard isSelectedProfile, !creatingSession, !store.isLoadingMessages, !store.isRunningCommand else { return }
        creatingSession = true
        Task { await store.createSession(); creatingSession = false }
    }
}
