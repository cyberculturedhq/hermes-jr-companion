import SwiftUI

enum AppRoute: Hashable {
    case profile(String)
    case session(String)
}

struct AppRootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var path: [AppRoute] = []
    @State private var showRemovedNotice = false
    @State private var onboardingVisible = false

    var body: some View {
        @Bindable var store = store
        ZStack {
            if onboardingVisible || store.phase == .connecting || (store.phase == .disconnected && store.connectionNotice == nil && !store.canBrowseCachedContent) {
                ConnectionView(onFinished: {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.35)) {
                        onboardingVisible = false
                    }
                })
                    .onAppear { onboardingVisible = true }
                    .transition(.asymmetric(
                        insertion: .identity,
                        removal: reduceMotion ? .opacity : .move(edge: .leading)
                    ))
                    .zIndex(1)
            } else {
                switch store.canBrowseCachedContent && store.phase == .disconnected ? .restoring : store.phase {
                case .restoring, .connected:
                    NavigationStack(path: $path) {
                        BotListView()
                            .navigationDestination(for: AppRoute.self) { route in
                                switch route {
                                case .profile(let id):
                                    if let profile = store.profiles.first(where: { $0.id == id }) {
                                        SessionListView(profile: profile)
                                            .onAppear {
                                                if store.selectedProfile?.id != id {
                                                    // Loading all pages continues when a conversation is pushed.
                                                    Task { await store.selectProfile(profile) }
                                                }
                                            }
                                    } else {
                                        ContentUnavailableView("Profile Unavailable", systemImage: "person.crop.circle.badge.questionmark")
                                    }
                                case .session(let id):
                                    ChatView(sessionID: id)
                                        .id(id)
                                        .onAppear {
                                            if store.selectedSession?.id != id || !store.sessionReady,
                                               let session = store.sessions.first(where: { $0.id == id }) {
                                                Task { await store.openSession(session) }
                                            }
                                        }
                                }
                            }
                    }
                    .overlay {
                        if path.isEmpty, PushNotifications.shared.pendingReference != nil,
                           store.phase == .restoring || store.openingNotificationReference != nil {
                            ProgressView("Opening conversation…")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color(.systemBackground))
                                .accessibilityIdentifier("notification.opening")
                        }
                    }
                    .transition(.asymmetric(
                        insertion: reduceMotion ? .opacity : .move(edge: .trailing),
                        removal: .identity
                    ))
                case .disconnected, .connecting:
                    if store.phase == .disconnected, let notice = store.connectionNotice {
                        ConnectionRecoveryView(notice: notice) { showRemovedNotice = true }
                    } else {
                        EmptyView()
                    }
                }
            }
        }
        .sheet(isPresented: $store.showingSettings) { ConnectionDetailsView() }
        .modifier(NotificationPreferenceErrorPresenter(inSettings: false))
        .overlay(alignment: .top) {
            if showRemovedNotice {
                Label("Connection removed. You can connect again here.", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .padding().background(.regularMaterial, in: Capsule())
                    .padding(.top, 12)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .task(id: showRemovedNotice) {
            guard showRemovedNotice else { return }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            showRemovedNotice = false
        }
        .onChange(of: path) { old, new in
            if case .session(let id) = new.last {
                store.visibleSessionID = id
                if let profile = store.selectedProfile { store.markSessionRead(id, profile: profile.id) }
            }
            else { store.visibleSessionID = nil }
            guard new.count < old.count else { return }
            if new.isEmpty { store.backToBots() }
            else if case .profile = new.last {
                store.backToSessions()
                // Notification routing defers the full list until it is visible.
                if store.sessionRefresh.phase == .checking && !store.isLoadingSessions {
                    Task { await store.refreshSessions() }
                }
            }
        }
        .onChange(of: store.selectedSession?.id) { _, id in
            if let id {
                switch path.last {
                case .profile:
                    path.append(.session(id))
                case .session(let previousID) where previousID != id:
                    // /new replaces the conversation while keeping Back pointed at its profile.
                    path[path.count - 1] = .session(id)
                default:
                    break
                }
            }
        }
        .onChange(of: store.phase) { _, phase in
            if phase != .connected && !store.canBrowseCachedContent {
                path.removeAll()
                if store.connectionNotice != nil { onboardingVisible = false }
            }
            else { Task { await store.processPendingNotification() } }
        }
        .onChange(of: store.notificationDestination) { _, destination in
            if let destination { path = [.profile(destination.profile), .session(destination.sessionID)] }
        }
        .onChange(of: store.updateDestination) { _, destination in
            if let destination { path = [.profile(destination.profile), .session(destination.sessionID)] }
        }
        .task(id: "\(scenePhase)-\(store.updateProgress?.receipt.id ?? "")") {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await store.refreshCompanionUpdate()
                do { try await Task.sleep(for: .seconds(store.updateProgress?.pending == true ? 15 : 900)) }
                catch { return }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            store.setAppActive(phase == .active)
            if phase == .background { store.enterBackground() }
            if phase == .active {
                store.returnToForeground()
                Task { await store.processPendingNotification() }
            }
        }
        .onChange(of: store.isSending) { _, busy in
            if !busy {
                Task { await store.processPendingNotification() }
            }
        }
        .onChange(of: store.isRunningCommand) { _, busy in
            if !busy {
                Task { await store.processPendingNotification() }
            }
        }
        .onChange(of: store.isLoadingMessages) { _, busy in
            if !busy { Task { await store.processPendingNotification() } }
        }
        .onChange(of: store.selectedSession?.id) { _, _ in store.setAppActive(scenePhase == .active) }
        .onReceive(NotificationCenter.default.publisher(for: .hermesNotificationOpened)) { notification in
            if let reference = notification.object as? String { Task { await store.openNotification(reference: reference) } }
        }
    }
}
