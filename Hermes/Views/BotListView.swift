import SwiftUI

struct BotListView: View {
    @Binding var path: [AppRoute]

    private enum HomeMode: String {
        case profiles = "Profiles", bots = "Bots"
    }

    private enum HomeTab: Hashable { case profiles, bots, search }

    @Environment(AppStore.self) private var store
    @AppStorage("hermes.home.mode.v1") private var mode: HomeMode = .profiles
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var isSearchPresented = false
    @State private var isVisible = false

    private var isRestoring: Bool { store.phase == .restoring }

    private var profiles: [BotProfile] {
        return store.profiles.filter {
            searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText)
                || rowPreview($0).localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        TabView(selection: selectedTab) {
            Tab("Profiles", systemImage: "person.crop.rectangle.stack.fill", value: HomeTab.profiles) {
                homeNavigation(for: .profiles)
            }
            Tab("Bots", systemImage: "bubble.left.and.bubble.right.fill", value: HomeTab.bots) {
                homeNavigation(for: .bots)
            }
            Tab("Search", systemImage: "magnifyingglass", value: HomeTab.search, role: .search) {
                homeNavigation(for: .search)
                    .searchable(text: $searchText, isPresented: $isSearchPresented, prompt: "Search \(mode.rawValue)")
            }
        }
        .modifier(HomeSearchActivation())
        .toolbar(path.isEmpty ? .visible : .hidden, for: .tabBar)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .onChange(of: isSearching) { _, searching in
            if !searching { searchText = "" }
        }
        .onChange(of: isSearchPresented) { _, presented in
            // Closing Search returns to the list. Navigation keeps its route.
            if !presented && path.isEmpty { isSearching = false }
        }
        .onChange(of: path) { _, newPath in
            // Back to the home screen returns to the list with Search closed.
            isSearchPresented = false
            if newPath.isEmpty { isSearching = false }
        }
        .alert("Couldn’t Load Profiles", isPresented: Binding(
            get: { isVisible && store.errorMessage != nil && store.selectedProfile == nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("Try Again") { Task { await store.refreshProfiles() } }
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private func homeNavigation(for tab: HomeTab) -> some View {
        // Only the visible tab owns the route. An inactive tab must not open
        // another copy of a conversation after a notification or a reply.
        let navigationPath = Binding<[AppRoute]>(
            get: { selectedTab.wrappedValue == tab ? path : [] },
            set: { if selectedTab.wrappedValue == tab { path = $0 } }
        )
        return NavigationStack(path: navigationPath) {
            homeList
                .modifier(ContentStatusSubtitle(status: store.profileRefresh))
                .navigationTitle(mode.rawValue)
                .navigationDestination(for: AppRoute.self) { route in
                    HomeRouteDestination(route: route)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        if store.profileRefresh.phase == .failed || store.profileRefresh.phase == .unavailable {
                            Button("Retry", systemImage: "arrow.clockwise") { Task { await store.retryContentConnection() } }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Settings", systemImage: "gearshape") { store.showingSettings = true }
                            .accessibilityLabel("Settings")
                            .disabled(isRestoring || store.openingBotProfileID != nil)
                    }
                }
        }
        .toolbar(path.isEmpty ? .visible : .hidden, for: .tabBar)
    }

    private var selectedTab: Binding<HomeTab> {
        Binding(
            get: { isSearching ? .search : mode == .profiles ? .profiles : .bots },
            set: { tab in
                guard store.openingBotProfileID == nil else { return }
                switch tab {
                case .search: isSearching = true
                case .profiles, .bots:
                    mode = tab == .profiles ? .profiles : .bots
                    isSearchPresented = false
                    isSearching = false
                    searchText = ""
                }
            }
        )
    }

    private var homeList: some View {
        List {
            if #unavailable(iOS 26.0) {
                ContentStatusHeader(status: store.profileRefresh) { Task { await store.retryContentConnection() } }
                    .listRowSeparator(.hidden)
            }
            
            if !isRestoring, let notice = store.visibleCompanionUpdate {
                CompanionUpdateRow(notice: notice)
            }
            if !isRestoring, store.updateProgress != nil { CompanionUpdateProgressRow() }
            ForEach(profiles) { profile in
                if mode == .profiles {
                    NavigationLink(value: AppRoute.profile(profile.id)) {
                        profileRow(profile)
                    }
                    .accessibilityIdentifier("profile.\(profile.id)")
                    .disabled(store.openingBotProfileID != nil
                              || (store.isRunningCommand && store.selectedProfile?.id != profile.id))
                } else {
                    NavigationLink(value: AppRoute.bot(profile.id)) {
                        profileRow(profile)
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("bot.\(profile.id)")
                    .accessibilityHint("Open the existing Bot Chat for \(profile.name)")
                    .disabled(store.phase != .connected || store.openingBotProfileID != nil
                              || store.isRunningCommand || store.isLoadingMessages || store.startingCompanionUpdate)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if store.profileRefresh.phase == .idle && profiles.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No \(mode.rawValue)" : "No Results",
                    systemImage: searchText.isEmpty ? "person.crop.circle" : "magnifyingglass",
                    description: Text(searchText.isEmpty
                        ? "Create a profile in Hermes, then pull down to refresh."
                        : "Try another name."))
            }
        }
        .refreshable {
            await store.retryContentConnection()
        }
    }

    private func rowPreview(_ profile: BotProfile) -> String {
        if mode == .bots {
            let preview = profile.botSession?.preview ?? ""
            return preview.isEmpty ? "No messages" : preview
        }
        return profile.summary.isEmpty ? profile.model : profile.summary
    }

    private func profileRow(_ profile: BotProfile) -> some View {
        HStack(spacing: 12) {
            ProfileAvatar(profile: profile, address: store.settings?.address ?? "", size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).font(.headline)
                Text(rowPreview(profile))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct HomeSearchActivation: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabViewSearchActivation(.searchTabSelection)
        } else { content }
    }
}

struct ConnectionDetailsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var disconnecting = false
    @State private var showingDisconnectConfirmation = false
    @State private var localRemoval: LocalDisconnectConfirmation?
    @State private var pendingNotificationScope: Bool?

    private var savingNotifications: Bool {
        pendingNotificationScope != nil || store.notificationScopeBusy ||
            store.notificationBusy || store.notificationPreference.isSaving
    }

    private var displayedAllSessions: Bool {
        pendingNotificationScope ?? store.allSessionNotifications
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let settings = store.settings {
                        Label(store.phase == .connected ? "Connected to Hermes" : "Hermes unavailable",
                              systemImage: store.phase == .connected ? "checkmark.circle.fill" : "wifi.slash")
                            .foregroundStyle(store.phase == .connected ? Color.green : Color.secondary)
                        if let notice = store.connectionNotice { Text(notice.message).font(.footnote).foregroundStyle(.secondary) }
                        DisclosureGroup("Connection details") {
                            LabeledContent("Address", value: settings.address)
                            LabeledContent("Connection", value: settings.companion == nil ? "Direct" : "Encrypted")
                            if !settings.username.isEmpty { LabeledContent("Username", value: settings.username) }
                            Button("Disconnect", role: .destructive) {
                                showingDisconnectConfirmation = true
                            }
                            .disabled(store.isSending || savingNotifications || disconnecting)
                        }
                    }
                }
                
                    Section("Companion") {
                        if let version = store.installedCompanionVersion { LabeledContent("Installed version", value: version) }
                        if let notice = store.companionUpdate { CompanionUpdateRow(notice: notice) }
                        if store.updateProgress != nil { CompanionUpdateProgressRow() }
                        Button {
                            Task { await store.refreshCompanionUpdate(force: true) }
                        } label: {
                            HStack { Text("Check for updates"); if store.checkingCompanionUpdate { Spacer(); ProgressView() } }
                        }
                        .disabled(store.checkingCompanionUpdate || store.phase != .connected)
                        if let message = store.updateCheckMessage { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    }
                    Section("Notifications") {
                        Toggle("All sessions", isOn: Binding(get: { displayedAllSessions }, set: { value in
                            pendingNotificationScope = value
                            Task {
                                defer { pendingNotificationScope = nil }
                                await store.setAllSessionNotifications(value)
                            }
                        }))
                        .disabled(disconnecting || savingNotifications)
                        Toggle("Only Hermes Jr. sessions", isOn: Binding(get: { displayedAllSessions || (store.notificationPreference.requestedValue ?? store.notificationsEnabled) }, set: { value in
                            store.requestNotificationsEnabled(value)
                        }))
                        .disabled(disconnecting || displayedAllSessions || savingNotifications)
                        if let status = store.notificationStatus { Text(status).font(.footnote).foregroundStyle(.secondary) }
                    }
                
            }
            .modifier(NotificationPreferenceErrorPresenter(inSettings: true))
            .task { await store.refreshCompanionUpdate() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        if savingNotifications {
                            ProgressView().accessibilityLabel("Saving notification settings")
                        } else {
                            Text("Done")
                        }
                    }
                    .disabled(savingNotifications)
                }
            }
            .interactiveDismissDisabled(savingNotifications)
            .alert("Disconnect from Hermes?", isPresented: $showingDisconnectConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Disconnect", role: .destructive) {
                    disconnecting = true
                    Task {
                        defer { disconnecting = false }
                        switch await store.disconnectWithNotifications() {
                        case .disconnected: dismiss()
                        case .needsLocalRemoval(let confirmation): localRemoval = confirmation
                        case .canceled: break
                        }
                    }
                }
            } message: {
                Text("This removes the connection from this iPhone. Your conversations stay in Hermes.")
            }
            .alert("Remove Connection from This iPhone?", isPresented: Binding(
                get: { localRemoval != nil },
                set: { if !$0 { localRemoval = nil } }
            ), presenting: localRemoval) { confirmation in
                Button("Cancel", role: .cancel) { localRemoval = nil }
                Button("Remove from This iPhone", role: .destructive) {
                    if store.removeLocalConnection(confirmation) { dismiss() }
                    localRemoval = nil
                }
            } message: { _ in
                Text("Couldn’t turn off notifications on the server. Removing this connection clears its saved sign-in details from this iPhone. Notifications may continue until you revoke this phone on the Hermes host.")
            }
            .onChange(of: store.settings) { _, _ in localRemoval = nil }
            .onChange(of: store.phase) { _, phase in if phase != .connected { localRemoval = nil } }
        }
    }
}


private struct CompanionUpdateRow: View {
    @Environment(AppStore.self) private var store
    let notice: CompanionUpdateNotice
    @State private var showingDetails = false
    @State private var copied = false

    var body: some View {
        Button { showingDetails = true } label: {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Companion update available").font(.headline)
                    Text("Version \(notice.version)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: "arrow.down.circle") }
        }
        .sheet(isPresented: $showingDetails) {
            NavigationStack {
                Form {
                    Section {
                        Text("Companion \(notice.version) is available")
                            .font(.headline)
                        Text(store.updateProgress?.status == "failed"
                             ? "Try the update again in its existing Hermes conversation. This uses your normal model allowance."
                             : "Start a new conversation with your default Hermes profile to install this update. This uses your normal model allowance.")
                        Text("The connection may briefly drop while updating. Existing Hermes sessions may need a restart afterward.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button(store.updateProgress?.status == "failed" ? "Try again" : "Update with Hermes", systemImage: "sparkles") {
                            showingDetails = false
                            Task {
                                if store.updateProgress?.status == "failed" { await store.retryCompanionUpdate() }
                                else { await store.startCompanionUpdate(notice) }
                            }
                        }
                        .disabled(store.updateProgress?.status == "failed" ? !store.canRetryCompanionUpdate : !store.canStartCompanionUpdate)
                        .accessibilityIdentifier("companion.update-with-hermes")
                        Text(store.notificationsEnabled
                             ? "We’ll send a notification after the installer verifies completion."
                             : "Enable notifications in Settings to receive an update completion notification.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if store.updateProgress?.pending == true {
                            Button("Open update conversation") {
                                showingDetails = false
                                Task { await store.openUpdateConversation() }
                            }
                            .disabled(store.isSending || store.phase != .connected)
                        } else if let progress = store.updateProgress, progress.status == "failed" {
                            Text(progress.message).font(.footnote)
                        }
                        if !store.profiles.contains(where: { $0.id == "default" }) {
                            Text("The default Hermes profile is unavailable. You can copy the prompt instead.").font(.footnote)
                        }
                    }
                    Section("Or ask Hermes yourself") {
                        Button(copied ? "Copied" : "Copy update prompt") {
                            UIPasteboard.general.string = notice.installPrompt
                            copied = true
                        }
                        Link("Release notes", destination: notice.releaseURL)
                    }
                    Section {
                        Button("Not now") {
                            store.dismissCompanionUpdate()
                            showingDetails = false
                        }
                    } footer: { Text("Not now hides this version’s notice from the home screen. You can still find it in Settings.") }
                }
                .navigationTitle("Companion Update")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingDetails = false } } }
            }
        }
    }
}

private struct CompanionUpdateProgressRow: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        if let progress = store.updateProgress {
            VStack(alignment: .leading, spacing: 8) {
                Label(progress.status == "completed" ? "Companion update installed" : progress.status == "failed" ? "Companion update failed" : progress.status == "unconfirmed" ? "Check companion update" : "Updating with Hermes",
                      systemImage: progress.status == "completed" ? "checkmark.circle" : progress.status == "failed" || progress.status == "unconfirmed" ? "exclamationmark.circle" : "arrow.triangle.2.circlepath")
                    .font(.headline)
                Text(progress.message).font(.footnote).foregroundStyle(.secondary)
                Button("Open update conversation") { Task { await store.openUpdateConversation() } }
                    .disabled(store.isSending || store.isRunningCommand || store.phase != .connected)
                if progress.pending {
                    Button("Check update status") { Task { await store.refreshCompanionUpdate(force: true) } }
                        .disabled(store.checkingCompanionUpdate || store.phase != .connected)
                } else {
                    if progress.status == "failed" {
                        Button("Try again") { Task { await store.retryCompanionUpdate() } }
                            .disabled(!store.canRetryCompanionUpdate)
                            .accessibilityIdentifier("companion.update-retry")
                    }
                    Button("Dismiss") { store.dismissFinishedUpdate() }
                }
            }
            .padding(.vertical, 4)
        }
    }
}
