import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct ChatView: View {
    var sessionID: String? = nil
    var botProfile: BotProfile? = nil
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var composerFrame: CGRect = .zero
    @State private var canAnimateSends = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var draft = ""
    @State private var blockedSend: BlockedSend?

    private struct BlockedSend {
        let profileID: String?
        let sessionID: String?
        let text: String
        let photoIDs: [UUID]
    }
    @State private var isAtBottom = true
    @State private var viewportIsAtBottom = true
    @State private var conversationWidth: CGFloat = 440
    @State private var conversationHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var initialTranscriptPositioned = false
    @State private var isPositioningInitialTranscript = false
    @State private var composerHeight: CGFloat = 56
    @State private var keyboardVisible = false
    @State private var isUserScrolling = false
    @State private var keyboardReferenceView = UIView(frame: .zero)
    @State private var showsFilePicker = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var photos: [DraftPhoto] = []
    @State private var showsPhotoPicker = false
    @State private var isLoadingPhotos = false
    @State private var completedCommandDraft: String?
    @FocusState private var composerFocused: Bool
    @ScaledMetric(relativeTo: .body) private var composerButtonHeight = 28

    private var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty)
            && !store.isSending && !store.isRunningCommand && !isLoadingPhotos
            && !store.isLoadingMessages && store.selectedSession != nil && store.phase == .connected && store.sessionReady
    }

    private func scrollToLatest(using proxy: ScrollViewProxy) {
        guard !isUserScrolling else { return }
        if conversationHeight <= max(0, viewportHeight - composerHeight) {
            proxy.scrollTo("conversation-content", anchor: .top)
        } else {
            proxy.scrollTo("conversation-bottom", anchor: .bottom)
        }
    }

    private func positionInitialTranscript(using proxy: ScrollViewProxy) {
        guard !initialTranscriptPositioned, !isPositioningInitialTranscript,
              conversationHeight > 0, viewportHeight > 0,
              !store.messages.isEmpty || store.sessionReady || !store.isLoadingMessages else { return }
        isPositioningInitialTranscript = true
        Task { @MainActor in
            // NavigationStack changes the chat width during its push animation.
            // Wait for that layout to settle before showing the cached page.
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { scrollToLatest(using: proxy) }
            await Task.yield()
            withTransaction(transaction) { initialTranscriptPositioned = true }
            isPositioningInitialTranscript = false
        }
    }

    private var commandQuery: String {
        guard composerFocused, !store.isSending, !store.isRunningCommand,
              !store.isLoadingMessages, draft != completedCommandDraft else { return "" }
        let text = draft.drop(while: { $0 == " " || $0 == "\t" })
        return text.hasPrefix("/") ? String(text) : ""
    }

    private var hasPendingPrompt: Bool {
        store.pendingApproval != nil || store.pendingClarification != nil
    }

    private var visibleMessages: [ChatMessage] {
        store.visibleWindowMessages.filter { !($0.role == "assistant" && $0.isStreaming && $0.text.isEmpty) }
    }

    private func showsTimestamp(at index: Int, in messages: [ChatMessage]) -> Bool {
        guard let date = messages[index].timestamp else { return false }
        guard index > 0, let previous = messages[index - 1].timestamp else { return true }
        return !Calendar.current.isDate(date, inSameDayAs: previous) || date.timeIntervalSince(previous) >= 300
    }

    private func timestampLabel(_ date: Date) -> String {
        let day: String
        if Calendar.current.isDateInToday(date) { day = "Today" }
        else if Calendar.current.isDateInYesterday(date) { day = "Yesterday" }
        else { day = date.formatted(date: .abbreviated, time: .omitted) }
        return day + " " + date.formatted(date: .omitted, time: .shortened)
    }

    private var headerActivity: String? {
        if hasPendingPrompt { return store.activity }
        if store.isSending { return store.activity ?? "Thinking…" }
        if store.isRunningCommand { return store.activity ?? "Running command…" }
        return nil
    }

    private var sessionTitle: String {
        if botProfile != nil || store.selectedSession?.title == "Bot Chat" { return "" }
        guard let sessionID else { return store.selectedSession?.name ?? "" }
        if let session = store.sessions.first(where: { $0.id == sessionID }) { return session.name }
        if let session = store.selectedSession, session.id == sessionID { return session.name }
        return ""
    }

    private var conversationContent: some View {
        let visibleMessages = self.visibleMessages
        let lastUserID = visibleMessages.last(where: { $0.role == "user" })?.id
        let hasUnread = store.selectedProfile.map {
            store.isSessionUnread(sessionID ?? store.selectedSession?.id ?? "", profile: $0.id)
        } ?? false
        return ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                transcriptViewport(visibleMessages, lastUserID: lastUserID, hasUnread: hasUnread, using: proxy)
                .onChange(of: store.sessionReady) { _, ready in
                    guard ready else { return }
                    if !initialTranscriptPositioned {
                        positionInitialTranscript(using: proxy)
                        return
                    }
                    guard isAtBottom, !isUserScrolling else { return }
                    Task { @MainActor in
                        await Task.yield()
                        scrollToLatest(using: proxy)
                    }
                }
                .onChange(of: conversationHeight) { oldHeight, newHeight in
                    if !initialTranscriptPositioned {
                        positionInitialTranscript(using: proxy)
                        return
                    }
                    guard newHeight != oldHeight, isAtBottom, !isUserScrolling else { return }
                    scrollToLatest(using: proxy)
                }
                .onChange(of: viewportHeight) { _, _ in
                    if initialTranscriptPositioned, isAtBottom, !isUserScrolling {
                        scrollToLatest(using: proxy)
                    } else {
                        positionInitialTranscript(using: proxy)
                    }
                }
                .onChange(of: composerFocused) { _, focused in
                    if focused { Task { @MainActor in await Task.yield(); scrollToLatest(using: proxy) } }
                }
            }
            // A persistent overlay lets messages pass behind the glass controls.
            // Content margins leave the final message reachable above the input.
            composer.fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
        }
        .coordinateSpace(name: "conversation-animation")
        .onAppear { canAnimateSends = true }
        .background(Color(uiColor: .systemBackground))
        .background(KeyboardWindowReference(view: keyboardReferenceView).allowsHitTesting(false))
    }

    private var conversationNavigation: some View {
        conversationContent
        .modifier(ChatNavigationTitle(botName: botProfile?.name ?? store.selectedProfile?.name ?? "Hermes",
                                      sessionTitle: sessionTitle, status: conversationStatus, activity: headerActivity))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.conversationRefresh.phase == .unavailable || store.conversationRefresh.phase == .failed {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Retry", systemImage: "arrow.clockwise") {
                        Task {
                            if let botProfile { await store.openBotConversation(botProfile) }
                            else { await store.retryContentConnection() }
                        }
                    }
                }
            }
        }
        .task(id: botProfile?.id) {
            if let botProfile { await store.openBotConversation(botProfile) }
        }
        .task(id: commandQuery) {
            await store.updateCommandSuggestions(commandQuery)
        }
        .onChange(of: store.commandDraft) { _, value in
            guard let value else { return }
            draft = value
            store.commandDraft = nil
            composerFocused = true
        }
    }

    private var conversationCommands: some View {
        conversationNavigation
        .sheet(item: Binding(get: { store.commandResult }, set: { store.commandResult = $0 })) { result in
            NavigationStack {
                ScrollView {
                    Text(result.text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(result.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { store.commandResult = nil }
                    }
                }
            }
        }
        .confirmationDialog("Run Hermes Command", isPresented: Binding(
            get: { store.pendingCommandConfirmation != nil },
            set: { if !$0 { store.cancelPendingCommand() } }
        ), titleVisibility: .visible) {
            Button("Run Command") { store.confirmPendingCommand() }
            Button("Cancel", role: .cancel) { store.cancelPendingCommand() }
        } message: {
            Text(store.pendingCommandConfirmation?.message ?? "")
        }
    }

    private var conversationAttachments: some View {
        conversationCommands
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            guard let window = keyboardReferenceView.window,
                  let screen = window.windowScene?.screen,
                  let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            // Keyboard frames are in screen coordinates; this chat may occupy only part of that screen.
            if let keyboardScreen = notification.object as? UIScreen, keyboardScreen !== screen { return }
            let localFrame = screen.coordinateSpace.convert(frame, to: window)
            let overlap = window.bounds.intersection(localFrame)
            let visible = !overlap.isNull && overlap.width > 0 && overlap.height > 1
            let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            withAnimation(.easeOut(duration: duration)) { keyboardVisible = visible }
        }
        .fileImporter(isPresented: $showsFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            Task { await loadFiles(result) }
        }
        .photosPicker(isPresented: $showsPhotoPicker, selection: $selectedPhotos,
                      maxSelectionCount: max(1, 4 - photos.count), matching: .images)
        .onChange(of: selectedPhotos) { _, selection in
            Task { await loadPhotos(selection) }
        }
    }

    private var conversationPrompts: some View {
        conversationAttachments
        .sheet(isPresented: Binding(get: { hasPendingPrompt }, set: { _ in })) {
            NavigationStack {
                Group {
                    if let approval = store.pendingApproval {
                        ApprovalForm(command: approval.command, choices: approval.choices) { choice in
                            await store.resolveApproval(choice)
                        }
                        .id(approval.id)
                    } else if let clarification = store.pendingClarification {
                        ClarificationForm(question: clarification.question, choices: clarification.choices) { answer in
                            await store.resolveClarification(answer)
                        }
                        .id(clarification.id)
                    }
                }
                .navigationTitle(store.pendingApproval != nil ? "Permission Needed" : "Reply to Hermes")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Stop", role: .destructive) { Task { await store.stop() } }
                            .disabled(!store.isSending)
                    }
                }
                .alert(store.pendingSessionHandoff != nil || store.canRequestSessionHandoff ? "Move session here?" : "Unable to Continue", isPresented: Binding(
                    get: { store.errorMessage != nil },
                    set: { if !$0 { store.errorMessage = nil } }
                )) {
                    Button("OK", role: .cancel) { store.errorMessage = nil }
                } message: {
                    Text((store.errorMessage ?? "").components(separatedBy: "\nDetails:").first ?? "")
                }
            }
            .interactiveDismissDisabled()
        }
    }

    var body: some View {
        conversationPrompts
        .safeAreaInset(edge: .top) {
            if let progress = store.selectedUpdateProgress, ["failed", "unconfirmed"].contains(progress.status) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(progress.status == "failed" ? "Companion update failed" : "Check companion update", systemImage: "exclamationmark.circle")
                        .font(.headline)
                    Text(progress.message).font(.footnote).foregroundStyle(.secondary)
                    if progress.status == "failed" {
                        Button("Try again") { Task { await store.retryCompanionUpdate() } }
                            .disabled(!store.canRetryCompanionUpdate)
                            .accessibilityIdentifier("companion.update-retry")
                    } else {
                        Button("Check update status") { Task { await store.refreshCompanionUpdate(force: true) } }
                            .disabled(store.checkingCompanionUpdate || store.phase != .connected)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding().background(.regularMaterial)
            }
        }
        .alert(store.pendingSessionHandoff != nil || store.canRequestSessionHandoff ? "Move session here?" : "Unable to Continue", isPresented: Binding(
            get: { store.errorMessage != nil && !hasPendingPrompt },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            if store.pendingSessionHandoff != nil {
                Button("Close CLI and Continue", role: .destructive) {
                    Task { if await store.confirmSessionHandoff() { sendAfterHandoff() } }
                }
            } else if store.canRequestSessionHandoff {
                Button("Continue on iPhone…") { Task { if await store.prepareSessionHandoff() { sendAfterHandoff() } } }
            }
            if let botProfile, store.messages.isEmpty {
                Button("Retry") { Task { await store.openBotConversation(botProfile) } }
            } else if store.messages.isEmpty,
               let session = store.selectedSession ?? store.sessions.first(where: { $0.id == sessionID }) {
                Button("Retry") { Task { await store.openSession(session) } }
            }
            Button("Cancel", role: .cancel) {
                store.errorMessage = nil
                store.pendingSessionHandoff = nil
                blockedSend = nil
            }
        } message: {
            Text((store.errorMessage ?? "").components(separatedBy: "\nDetails:").first ?? "")
        }
    }

    private func transcriptContent(_ visibleMessages: [ChatMessage], lastUserID: String?,
                                   hasUnread: Bool, using proxy: ScrollViewProxy) -> some View {
        ScrollView {
            // The bounded window stays eager so a very tall bubble
            // never changes its estimated height while scrolling.
            VStack(alignment: .leading, spacing: 0) {
                transcriptRows(visibleMessages, lastUserID: lastUserID, hasUnread: hasUnread, using: proxy)
            }
            .scrollTargetLayout()
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { conversationHeight = $0 }
        }
        .contentMargins(.bottom, composerHeight, for: .scrollContent)
        .opacity(initialTranscriptPositioned ? 1 : 0)
        .allowsHitTesting(initialTranscriptPositioned)
        .overlay {
            if !initialTranscriptPositioned && botProfile == nil {
                ProgressView("Opening conversation…")
                    .padding(.bottom, composerHeight)
            }
        }
        .accessibilityIdentifier("chat.transcript")
        .scrollDismissesKeyboard(.interactively)
    }

    private func transcriptViewport(_ visibleMessages: [ChatMessage], lastUserID: String?,
                                    hasUnread: Bool, using proxy: ScrollViewProxy) -> some View {
        transcriptContent(visibleMessages, lastUserID: lastUserID, hasUnread: hasUnread, using: proxy)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height + geometry.contentInsets.bottom
                - geometry.contentOffset.y - geometry.containerSize.height <= 80
        } action: { (_: Bool, atBottom: Bool) in
            viewportIsAtBottom = atBottom
            // Content growth must not disable following an active reply.
            if isUserScrolling { isAtBottom = atBottom }
        }
        .onScrollPhaseChange { _, phase in
            let wasScrolling = isUserScrolling
            isUserScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            if wasScrolling && !isUserScrolling { isAtBottom = viewportIsAtBottom }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: {
            conversationWidth = $0.width
            viewportHeight = $0.height
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(isAtBottom ? .bottom : .top, for: .sizeChanges)
        .defaultScrollAnchor(.top, for: .alignment)
    }

    @ViewBuilder
    private func transcriptRows(_ visibleMessages: [ChatMessage], lastUserID: String?,
                                hasUnread: Bool, using proxy: ScrollViewProxy) -> some View {
        Color.clear.frame(height: 12).id("conversation-content")
        if store.hasEarlierLoadedMessages || store.hasOlderMessages {
            Button {
                loadOlder(using: proxy)
            } label: {
                if store.isLoadingOlderMessages { ProgressView() }
                else { Text(hasUnread ? "Earlier unread messages" : "Earlier messages") }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .disabled(store.isLoadingOlderMessages)
            .accessibilityIdentifier("chat.loadOlder")
            .id("history-top-\(store.olderPageVersion)-\(store.messageWindowStart)")
        }

        if store.isLoadingMessages && visibleMessages.isEmpty && botProfile == nil {
            ProgressView("Loading conversation…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .accessibilityIdentifier("chat.loading")
        }

        if store.conversationRefresh.phase == .idle && store.messages.isEmpty && !store.isSending {
            ContentUnavailableView(
                "New Message",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Send a message to \(store.selectedProfile?.name ?? "Hermes").")
            )
        }

        ForEach(Array(visibleMessages.enumerated()), id: \.element.id) { index, message in
            if let date = message.timestamp, showsTimestamp(at: index, in: visibleMessages) {
                Text(timestampLabel(date))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, index == 0 ? 0 : 16).padding(.bottom, 8)
                    .accessibilityIdentifier("chat.timestamp")
            }
            MessageRow(
                message: message,
                minimumOppositeSpace: max(0, conversationWidth - 40 - min(560, (conversationWidth - 40) * 0.78)),
                hasTail: index == visibleMessages.count - 1 || visibleMessages[index + 1].role != message.role,
                animateSend: canAnimateSends && message.delivery == .sending,
                composerFrame: message.delivery == .sending ? composerFrame : .zero
            )
                .equatable()
                .padding(.top, index == 0 ? 0 : (visibleMessages[index - 1].role == message.role ? 4 : 12))
                .id(message.id)
                .onAppear { noteVisibleMessage(message.id, firstID: visibleMessages.first?.id) }
                .onChange(of: store.sessionReady) { _, ready in
                    if ready { noteVisibleMessage(message.id, firstID: visibleMessages.first?.id) }
                }
                .onChange(of: store.hasOlderMessages) { _, _ in
                    noteVisibleMessage(message.id, firstID: visibleMessages.first?.id)
                }
            if message.role == "user", let delivery = message.delivery,
               message.id == lastUserID || delivery != .delivered {
                Text(delivery == .sending ? "Sending…" : delivery == .delivered ? "Delivered" : "Delivery unknown")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 20).padding(.top, 6)
                    .contentTransition(.opacity)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: delivery)
                    .accessibilityIdentifier("chat.delivery")
            }
        }
        if store.hasNewerLoadedMessages {
            Button("Newer messages") { showNewer(using: proxy) }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .accessibilityIdentifier("chat.loadNewer")
                .id("history-bottom-\(store.messageWindowStart)")
        }

        Color.clear.frame(height: 1).id("conversation-bottom")
    }

    private var conversationStatus: ContentRefreshStatus {
        if let botProfile, store.selectedProfile?.id != botProfile.id {
            return ContentRefreshStatus(phase: .checking)
        }
        return store.conversationRefresh
    }

    private func loadOlder(using proxy: ScrollViewProxy) {
        guard !store.isLoadingOlderMessages else { return }
        let preservePosition = conversationHeight > max(0, viewportHeight - composerHeight)
        if let anchor = store.showEarlierLoadedMessages() {
            if preservePosition { Task { await Task.yield(); proxy.scrollTo(anchor, anchor: .top) } }
            return
        }
        guard store.hasOlderMessages else { return }
        Task {
            guard let anchor = await store.loadOlderMessages(), preservePosition else { return }
            await Task.yield()
            proxy.scrollTo(anchor, anchor: .top)
        }
    }

    private func showNewer(using proxy: ScrollViewProxy) {
        guard let anchor = store.showNewerLoadedMessages() else { return }
        Task { await Task.yield(); proxy.scrollTo(anchor, anchor: .bottom) }
    }

    private func noteVisibleMessage(_ id: String, firstID: String?) {
        guard store.sessionReady, let profile = store.selectedProfile, let session = store.selectedSession,
              session.id == sessionID, store.isSessionUnread(session.id, profile: profile.id) else { return }
        let boundary = store.unreadBoundary(profile: profile.id, sessionID: session.id)
        if id == boundary || (!store.hasOlderMessages && !store.hasEarlierLoadedMessages && id == firstID) {
            store.markSessionRead(session.id, profile: profile.id)
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            if !commandQuery.isEmpty {
                CommandSuggestionsView(
                    suggestions: store.commandSuggestions,
                    isLoading: store.isLoadingCommands,
                    error: store.commandError,
                    hint: store.availableCommands.first(where: {
                        $0.text.trimmingCharacters(in: .whitespaces) == commandQuery.components(separatedBy: .whitespacesAndNewlines).first
                    })?.description,
                    select: { suggestion in
                        draft = suggestion.text
                        if !draft.contains(where: \.isWhitespace) {
                            draft += " "
                        }
                        let finished = (suggestion.argumentMode == nil && suggestion.kind != "skill")
                            || (suggestion.argumentMode == "options" && suggestion.text.contains(where: \.isWhitespace))
                        completedCommandDraft = finished ? draft : nil
                        composerFocused = true
                    },
                    retry: { Task { await store.updateCommandSuggestions(commandQuery) } }
                )
            }
            composerControls
        }
    }

    private var composerControls: some View {
        VStack(spacing: 8) {
            if !photos.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(photos) { photo in
                            if photo.isFile == true {
                                VStack(spacing: 4) {
                                    Image(systemName: "doc.fill").font(.title2)
                                    Text(photo.filename).font(.caption).lineLimit(2)
                                }
                                .frame(width: 100, height: 80)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(alignment: .topTrailing) {
                                    Button("Remove File", systemImage: "xmark.circle.fill") {
                                        photos.removeAll { $0.id == photo.id }
                                    }
                                    .labelStyle(.iconOnly).padding(4)
                                    .disabled(isLoadingPhotos)
                                }
                            } else if let image = UIImage(data: photo.data) {
                                Image(uiImage: image)
                                    .resizable().scaledToFill()
                                    .frame(width: 80, height: 80)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay(alignment: .topTrailing) {
                                        Button("Remove Photo", systemImage: "xmark.circle.fill") {
                                            photos.removeAll { $0.id == photo.id }
                                        }
                                        .labelStyle(.iconOnly)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                        .padding(4)
                                        .disabled(isLoadingPhotos)
                                    }
                            }
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 12) {
                composerAddButton.padding(.bottom, 2)
                composerInput
            }
        }
        .padding(.horizontal, keyboardVisible ? 20 : 28)
        .padding(.top, 8)
        .padding(.bottom, keyboardVisible ? 16 : -6)
    }

    @ViewBuilder private var composerAddButton: some View {
        let button = Menu {
            Button("Photos", systemImage: "photo.on.rectangle") { showsPhotoPicker = true }
                .disabled(isLoadingPhotos || store.isSending || store.isRunningCommand || photos.count >= 4)
            Button("Files", systemImage: "folder") { showsFilePicker = true }
                .disabled(isLoadingPhotos || store.isSending || store.isRunningCommand || photos.count >= 4)
        } label: {
            Group {
                if isLoadingPhotos { ProgressView().controlSize(.small) }
                else { Image(systemName: "plus").font(.system(size: 22, weight: .regular)) }
            }
            .foregroundStyle(.primary)
            .frame(width: 40, height: 40)
            .contentShape(Circle())
        }
        .accessibilityLabel("Add to Message")
        .accessibilityIdentifier("chat.add")
        .tint(.primary)

        if #available(iOS 26.0, *) { button.glassEffect(.regular.interactive(), in: .circle) }
        else { button.background(.bar, in: Circle()) }
    }

    @ViewBuilder private var composerInput: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        let input = HStack(alignment: .bottom, spacing: 0) {
            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body.leading(.tight))
                .lineLimit(1...(dynamicTypeSize.isAccessibilitySize ? 3 : 6))
                .focused($composerFocused)
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .accessibilityLabel("Message")
                .accessibilityIdentifier("chat.composer")

            if store.isRunningCommand {
                ProgressView()
                    .frame(width: 40, height: 40)
                    .accessibilityLabel("Running command")
            } else if store.isSending {
                Button { Task { await store.stop() } } label: {
                    composerSymbol("stop.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop response")
                .accessibilityIdentifier("chat.stop")
            } else if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty {
                Button(action: send) {
                    composerSymbol("arrow.up")
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.35)
                .accessibilityLabel(draft.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") ? "Run command" : "Send message")
                .accessibilityIdentifier("chat.send")
            }
        }

        if #available(iOS 26.0, *) {
            input.frame(minHeight: 44)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("conversation-animation")) } action: { composerFrame = $0 }
                .glassEffect(.regular, in: shape)
        } else {
            input.frame(minHeight: 44)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("conversation-animation")) } action: { composerFrame = $0 }
                .background(.bar, in: shape)
                .overlay(shape.strokeBorder(Color(uiColor: .separator), lineWidth: 0.5))
        }
    }

    private func composerSymbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: name == "stop.fill" ? 13 : 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: composerButtonHeight + 10, height: composerButtonHeight)
            .background(Color.accentColor, in: Capsule())
            .frame(width: max(50, composerButtonHeight + 22), height: max(44, composerButtonHeight + 16))
            .contentShape(Rectangle())
    }

    private func sendAfterHandoff() {
        guard let pending = blockedSend,
              pending.profileID == store.selectedProfile?.id,
              pending.sessionID == store.selectedSession?.id,
              pending.text == draft.trimmingCharacters(in: .whitespacesAndNewlines),
              pending.photoIDs == photos.map(\.id), canSend else { return }
        blockedSend = nil
        send()
    }

    private func send() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentPhotos = photos
        let sentProfileID = store.selectedProfile?.id
        let sentSessionID = store.selectedSession?.id
        blockedSend = nil
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            draft = ""
            photos = []
            selectedPhotos = []
        }
        isAtBottom = true
        Task {
            let accepted = await store.send(text, photos: sentPhotos)
            if !accepted {
                if store.canRequestSessionHandoff {
                    blockedSend = BlockedSend(profileID: sentProfileID, sessionID: sentSessionID,
                                              text: text, photoIDs: sentPhotos.map(\.id))
                }
                if draft.isEmpty { draft = text }
                if photos.isEmpty { photos = sentPhotos }
            }
        }
    }

    private func loadFiles(_ result: Result<[URL], Error>) async {
        isLoadingPhotos = true
        defer { isLoadingPhotos = false }
        do {
            let urls = try result.get()
            guard urls.count <= 4 - photos.count else {
                throw HermesError.message("You can attach up to four files or photos per message.")
            }
            let loaded = try await Task.detached(priority: .userInitiated) {
                try urls.map { url in
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard values.isRegularFile == true else { throw HermesError.message("Choose files rather than folders.") }
                    guard let size = values.fileSize, size > 0, size <= 25 * 1024 * 1024 else {
                        throw HermesError.message("Each file must be nonempty and no larger than 25 MB.")
                    }
                    let data = try Data(contentsOf: url)
                    guard !data.isEmpty, data.count <= 25 * 1024 * 1024 else {
                        throw HermesError.message("Each file must be nonempty and no larger than 25 MB.")
                    }
                    return DraftPhoto(data: data, filename: url.lastPathComponent, isFile: true)
                }
            }.value
            photos.append(contentsOf: loaded)
        } catch { store.errorMessage = error.localizedDescription }
    }

    private func loadPhotos(_ selection: [PhotosPickerItem]) async {
        guard !selection.isEmpty else { return }
        isLoadingPhotos = true
        defer {
            isLoadingPhotos = false
            // Each picker presentation adds a fresh batch. Removed tray photos
            // must not remain selected and reappear the next time it opens.
            selectedPhotos = []
        }
        do {
            var loaded: [DraftPhoto] = []
            for item in selection {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data),
                      let jpeg = image.jpegData(compressionQuality: 0.85) else {
                    throw PhotoError.unreadable
                }
                guard jpeg.count <= 25 * 1024 * 1024 else { throw PhotoError.tooLarge }
                loaded.append(DraftPhoto(data: jpeg, filename: "photo-\(UUID().uuidString).jpg"))
            }
            photos.append(contentsOf: loaded.prefix(max(0, 4 - photos.count)))
        } catch { store.errorMessage = error.localizedDescription }
    }

    private enum PhotoError: LocalizedError {
        case unreadable, tooLarge
        var errorDescription: String? {
            switch self {
            case .unreadable: return "This photo couldn’t be opened. Please choose another photo."
            case .tooLarge: return "Choose a photo smaller than 25 MB."
            }
        }
    }
}

/// Resolves the window that actually hosts this chat, including iPad and mirrored windows.
private struct KeyboardWindowReference: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Keep the final row layout stable while its bubble emerges from the composer.
/// Background width changes independently so the message glyphs never stretch.
private struct OutgoingSendAnimation: ViewModifier {
    let composerFrame: CGRect
    let hasTail: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contraction: CGFloat
    @State private var travel: CGFloat
    @State private var sourceFrame: CGRect?

    init(enabled: Bool, composerFrame: CGRect, hasTail: Bool) {
        self.composerFrame = composerFrame
        self.hasTail = hasTail
        _contraction = State(initialValue: enabled ? 0 : 1)
        _travel = State(initialValue: enabled ? 0 : 1)
    }

    func body(content: Content) -> some View {
        let source = sourceFrame ?? composerFrame
        let widthProgress = reduceMotion || source.isEmpty ? 1 : contraction
        let flightProgress = reduceMotion || source.isEmpty ? 1 : travel
        let flightOpacity: Double = reduceMotion ? 0.25 + 0.75 * travel : 1
        content
            .visualEffect { effect, geometry in
                effect.offset(
                    x: -(source.width - geometry.size.width) * (1 - widthProgress)
                )
            }
            .background {
                GeometryReader { geometry in
                    let width = max(1, geometry.size.width + (source.width - geometry.size.width) * (1 - widthProgress))
                    let height = max(1, geometry.size.height + (source.height - geometry.size.height) * (1 - widthProgress))
                    RoundedRectangle(cornerRadius: 20 + 2 * (1 - widthProgress), style: .continuous)
                        .fill(.blue)
                        .overlay {
                            MessageBubble(outgoing: true, hasTail: hasTail)
                                .fill(.blue)
                                .opacity(min(1, max(0, widthProgress)))
                        }
                        .frame(width: width, height: height)
                        .offset(x: geometry.size.width - width)
                }
            }
            .visualEffect { effect, geometry in
                let destination = geometry.frame(in: .named("conversation-animation"))
                return effect
                    .offset(x: (source.maxX - destination.maxX) * (1 - flightProgress),
                            y: max(0, source.minY - destination.minY) * (1 - flightProgress))
                    .opacity(flightOpacity)
            }
            .task {
                guard travel == 0 else { return }
                sourceFrame = composerFrame
                // Give SwiftUI one frame to commit the composer-sized start shape.
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.72)) {
                    contraction = 1
                }
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.46, dampingFraction: 0.86)) {
                    travel = 1
                }
            }
    }
}

private struct MessageRow: View, Equatable {
    let message: ChatMessage
    var minimumOppositeSpace: CGFloat = 88
    var hasTail = true
    var animateSend = false
    var composerFrame: CGRect = .zero
    private var isPhotoOnly: Bool { !message.photos.isEmpty && message.photos.allSatisfy { $0.isFile != true } && message.text.isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if message.role == "user" { Spacer(minLength: minimumOppositeSpace) }
            Group {
                messageContent
                    .padding(.horizontal, isPhotoOnly ? 0 : 15)
                    .padding(.vertical, isPhotoOnly ? 0 : 10)
                    .foregroundStyle(message.role == "user" ? Color.white : Color.primary)
                    .modifier(MessageBubblePresentation(
                        outgoing: message.role == "user", photoOnly: isPhotoOnly,
                        hasTail: hasTail, animateSend: animateSend && message.photos.isEmpty,
                        composerFrame: composerFrame))
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = message.text
                        }
                    }
            }
            if message.role != "user" { Spacer(minLength: minimumOppositeSpace) }
        }
    }

    @ViewBuilder private var messageContent: some View {
        if message.role == "user" {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(message.photos) { photo in
                    if photo.isFile == true {
                        Label(photo.filename, systemImage: "doc.fill")
                            .font(.body).lineLimit(3)
                    } else if let image = UIImage(data: photo.data) {
                        Image(uiImage: image)
                            .resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .accessibilityLabel("Attached photo")
                    }
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.body.leading(.tight))
                        .textSelection(.enabled)
                        .accessibilityLabel("You: \(message.text)")
                }
            }
        } else if message.role == "tool" {
            DisclosureGroup {
                Text(message.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } label: {
                Label("Tool output", systemImage: "wrench.and.screwdriver")
                    .font(.subheadline)
            }
        } else if !message.text.isEmpty {
            MarkdownMessage(text: message.text)
        }
    }
}

private struct MessageBubblePresentation: ViewModifier {
    let outgoing: Bool
    let photoOnly: Bool
    let hasTail: Bool
    let animateSend: Bool
    let composerFrame: CGRect

    func body(content: Content) -> some View {
        if outgoing && !photoOnly {
            content.modifier(OutgoingSendAnimation(enabled: animateSend,
                                                  composerFrame: composerFrame, hasTail: hasTail))
        } else {
            content.background(photoOnly ? Color.clear : Color(uiColor: .secondarySystemFill),
                               in: MessageBubble(outgoing: outgoing, hasTail: hasTail))
        }
    }
}

private struct MessageBubble: Shape {
    var outgoing: Bool
    var hasTail: Bool

    func path(in rect: CGRect) -> Path {
        let path = Path(roundedRect: rect, cornerRadius: 20)
        guard hasTail else { return path }
        var tail = Path()
        let w = rect.maxX
        let h = rect.maxY
        tail.move(to: CGPoint(x: w - 22, y: h - 5))
        tail.addCurve(to: CGPoint(x: w - 6, y: h + 6),
                      control1: CGPoint(x: w - 17, y: h + 2),
                      control2: CGPoint(x: w - 10, y: h + 6))
        tail.addQuadCurve(to: CGPoint(x: w - 11, y: h - 12), control: CGPoint(x: w - 12, y: h))
        tail.closeSubpath()
        if !outgoing {
            tail = tail.applying(CGAffineTransform(translationX: rect.width, y: 0).scaledBy(x: -1, y: 1))
        }
        return path.union(tail)
    }
}

private struct ChatNavigationTitle: ViewModifier {
    let botName: String
    let sessionTitle: String
    let status: ContentRefreshStatus
    let activity: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settledUpdate: Date?

    func body(content: Content) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let showingStatus = status.phase != .idle || status.updatedAt.map {
                settledUpdate != $0 && Date().timeIntervalSince($0) < 3
            } == true
            let subtitle = activity ?? (showingStatus ? status.text(now: context.date) : sessionTitle)
            content
                .navigationTitle(botName)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 2) {
                            Text(botName).font(.headline).lineLimit(1)
                            if !subtitle.isEmpty {
                                Text(subtitle)
                                .font(.subheadline).foregroundStyle(.secondary)
                                .lineLimit(1)
                                .modifier(ActivityTextShimmer(active: activity != nil))
                                .contentTransition(.opacity)
                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: subtitle)
                                .accessibilityIdentifier("chat.headerStatus")
                            }
                        }
                    }
                }
        }
        .task(id: status.updatedAt) {
            guard let updatedAt = status.updatedAt else { return }
            let remaining = max(0, 3 - Date().timeIntervalSince(updatedAt))
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            settledUpdate = updatedAt
        }
    }
}

private struct ApprovalForm: View {
    let command: String
    let choices: [String]
    let choose: (String) async -> Void
    @State private var selectedChoice: String?

    private func title(for choice: String) -> String {
        switch choice.lowercased() {
        case "once": return "Allow Once"
        case "always": return "Always Allow"
        case "deny", "reject": return "Deny"
        case "session": return "Allow This Session"
        default: return choice.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var body: some View {
        Form {
            Section("Command") {
                Text(command)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            Section {
                ForEach(choices, id: \.self) { choice in
                    Button(title(for: choice), role: ["deny", "reject"].contains(choice.lowercased()) ? .destructive : nil) {
                        selectedChoice = choice
                        Task {
                            await choose(choice)
                            selectedChoice = nil
                        }
                    }
                    .disabled(selectedChoice != nil)
                }
                if selectedChoice != nil { ProgressView("Sending response…") }
            } footer: {
                Text("Hermes needs your permission to run this command.")
            }
        }
    }
}

private struct ClarificationForm: View {
    let question: String
    let choices: [String]
    let answer: (String) async -> Void
    @State private var customAnswer = ""
    @State private var isSubmitting = false

    var body: some View {
        Form {
            Section("Question") {
                MarkdownMessage(text: question)
            }
            if !choices.isEmpty {
                Section("Choose a Reply") {
                    ForEach(choices, id: \.self) { choice in
                        Button(choice) { submit(choice) }
                    }
                }
            }
            Section(choices.isEmpty ? "Your Reply" : "Or Write a Reply") {
                TextField("Message", text: $customAnswer, axis: .vertical)
                    .lineLimit(1...6)
                    .accessibilityLabel("Answer Hermes’s question")
                Button("Send") { submit(customAnswer) }
                    .disabled(customAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if isSubmitting { ProgressView("Sending response…") }
            }
        }
        .disabled(isSubmitting)
    }

    private func submit(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        Task {
            await answer(value)
            isSubmitting = false
        }
    }
}
