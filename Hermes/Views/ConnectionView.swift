import SwiftUI
import UIKit
import AVFoundation

enum HermesCompanionSetup {
    // Legacy fallback for older servers/saved attempts; new prompts come from the relay.
    static func prompt(ticket: String) -> String {
        """
        Install the Hermes Jr. plugin from https://github.com/cyberculturedhq/hermes-jr-companion and connect my iPhone.

        Setup ticket:
        \(ticket)
        """
    }

}

struct ConnectionView: View {
    var onFinished: () -> Void = {}
    @State private var video = OnboardingVideo()
    @State private var videoFinished = false
    @State private var showingSuccess = false
    @State private var pageOpacity = 1.0
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var setup = SetupPairing()
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var token = ""
    private enum SignInMethod { case password, token }
    @State private var signInMethod: SignInMethod = .password
    @State private var path: [Step] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Step: Hashable { case install, handoff, waiting, verify, address }
    @State private var sharedSetupPrompt: SharedSetupPrompt?
    @State private var showCancelSetup = false
    @State private var showNotificationsOff = false
    @State private var showSetupUnavailable = false
    @State private var showSetupRateLimited = false
    private enum PromptAction { case copy, share }
    @State private var advancingPromptAction: PromptAction?
    @State private var preparingShare = false
    @State private var setupPromptCopied = false
    @State private var creatingSetupPrompt = false
    @State private var sharedPromptCompleted = false
    @State private var copyFeedbackTask: Task<Void, Never>?
    @State private var codesRejected = false
    @State private var selectedComparisonID: String?
    @State private var pairingError: String?
    @State private var pairingInProgress = false
    @FocusState private var focusedField: Field?

    private enum Field { case address, username, password, token }
    private var isConnecting: Bool { store.phase == .connecting }
    private var connectionReady: Bool { store.phase == .connected }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // One persistent player surface, outside the changing step content.
                ZStack(alignment: .top) {
                    OnboardingVideoHeader(video: video)
                        .allowsHitTesting(false)
                        HStack {
                            Button {
                                focusedField = nil
                                navigate(to: Array(path.dropLast()))
                            } label: {
                                Image(systemName: "chevron.left")
                                    .font(.title3.weight(.semibold))
                                    .frame(width: 30, height: 30)
                            }
                            .modifier(OnboardingBackButtonStyle())
                            .accessibilityLabel("Back")
                            .accessibilityIdentifier("connection.back")
                            .opacity(showsNavigation ? 1 : 0)
                            .offset(y: showsNavigation || reduceMotion ? 0 : -8)
                            .animation(headerAnimation, value: showsNavigation)
                            .disabled(!showsNavigation)
                            .accessibilityHidden(!showsNavigation)
                            Spacer()
                            if (path.last == .waiting || path.last == .verify) && store.phase != .connected {
                                Button { showCancelSetup = true } label: {
                                    Image(systemName: "xmark")
                                        .font(.title3.weight(.semibold))
                                        .frame(width: 30, height: 30)
                                }
                                .modifier(OnboardingBackButtonStyle())
                                .accessibilityLabel("Cancel setup")
                                .accessibilityIdentifier("connection.cancelSetup")
                            }
                        }
                        .frame(height: 44)
                        .foregroundStyle(.white)
                        .tint(.white)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                    }
                    .padding(.top, geometry.safeAreaInsets.top)
                    .background(OnboardingVideo.blue)
                onboardingContent
                    .opacity(pageOpacity)
                    .allowsHitTesting(!connectionReady || showingSuccess)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemGroupedBackground))
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .alert("Notifications are off in Settings.", isPresented: $showNotificationsOff) {
            Button("Open Notification Settings") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Dismiss", role: .cancel) {}
        } message: {
            Text("You can still finish setup on this screen.")
        }
        .alert("Please wait before trying again", isPresented: $showSetupRateLimited) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Too many setup prompts were requested. Try again in a minute.")
        }
        .alert("Setup is unavailable", isPresented: $showSetupUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The setup service could not prepare a prompt. Please try again later.")
        }
        .alert("Cancel this setup?", isPresented: $showCancelSetup) {
            Button("Keep setting up", role: .cancel) {}
            Button("Cancel setup", role: .destructive) {
                resetSetup()
                navigate(to: [.install])
            }
        } message: {
            Text("You’ll need a new setup prompt to try again. Companion can stay installed.")
        }
        .task(id: connectionReady) {
            guard connectionReady else {
                video.player.pause()
                showingSuccess = false
                pageOpacity = 1
                return
            }
            focusedField = nil
            // Start on confirmed connection, while the previous page fades away.
            // Pairing cleanup and the success-page transition must not delay playback.
            if scenePhase == .active && !videoFinished {
                video.player.playImmediately(atRate: 1.25)
            }
            withAnimation(.easeInOut(duration: reduceMotion ? 0.2 : 1.6)) {
                pageOpacity = 0
            }
            do { try await Task.sleep(for: .seconds(reduceMotion ? 0.2 : 1.6)) }
            catch { return }
            showingSuccess = true
            if reduceMotion {
                withAnimation(.easeInOut(duration: 0.2)) { pageOpacity = 1 }
            }
        }
        .onReceive(Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()) { _ in
            guard showingSuccess, !reduceMotion, !videoFinished, scenePhase == .active,
                  let duration = video.player.currentItem?.duration.seconds,
                  duration.isFinite, duration > 0 else { return }
            // Follow playback itself, so pausing or buffering also pauses the fade.
            // Playback is 1.25×: half a second of viewing time is 0.625 media seconds.
            let delay = min(0.5 * 1.25, duration)
            let fadeDuration = max(duration - delay, 0.001)
            let progress = min(1, max(0, (video.player.currentTime().seconds - delay) / fadeDuration))
            pageOpacity = progress * progress * (3 - 2 * progress)
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: video.player.currentItem)) { _ in
            videoFinished = true
            pageOpacity = 1
        }
        .onDisappear { video.player.pause(); copyFeedbackTask?.cancel() }
        .onChange(of: setup.comparisons.map(\.id)) { _, ids in
            if path.last == .waiting && !ids.isEmpty && !setup.isFailed && !setup.hasSelection {
                navigate(to: path + [.verify])
            }
        }
        .onChange(of: path) { previous, steps in
            if steps.last == .waiting && steps.count > previous.count && !setup.comparisons.isEmpty && !setup.isFailed && !setup.hasSelection {
                navigate(to: steps + [.verify])
            }
            if steps.last != .install {
                codesRejected = false
                copyFeedbackTask?.cancel()
                setupPromptCopied = false
                advancingPromptAction = nil
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && connectionReady && !videoFinished {
                video.player.playImmediately(atRate: 1.25)
            } else {
                video.player.pause()
            }
        }
        // Keep polling alive across onboarding pages and the success animation.
            .alert("Unable to Connect", isPresented: Binding(
                get: { store.errorMessage != nil && !pairingInProgress },
                set: { if !$0 { store.errorMessage = nil } }
            )) {
                Button("Try Again", action: connect)
                Button("Cancel", role: .cancel) { store.errorMessage = nil }
            } message: {
                Text(store.errorMessage ?? "Please try again.")
            }
            .onAppear {
                restoreFields()
                if setup.hasAttempt && path.isEmpty {
                    path = [.install, .waiting]
                }
            }
            .sheet(item: $sharedSetupPrompt, onDismiss: {
                if sharedPromptCompleted {
                    sharedPromptCompleted = false
                    showPromptHandoff(after: .share)
                }
            }) { item in
                SetupPromptShareSheet(prompt: item.text) { completed in
                    sharedPromptCompleted = completed
                    sharedSetupPrompt = nil
                }
                .presentationDetents([.medium, .large])
            }
            .onChange(of: sharedPromptCompleted) { _, completed in
                // UIKit can report completion after SwiftUI's dismissal callback.
                if completed && sharedSetupPrompt == nil {
                    sharedPromptCompleted = false
                    showPromptHandoff(after: .share)
                }
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    if !isConnecting && !pairingInProgress {
                        await setup.refresh()
                        await connectConfirmedHermes()
                    }
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .hermesSetupOpened)) { _ in
                Task { await setup.refresh() }
            }
            .onChange(of: store.settings) { _, settings in
                guard let settings, store.phase != .connected else { return }
                address = settings.address
                username = settings.username
            }
    
    }

    private var headerAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.25)
    }

    private var showsNavigation: Bool { !path.isEmpty && store.phase != .connected }

    private func navigate(to steps: [Step]) {
        focusedField = nil
        path = steps
    }

    @ViewBuilder
    private var onboardingContent: some View {
        if showingSuccess {
            VStack(spacing: 20) {
                Text("You’re connected").font(.largeTitle.bold())
                Text("Your Hermes Agent is ready to open.").foregroundStyle(.secondary)
                Button(action: onFinished) {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .modifier(OnboardingChoiceButtonStyle(prominent: true))
                .tint(.blue)
                .controlSize(.large)
                .accessibilityIdentifier("connection.finish")
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
        } else {
            NavigationStack(path: $path) {
                welcomePage
                    .background(OnboardingSwipeBack())
                    .navigationDestination(for: Step.self) { step in
                        stepPage(step)
                            .background(OnboardingSwipeBack())
                            .toolbar(.hidden, for: .navigationBar)
                    }
                    .toolbar(.hidden, for: .navigationBar)
            }
            .tint(.blue)
        }
    }

    private func stepPage(_ step: Step) -> some View {
        Group {
            if step == .address {
                addressPage
            } else {
                switch step {
                case .install: installPage
                case .handoff: handoffPage
                case .waiting: waitingPage
                case .verify: verificationPage
                case .address: EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .scrollDismissesKeyboard(.interactively)
    }

    private func pageHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(.body).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24)
    }

    // Fill the available height, while allowing scrolling on smaller screens or large text.
    private func fullHeightPage<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24, content: content)
                    .padding(.vertical, 24)
                    .frame(minHeight: geometry.size.height)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var welcomePage: some View {
        fullHeightPage {
            pageHeading("Your Hermes, on your phone", subtitle: "Talk to your existing Hermes agents and conversations on your phone.")
            Spacer(minLength: 0)
            VStack(spacing: 16) {
                Button { navigate(to: path + [.install]) } label: {
                    Text("Set up with Companion").frame(maxWidth: .infinity)
                }.modifier(OnboardingChoiceButtonStyle(prominent: true)).accessibilityIdentifier("connection.chooseCompanion")
                Button { navigate(to: path + [.address]) } label: {
                    Text("Use a dashboard address").frame(maxWidth: .infinity)
                }.modifier(OnboardingChoiceButtonStyle(prominent: false)).accessibilityIdentifier("connection.chooseAddress")
                Text("Requires Hermes on a computer or server.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .controlSize(.large).padding(.horizontal, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var installPage: some View {
        fullHeightPage {
            pageHeading(
                codesRejected ? "Start again with your Hermes" : "Set up Companion",
                subtitle: codesRejected
                    ? "The codes did not match, so that attempt was canceled. Send a fresh setup prompt to the correct Hermes."
                    : "Hermes Jr. Companion plugin connects this device to Hermes. Send the prompt to Hermes to set it up.\n\nKeep the computer running Hermes awake during setup and while using Jr."
            )
            Spacer(minLength: 0)
            VStack(spacing: 18) {
                Button { preparePrompt(share: false) } label: {
                    ZStack {
                        // Reserve feedback labels' intrinsic dimensions, including symbol height.
                        Label("Copy setup prompt", systemImage: "doc.on.doc")
                            .hidden().accessibilityHidden(true)
                        Label("Creating setup prompt…", systemImage: "doc.on.doc")
                            .hidden().accessibilityHidden(true)
                        Label("Taking you to next step", systemImage: "doc.on.doc")
                            .hidden().accessibilityHidden(true)
                        Label("Copied", systemImage: "checkmark")
                            .hidden().accessibilityHidden(true)
                        Label(copyPromptTitle, systemImage: setupPromptCopied ? "checkmark" : "doc.on.doc")
                            .contentTransition(.opacity)
                            .animation(reduceMotion ? nil : .default, value: copyPromptTitle)
                    }
                    .frame(maxWidth: .infinity)
                }.modifier(CopyPromptButtonStyle(secondary: false))
                    .disabled(creatingSetupPrompt || setupPromptCopied || advancingPromptAction != nil || (setup.busy && !setup.hasAttempt) || setup.isFailed || isConnecting)
                    .accessibilityIdentifier("connection.copyDevicePrompt")
                Button { preparePrompt(share: true) } label: {
                    ZStack {
                        Label("Share setup prompt", systemImage: "square.and.arrow.up")
                            .hidden().accessibilityHidden(true)
                        Label("Taking you to next step", systemImage: "square.and.arrow.up")
                            .hidden().accessibilityHidden(true)
                        Label(sharePromptTitle, systemImage: "square.and.arrow.up")
                            .contentTransition(.opacity)
                            .animation(reduceMotion ? nil : .default, value: sharePromptTitle)
                    }.frame(maxWidth: .infinity)
                }.modifier(OnboardingChoiceButtonStyle(prominent: false)).disabled(creatingSetupPrompt || setupPromptCopied || advancingPromptAction != nil || (setup.busy && !setup.hasAttempt) || setup.isFailed || isConnecting)
                    .accessibilityLabel(sharePromptTitle)
                    .accessibilityIdentifier("connection.shareDevicePrompt")
                if !setup.needsConnectionRetry { setupErrors }
                if setup.isFailed { Button("Start a new setup") { resetSetup() } }
                Text("Conversation data is encrypted between this device and Companion.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .controlSize(.large).padding(.horizontal, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var copyPromptTitle: String {
        if advancingPromptAction == .copy { return "Taking you to next step" }
        if creatingSetupPrompt && !preparingShare { return "Creating setup prompt…" }
        return setupPromptCopied ? "Copied" : "Copy setup prompt"
    }

    private var sharePromptTitle: String {
        advancingPromptAction == .share ? "Taking you to next step" : "Share setup prompt"
    }

    private var handoffPage: some View {
        fullHeightPage {
            pageHeading("Give prompt to Hermes", subtitle: "After you send the prompt to Hermes, continue here.")
            Spacer(minLength: 0)
            Button { navigate(to: path + [.waiting]) } label: {
                Text("I sent the prompt").frame(maxWidth: .infinity)
            }
            .modifier(OnboardingChoiceButtonStyle(prominent: true))
            .controlSize(.large)
            .padding(.horizontal, 24)
            .accessibilityIdentifier("connection.startWaiting")
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var notificationButtonLabel: some View {
        ZStack {
            Label("Notify me when ready", systemImage: "bell")
                .hidden().accessibilityHidden(true)
            Label("Setup notifications on", systemImage: "bell.badge.fill")
                .hidden().accessibilityHidden(true)
            Label(setup.pushEnabled ? "Setup notifications on" : "Notify me when ready",
                  systemImage: setup.pushEnabled ? "bell.badge.fill" : "bell")
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : .default, value: setup.pushEnabled)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var waitingPage: some View {
        if let failure = setup.failure, failure != .cancelled {
            setupFailurePage(failure)
        } else if setup.needsConnectionRetry && !setup.isFailed {
            connectionRetryPage
        } else if !setup.isFailed && !setup.needsConnectionRetry && !setup.hasSelection {
            fullHeightPage {
                pageHeading("Waiting for Hermes", subtitle: "Follow the setup in Hermes. Return here when Hermes shows a code to compare.")
                Spacer(minLength: 0)
                ProgressView()
                    .controlSize(.large)
                    .accessibilityLabel("Waiting for Hermes")
                Spacer(minLength: 0)
                VStack(spacing: 20) {
                    setupErrors
                    Button {
                        Task { await setup.enablePush(); showNotificationsOff = setup.pushPermissionDenied }
                    } label: {
                        notificationButtonLabel
                    }.modifier(OnboardingChoiceButtonStyle(prominent: false)).disabled(setup.pushEnabled)
                }
                .multilineTextAlignment(.center)
                .controlSize(.large).padding(.horizontal, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) { waitingDetails }
                    .padding(.vertical, 24)
            }
        }
    }

    private func setupFailurePage(_ failure: SetupFailure) -> some View {
        fullHeightPage {
            pageHeading(failure.title, subtitle: failure.message)
            Spacer(minLength: 0)
            Button {
                resetSetup()
                navigate(to: [.install])
            } label: {
                Text("Start a new setup").frame(maxWidth: .infinity)
            }
            .modifier(OnboardingChoiceButtonStyle(prominent: true))
            .controlSize(.large)
            .padding(.horizontal, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var connectionRetryPage: some View {
        fullHeightPage {
            pageHeading("Couldn’t connect to Hermes", subtitle: "The codes matched, but the connection did not finish. Check that Hermes is running and both devices are online.")
            Spacer(minLength: 0)
            Button {
                pairingError = nil
                setup.retryConnection()
            } label: {
                Text("Try connecting again").frame(maxWidth: .infinity)
            }
            .modifier(OnboardingChoiceButtonStyle(prominent: true))
            .controlSize(.large)
            .padding(.horizontal, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var selectedComparison: SetupComparison? {
        if setup.comparisons.count == 1 { return setup.comparisons.first }
        return setup.comparisons.first { $0.id == selectedComparisonID }
    }

    private func comparisonCard(_ comparison: SetupComparison) -> some View {
        VStack(spacing: 20) {
            Text(comparison.name).font(.headline)
            Text(comparison.code)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .minimumScaleFactor(0.7).lineLimit(1)
                .padding(.vertical, 16)
                .accessibilityLabel("Pairing code \(comparison.code)")
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private var verificationPage: some View {
        if let failure = setup.failure, failure != .cancelled {
            setupFailurePage(failure)
        } else if setup.needsConnectionRetry && !setup.isFailed {
            connectionRetryPage
        } else if setup.isFailed {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) { waitingDetails }
                    .padding(.vertical, 24)
            }
        } else {
            fullHeightPage {
                pageHeading(
                    setup.comparisons.count > 1 ? "Choose your Hermes" : "Verify your Hermes",
                    subtitle: setup.comparisons.count > 1
                        ? "More than one Hermes responded. Select the one whose three code groups match the code in your Hermes conversation."
                        : "Hermes is ready to connect. Compare all three code groups before continuing."
                )
                Spacer(minLength: 0)
                VStack(spacing: 16) {
                    ForEach(setup.comparisons) { comparison in
                        if setup.comparisons.count > 1 {
                            Button { selectedComparisonID = comparison.id } label: {
                                comparisonCard(comparison)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 20)
                                            .stroke(selectedComparisonID == comparison.id ? Color.accentColor : .clear, lineWidth: 2)
                                    }
                            }
                            .buttonStyle(.plain)
                            .disabled(codesConnecting)
                            .accessibilityAddTraits(selectedComparisonID == comparison.id ? [.isSelected] : [])
                        } else {
                            comparisonCard(comparison)
                        }
                    }
                }.padding(.horizontal, 24)
                Spacer(minLength: 0)
                VStack(spacing: 16) {
                    setupErrors
                    Button {
                        guard let comparison = selectedComparison else { return }
                        Task {
                            await setup.confirm(comparison.id)
                            await connectConfirmedHermes()
                        }
                    } label: {
                        Text(confirmCodesTitle)
                            .contentTransition(.opacity)
                            .animation(reduceMotion ? nil : .default, value: confirmCodesTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .modifier(OnboardingChoiceButtonStyle(prominent: true))
                    .disabled(selectedComparison == nil || codesConnecting)
                    .accessibilityIdentifier("connection.confirmCodes")
                    Button {
                        resetSetup()
                        codesRejected = true
                        navigate(to: [.install])
                    } label: {
                        Text("Codes don’t match").frame(maxWidth: .infinity)
                    }
                    .modifier(OnboardingChoiceButtonStyle(prominent: false))
                    .disabled(codesConnecting)
                    .accessibilityIdentifier("connection.rejectCodes")
                }
                .multilineTextAlignment(.center)
                .controlSize(.large)
                .padding(.horizontal, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var waitingDetails: some View {
        Group {
            if let failure = setup.failure {
                pageHeading(failure.title, subtitle: failure.message)
            } else if setup.needsConnectionRetry {
                pageHeading("Couldn’t connect to Hermes", subtitle: "The codes matched, but the connection did not finish. Check that Hermes is running and both devices are online.")
            } else if setup.hasSelection {
                pageHeading("Connecting to Hermes", subtitle: "Your codes match. We’re finishing the secure connection.")
            } else if setup.comparisons.isEmpty {
                pageHeading("Waiting for Hermes", subtitle: "Follow the setup in Hermes. Return here when Hermes shows a code to compare.")
            } else {
                pageHeading("Verify your Hermes", subtitle: "Hermes is ready to connect. Compare all three code groups before continuing.")
            }
            VStack(alignment: .leading, spacing: 24) {
                if !setup.isFailed {
                    if setup.needsConnectionRetry {
                        Button("Try connecting again") { pairingError = nil; setup.retryConnection() }
                            .modifier(OnboardingChoiceButtonStyle(prominent: true))
                    } else if setup.hasSelection {
                        ProgressView("Connecting…")
                    } else if setup.comparisons.isEmpty {
                        ProgressView("Waiting for Hermes…")
                        Button {
                            Task { await setup.enablePush(); showNotificationsOff = setup.pushPermissionDenied }
                        } label: {
                            notificationButtonLabel
                        }.modifier(OnboardingChoiceButtonStyle(prominent: false)).disabled(setup.pushEnabled)
                    } else {
                        Button("Verify your Hermes") { navigate(to: path + [.verify]) }
                            .modifier(OnboardingChoiceButtonStyle(prominent: true))
                    }
                }
                if !setup.needsConnectionRetry { setupErrors }
                if setup.isFailed {
                    Button("Start a new setup") {
                        resetSetup(); navigate(to: [.install])
                    }.modifier(OnboardingChoiceButtonStyle(prominent: false))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }.controlSize(.large).padding(.horizontal, 24)
        }
    }

    private var setupErrors: some View {
        Group {
            if setup.setupServiceUnreachable {
                VStack(spacing: 8) {
                    Text("The setup service is unreachable.")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("You do not need a new prompt yet. This attempt will resume after reconnection.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
            } else if let error = setup.error {
                Text(error).font(.subheadline).foregroundStyle(.red)
            }
            if let pairingError { Text(pairingError).font(.subheadline).foregroundStyle(.red) }
        }
    }

    private var codesConnecting: Bool {
        // Keep the completed confirmation disabled while its page fades out.
        setup.confirming || setup.hasSelection || pairingInProgress || isConnecting || connectionReady
    }

    private var confirmCodesTitle: String {
        codesConnecting ? "Connecting to Hermes…" : "Codes match"
    }

    private func connectConfirmedHermes() async {
        guard !pairingInProgress, !isConnecting, !setup.needsConnectionRetry else { return }
        do {
            guard let (invitation, key) = try setup.enrollment() else { return }
            pairingInProgress = true
            defer { pairingInProgress = false }
            await store.pair(with: invitation, phonePrivateKey: key)
            if store.phase == .connected {
                await setup.completed()
            } else {
                setup.connectionFailed()
                pairingError = "Your codes matched, but Jr. couldn’t connect to Hermes. Check that Hermes is running and both devices have internet access, then try again."
                store.errorMessage = nil
            }
        } catch { pairingError = error.localizedDescription }
    }

    private func resetSetup() {
        setup.cancel(); store.cancelPairing(); advancingPromptAction = nil
        selectedComparisonID = nil
        copyFeedbackTask?.cancel()
        setupPromptCopied = false
        pairingError = nil; codesRejected = false
    }

    private func showCopiedFeedback() {
        showPromptHandoff(after: .copy)
    }

    private func showPromptHandoff(after action: PromptAction) {
        copyFeedbackTask?.cancel()
        setupPromptCopied = action == .copy
        copyFeedbackTask = Task { @MainActor in
            do {
                if action == .copy { try await Task.sleep(for: .seconds(1.2)) }
                else { try await Task.sleep(for: .milliseconds(500)) }
                guard path.last == .install else { return }
                setupPromptCopied = false
                advancingPromptAction = action
                try await Task.sleep(for: .seconds(1.2))
                guard path.last == .install else { return }
                navigate(to: path + [.handoff])
            } catch { return }
        }
    }

    private func preparePrompt(share: Bool) {
        guard !creatingSetupPrompt, !setupPromptCopied, advancingPromptAction == nil else { return }
        copyFeedbackTask?.cancel()
        setupPromptCopied = false
        preparingShare = share
        creatingSetupPrompt = true
        Task { @MainActor in
            defer { creatingSetupPrompt = false }
            await setup.prepare()
            if setup.promptRateLimited {
                showSetupRateLimited = true
                return
            }
            if setup.promptServiceUnavailable {
                showSetupUnavailable = true
                return
            }
            guard let prompt = setup.prompt, !setup.isFailed else { return }
            if share {
                sharedPromptCompleted = false
                sharedSetupPrompt = SharedSetupPrompt(text: prompt)
            }
            else {
                UIPasteboard.general.string = prompt
                showCopiedFeedback()
            }
        }
    }

    private var addressPage: some View {
        fullHeightPage {
            pageHeading("Use a dashboard address", subtitle: "Enter the Hermes dashboard address this device can reach.")
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Dashboard address").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("Dashboard address", text: $address, prompt: Text(verbatim: "https://123.123.123.123:1919"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .focused($focusedField, equals: .address)
                        .submitLabel(.next)
                        .onSubmit { focusedField = signInMethod == .password ? .username : .token }
                        .accessibilityLabel("Dashboard address")
                        .accessibilityIdentifier("connection.address")
                        .padding(16)
                        .background(.background, in: RoundedRectangle(cornerRadius: 26))
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Sign-in method").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Picker("Sign-in method", selection: $signInMethod) {
                        Text("Username and password").tag(SignInMethod.password)
                        Text("Access token").tag(SignInMethod.token)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("connection.signInMethod")
                    .onChange(of: signInMethod) { _, _ in focusedField = nil }
                    VStack(spacing: 0) {
                        if signInMethod == .password {
                            TextField("Username", text: $username)
                                .textContentType(.username)
                                .focused($focusedField, equals: .username)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .password }
                                .padding(16)
                            Divider().padding(.leading, 16)
                            SecureField("Password", text: $password)
                                .textContentType(.password)
                                .focused($focusedField, equals: .password)
                                .submitLabel(.go)
                                .onSubmit(connect)
                                .padding(16)
                        } else {
                            SecureField("Access token", text: $token)
                                .focused($focusedField, equals: .token)
                                .submitLabel(.go)
                                .onSubmit(connect)
                                .padding(16)
                        }
                    }
                    .background(.background, in: RoundedRectangle(cornerRadius: 26))
                }
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 0)
            VStack(spacing: 12) {
                Button(action: connect) {
                    ZStack {
                        Text("Connecting…").hidden().accessibilityHidden(true)
                        Text(isConnecting ? "Connecting…" : "Connect")
                            .contentTransition(.opacity)
                            .animation(reduceMotion ? nil : .default, value: isConnecting)
                    }.frame(maxWidth: .infinity)
                }
                .modifier(OnboardingChoiceButtonStyle(prominent: true))
                .controlSize(.large)
                .disabled(isConnecting || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("connection.connect")
                Text("Use dashboard sign-in details, not a model API key.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .disabled(isConnecting)
    }

    private func restoreFields() {
        guard let settings = store.settings, settings.companion == nil else { return }
        address = settings.address
        username = settings.username
    }

    private func connect() {
        guard !isConnecting else { return }
        setup.cancel()
        focusedField = nil
        let usesPassword = signInMethod == .password
        Task {
            await store.connect(address: address,
                                username: usesPassword ? username : "",
                                password: usesPassword ? password : "",
                                token: usesPassword ? "" : token)
        }
    }
}

private struct SharedSetupPrompt: Identifiable {
    let id = UUID()
    let text: String
}

private struct SetupPromptShareSheet: UIViewControllerRepresentable {
    let prompt: String
    let onComplete: @MainActor (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [prompt], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            Task { @MainActor in onComplete(completed) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// Hiding the content stack's bar leaves room for the persistent video controls.
// Re-enable UIKit's own interactive pop gesture for this stack only.
private struct OnboardingSwipeBack: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.restoreGestureDelegate()
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private weak var popGesture: UIGestureRecognizer?
        private weak var previousDelegate: (any UIGestureRecognizerDelegate)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let gesture = navigationController?.interactivePopGestureRecognizer else { return }
            if gesture.delegate !== self {
                previousDelegate = gesture.delegate
                popGesture = gesture
                gesture.delegate = self
            }
            gesture.isEnabled = true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let navigationController else { return false }
            return navigationController.viewControllers.count > 1
                && navigationController.transitionCoordinator == nil
        }

        func restoreGestureDelegate() {
            if let popGesture, popGesture.delegate === self {
                popGesture.delegate = previousDelegate
            }
        }
    }
}

private struct OnboardingBackButtonStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glass).buttonBorderShape(.circle)
        } else {
            content.buttonStyle(.plain).background(.ultraThinMaterial, in: Circle())
        }
    }
}

private struct CopyPromptButtonStyle: ViewModifier {
    let secondary: Bool

    func body(content: Content) -> some View {
        content.modifier(OnboardingChoiceButtonStyle(prominent: !secondary))
    }
}

private struct OnboardingChoiceButtonStyle: ViewModifier {
    let prominent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            if prominent {
                content.buttonStyle(.borderedProminent)
            } else {
                content.buttonStyle(.bordered)
            }
        }
    }
}
