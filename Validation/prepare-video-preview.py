"""Prepare the isolated simulator fixture; production sources remain unchanged."""
from pathlib import Path
import shutil
root = Path('/var/folders/q9/9f6v84r171ld525sf72g2g2w0000gn/T/hermes-pairing-ui-l_1ilrv4')
source = Path('Hermes/Views/ConnectionView.swift').read_text()
start = source.index('            .task(id: scenePhase) {')
end = source.index('            .onReceive(NotificationCenter.default.publisher(for: .hermesSetupOpened))', start)
source = source[:start] + source[end:]
source = source.replace('.disabled(!setup.hasAttempt || setup.isFailed)', '')
source = source.replace('case .waiting: waitingPage', '''case .waiting:
                            waitingPage.task {
                                guard previewFailure == nil, !ProcessInfo.processInfo.arguments.contains("--preview-cancel-setup"), !ProcessInfo.processInfo.arguments.contains("--preview-waiting"), !ProcessInfo.processInfo.arguments.contains("--preview-notifications-off"), !ProcessInfo.processInfo.arguments.contains("--preview-setup-network-error") else { return }
                                do { try await Task.sleep(for: .seconds(3)) }
                                catch { return }
                                previewComparisons = [SetupComparison(id: "preview", name: "Hermes preview", code: "123 456 789")]
                                if ProcessInfo.processInfo.arguments.contains("--preview-multiple") {
                                    previewComparisons.append(SetupComparison(id: "other-preview", name: "Other Hermes", code: "654 321 987"))
                                }
                            }''')
source = source.replace('@State private var setup = SetupPairing()', '@State private var setup = SetupPairing()\n    @State private var previewComparisons: [SetupComparison] = []')
source = source.replace('setup.comparisons', 'previewComparisons')
source = source.replace('@State private var previewComparisons:', '@State private var previewPushEnabled = false\n    @State private var previewComparisons:')
source = source.replace('setup.pushEnabled', 'previewPushEnabled')
source = source.replace('@State private var previewPushEnabled = false', '@State private var previewPushEnabled = false\n    @State private var previewFailure: SetupFailure?')
source = source.replace('setup.failure', 'previewFailure')
source = source.replace('setup.isFailed', '(previewFailure != nil)')
source = source.replace('setup.cancel(); store.cancelPairing()', 'previewFailure = nil; previewConnectionRetry = false; setup.cancel(); store.cancelPairing()')

source = source.replace('@State private var previewPushEnabled = false', '@State private var previewPushEnabled = false\n    @State private var previewConnectionRetry = false')
source = source.replace('setup.needsConnectionRetry', 'previewConnectionRetry')
source = source.replace('setup.retryConnection()', 'previewConnectionRetry = false; pairingInProgress = true; Task { try? await Task.sleep(for: .seconds(2)); store.phase = .connected; pairingInProgress = false }')

source = source.replace('Task { await setup.enablePush(); showNotificationsOff = setup.pushPermissionDenied }', 'if ProcessInfo.processInfo.arguments.contains("--preview-notifications-off") { showNotificationsOff = true } else { previewPushEnabled = true }')

source = source.replace('await setup.confirm(comparison.id)', 'pairingInProgress = true; try? await Task.sleep(for: .seconds(2)); store.phase = .connected; pairingInProgress = false')
source = source.replace('await connectConfirmedHermes()', '')

source = source.replace('                restoreFields()', '''                restoreFields()
                if ProcessInfo.processInfo.arguments.contains("--preview-address-connecting") {
                    path = [.address]
                    address = "https://hermes-preview.example.com"
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        store.phase = .connecting
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("--preview-address") {
                    path = [.address]
                }
                if ProcessInfo.processInfo.arguments.contains("--preview-setup-unknown") {
                    previewFailure = .unknown
                    pairingError = SetupFailure.unknown.message
                    path = [.install, .handoff, .waiting]
                }
                if ProcessInfo.processInfo.arguments.contains("--preview-setup-verification") {
                    previewFailure = .verification
                    pairingError = SetupFailure.verification.message
                    path = [.install, .handoff, .waiting]
                }
                if ProcessInfo.processInfo.arguments.contains("--preview-setup-rejected") {
                    previewFailure = .rejected
                    pairingError = SetupFailure.rejected.message
                    path = [.install, .handoff, .waiting]
                }
                if ProcessInfo.processInfo.arguments.contains("--preview-setup-unavailable") {
                    previewFailure = .unavailable
                    path = [.install, .handoff, .waiting]
                }
                if ProcessInfo.processInfo.arguments.contains("--preview-setup-expired") {
                    previewFailure = .expired
                    path = [.install, .handoff, .waiting]
                }
                if ProcessInfo.processInfo.arguments.contains("--preview-cancel-setup") {
                    path = [.install, .handoff, .waiting]
                    Task {
                        try? await Task.sleep(for: .milliseconds(700))
                        showCancelSetup = true
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("--preview-setup-retry") {
                    previewConnectionRetry = true
                    pairingError = "Your codes matched, but Jr. couldn’t connect to Hermes. Check that Hermes is running and both devices have internet access, then try again."
                    path = [.install, .handoff, .waiting, .verify]
                }
                if ProcessInfo.processInfo.arguments.contains("--preview-success") {
                    path = [.install, .waiting]
                    Task {
                        try? await Task.sleep(for: .seconds(4))
                        pairingInProgress = true
                        try? await Task.sleep(for: .seconds(2))
                        store.phase = .connected
                        pairingInProgress = false
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("--preview-install") {
                    path = [.install]
                }
                if ProcessInfo.processInfo.arguments.contains("--preview-install-error") {
                    path = [.install]
                    preparePrompt(share: false)
                }
                if ProcessInfo.processInfo.arguments.contains("--preview-install-rate-limit") {
                    path = [.install]
                    preparePrompt(share: false)
                }
                if ProcessInfo.processInfo.arguments.contains("--preview-rejected") {
                    codesRejected = true
                    path = [.install]
                }
                if ProcessInfo.processInfo.arguments.contains("--preview-handoff") {
                    path = [.install, .handoff]
                }
                if ProcessInfo.processInfo.arguments.contains("--preview-share") {
                    path = [.install]
                    preparePrompt(share: true)
                }
                if ProcessInfo.processInfo.arguments.contains("--preview-notifications-off") {
                    path = [.install, .handoff, .waiting]
                    Task {
                        try? await Task.sleep(for: .milliseconds(700))
                        showNotificationsOff = true
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("--preview-setup-network-error") {
                    path = [.install, .handoff, .waiting]
                }
                if ProcessInfo.processInfo.arguments.contains("--preview-waiting") {
                    path = [.install, .handoff, .waiting]
                }
                if ProcessInfo.processInfo.arguments.contains("--preview-pairing-card") || ProcessInfo.processInfo.arguments.contains("--preview-multiple") {
                    path = [.install, .waiting]
                }''')
source = source.replace('    private func resetSetup() {', '    private func resetSetup() {\n        previewComparisons = []\n        previewPushEnabled = false')
# Exercise the real copy/share UI with an inert ticket and simulated preparation.
source = source.replace('if setup.setupServiceUnreachable {', 'if ProcessInfo.processInfo.arguments.contains("--preview-setup-network-error") || setup.setupServiceUnreachable {')
source = source.replace('if setup.promptRateLimited {', 'if ProcessInfo.processInfo.arguments.contains("--preview-install-rate-limit") {')
source = source.replace('if setup.promptServiceUnavailable {', 'if ProcessInfo.processInfo.arguments.contains("--preview-install-error") {')
source = source.replace('            await setup.prepare()', '            try? await Task.sleep(for: .milliseconds(700))')
source = source.replace('guard let prompt = setup.prompt, !setup.isFailed else { return }', 'let prompt = HermesCompanionSetup.prompt(ticket: "PREVIEW-ONLY-NOT-A-VALID-TICKET")')
# Keep the growing preview routing outside SwiftUI's view type-checking expression.
preview_start = source.index('            .onAppear {\n                restoreFields()')
preview_end = source.index('\n            }', preview_start)
preview_body = source[preview_start + len('            .onAppear {'):preview_end]
source = source[:preview_start] + '            .onAppear { configurePreview() }' + source[preview_end + len('\n            }'):]
source = source.replace('    private func resetSetup() {', '    private func configurePreview() {' + preview_body + '\n    }\n\n    private func resetSetup() {')
(root / 'Hermes/Views/ConnectionView.swift').write_text(source)
# Keep production UI changes while preserving the isolated fake pairing flow.
for name in ['Services/PushNotifications.swift', 'Services/CredentialStore.swift', 'Services/SetupPairing.swift', 'Views/OnboardingVideoHeader.swift', 'Views/AppRootView.swift',
             'Views/BotListView.swift', 'Views/ConnectionRecoveryView.swift', 'Views/NotificationPreferenceErrorPresenter.swift',
             'Models/NotificationPreferenceUpdate.swift']:
    shutil.copy(Path('Hermes') / name, root / 'Hermes' / name)

recovery_path = root / 'Hermes/Views/ConnectionRecoveryView.swift'
recovery = recovery_path.read_text().replace('        .safeAreaInset(edge: .bottom) {', '''        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--preview-removal-dialog") {
                Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    confirmRemoval = true
                }
            }
        }
        .safeAreaInset(edge: .bottom) {''')
recovery_path.write_text(recovery)

store = Path('Hermes/Models/AppStore.swift').read_text()
store = store.replace('    func selectProfile(_ profile: BotProfile) async {', '''    func selectProfile(_ profile: BotProfile) async {
        if settings?.address == "https://hermes-preview.example.com" {
            selectedProfile = profile
            selectedSession = nil
            sessions = [HermesSession(id: "preview-conversation", title: "Welcome to Hermes", preview: "Your conversations are ready.", lastActive: .now, messageCount: 2, source: "preview")]
            return
        }''')

store = store.replace('    func setNotificationsEnabled(_ enabled: Bool) async -> String? {', '''    func setNotificationsEnabled(_ enabled: Bool) async -> String? {
        if settings?.address == "https://hermes-preview.example.com" {
            do { try await Task.sleep(for: .seconds(2)) } catch { return nil }
            if ProcessInfo.processInfo.arguments.contains("--preview-notification-failure") {
                return "The preview server couldn’t be reached. Please try again."
            }
            notificationsEnabled = enabled
            return nil
        }''')
(root / 'Hermes/Models/AppStore.swift').write_text(store)
(root / 'Hermes/HermesApp.swift').write_text('''import SwiftUI
@main struct HermesApp: App {
    @State private var store: AppStore
    init() {
        let previewStore = AppStore()
        previewStore.settings = ConnectionSettings(address: "https://hermes-preview.example.com", username: "preview",
            companion: CompanionConnection(relayURL: "https://hermes-preview.example.com",
                installationID: "00000000-0000-4000-8000-000000000001",
                deviceID: "00000000-0000-4000-8000-000000000002",
                hostPublicKey: Data(repeating: 0, count: 32).companionBase64))
        previewStore.profiles = [BotProfile(id: "default", displayName: "Hermes", summary: "Your personal agent", model: "Preview", isGatewayRunning: true)]
        previewStore.phase = ProcessInfo.processInfo.arguments.contains("--preview-restoring") ? .restoring
            : (ProcessInfo.processInfo.arguments.contains("--preview-connected") ? .connected : .disconnected)
        if ProcessInfo.processInfo.arguments.contains("--preview-recovery-pair-again") {
            previewStore.phase = .disconnected
            previewStore.connectionNotice = .pairAgain
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-recovery-credentials-invalid") {
            previewStore.phase = .disconnected
            previewStore.connectionNotice = .credentialsInvalid
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-recovery-credentials") {
            previewStore.phase = .disconnected
            previewStore.connectionNotice = .credentialsUnavailable
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-recovery-service") {
            previewStore.phase = .disconnected
            previewStore.connectionNotice = .serviceUnavailable
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-recovery-unavailable") {
            previewStore.phase = .disconnected
            previewStore.connectionNotice = .unavailable
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-recovery-offline") {
            previewStore.phase = .disconnected
            previewStore.connectionNotice = .offline
        }
        _store = State(initialValue: previewStore)
    }
    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(store)
        }
    }
}
''')
