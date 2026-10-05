import Foundation
import Observation
import UIKit
import CryptoKit

enum ConnectionRecovery: Equatable {
    case pairAgain, unavailable, offline, serviceUnavailable, credentialsUnavailable, credentialsInvalid, secureConnectionRequired

    var title: String {
        switch self {
        case .pairAgain: "Connect this device again"
        case .unavailable: "Couldn’t reach Hermes"
        case .offline: "This device is offline"
        case .serviceUnavailable: "Connection service unavailable"
        case .credentialsUnavailable: "Couldn’t read saved sign-in details"
        case .credentialsInvalid: "Couldn’t read saved sign-in details"
        case .secureConnectionRequired: "Use a secure connection"
        }
    }

    var message: String {
        switch self {
        case .pairAgain: "This pairing can no longer be used. Remove the saved connection to start a new setup."
        case .unavailable: "Check that Hermes is running and its computer is awake. Then check the network and try again."
        case .offline: "Check this device’s internet connection, then try again."
        case .serviceUnavailable: "Try reconnecting later. The service used for this connection is unavailable."
        case .credentialsUnavailable: "This device could not read the saved sign-in details. Please retry again."
        case .credentialsInvalid: "The saved sign-in details are unreadable. Please remove the connection to start again."
        case .secureConnectionRequired: HermesError.secureConnectionRequired.localizedDescription
        }
    }

    var canRetry: Bool { self != .pairAgain && self != .credentialsInvalid && self != .secureConnectionRequired }

    static func credentialFailure(_ error: Error) -> Self {
        if let failure = error as? CredentialReadError, case .invalidData = failure {
            return .credentialsInvalid
        }
        return .credentialsUnavailable
    }

    static func companionFailure(_ error: Error) -> Self {
        if let error = error as? HermesError, case .secureConnectionRequired = error { return .secureConnectionRequired }
        if let failure = error as? CompanionConnectionFailure {
            switch failure {
            case .pairingRequired: return .pairAgain
            case .offline: return .offline
            case .serviceUnavailable: return .serviceUnavailable
            case .unavailable: return .unavailable
            }
        }
        if (error as? URLError)?.code == .notConnectedToInternet { return .offline }
        return .unavailable
    }
}

struct PendingApproval: Identifiable {
    var id: String
    var command: String
    var choices: [String]
}

struct LocalDisconnectConfirmation: Identifiable {
    let id = UUID()
    fileprivate let client: HermesClient
    fileprivate let account: String
    fileprivate let generation: Int
}

enum DisconnectOutcome {
    case disconnected
    case canceled
    case needsLocalRemoval(LocalDisconnectConfirmation)
}

extension AppStore {
    private struct NotificationContext {
        let client: HermesClient
        let account: String
        let enrollment: CompanionEnrollment?
    }

    private var notificationAccount: String { "notifications/" + (settings?.companion?.keychainAccount ?? settings?.address ?? "") }
    private var notificationPreferencesKey: String { notificationAccount + "/preferences" }

    private func notificationContext() -> NotificationContext? {
        guard phase == .connected else { return nil }
        return NotificationContext(client: client, account: notificationAccount, enrollment: enrollment)
    }

    private func isCurrent(_ context: NotificationContext) -> Bool {
        phase == .connected && client === context.client && notificationAccount == context.account
    }

    private func resetNotificationRuntime() {
        conversationWatch?.cancel(); conversationWatch = nil
        sessionActivities = [:]; sentPreviews = [:]
        notificationPreference.reset()
        showingSettings = false
        backgroundTransition?.cancel(); backgroundTransition = nil
        recoveryTask?.cancel(); recoveryTask = nil
        wasBackgrounded = false
        presenceTask?.cancel(); presenceTask = nil
        notificationOperationID = nil
        notificationBusy = false
        enrollment = nil
        notificationsEnabled = false
        allSessionNotifications = false
        notificationScopeBusy = false
        notificationScopeOperationID = nil
        followedConversations = []
        mutedConversations = []
        notificationStatus = nil
        notificationDestination = nil
        companionUpdate = nil
        updateProgress = nil
        updateDestination = nil
        installedCompanionVersion = nil
        updateCheckMessage = nil
        updateTrackingSupported = false
    }

    func pair(with invitation: CompanionInvitation, phonePrivateKey: Data? = nil) async {
        let connection = invitation.connection
        do {
            // Keep the same device key across a pending approval or an interrupted pairing attempt.
            let existing = try CredentialStore.readValue(CompanionCredentials.self, account: connection.keychainAccount)
            if let existing, let phonePrivateKey, existing.privateKey != phonePrivateKey {
                throw CompanionCryptoError.authenticationFailed
            }
            let credentials = existing ?? CompanionCredentials(deviceToken: invitation.device_token,
                privateKey: phonePrivateKey ?? CompanionCrypto.generatePrivateKey(), pairingSecret: invitation.pairing_secret)
            try CredentialStore.saveValue(credentials, account: connection.keychainAccount)
            pairingPhonePublicKey = try CompanionCrypto.publicKey(for: credentials.privateKey)
            defer { pairingPhonePublicKey = nil }
            await connectCompanion(connection, credentials: credentials, restoring: false)
        } catch { errorMessage = error.localizedDescription }
    }

    private func connectCompanion(_ identity: CompanionConnection, credentials: CompanionCredentials, restoring: Bool) async {
        guard phase != .connecting else { return }
        resetNotificationRuntime()
        generation += 1
        let connectionID = UUID()
        connectionAttemptID = connectionID
        client.disconnect()
        client = HermesClient()
        let connection = client
        connection.onConnected = { [weak self, weak connection] in
            guard let self, let connection, self.client === connection else { return }
            self.profileRefresh.phase = .checking
            if self.selectedProfile != nil { self.sessionRefresh.phase = .checking }
            if self.selectedSession != nil { self.conversationRefresh.phase = .checking }
        }
        connection.onSessionEvent = { [weak self, weak connection] profile, sessionID, type, payload in
            guard let self, let connection, self.client === connection else { return }
            self.trackSessionEvent(profile: profile, sessionID: sessionID, type: type, payload: payload)
        }
        connection.onInteraction = { [weak self, weak connection] event in
            guard let self, let connection, self.client === connection else { return }
            self.receive(event, assistantID: "")
        }
        phase = restoring ? .restoring : .connecting
        errorMessage = nil
        connectionNotice = nil
        do {
            let bots = try await connection.connect(companion: identity, credentials: credentials)
            guard client === connection, connectionAttemptID == connectionID else { return }
            let savedSettings = ConnectionSettings(address: identity.relayURL, companion: identity)
            var savedCredentials = credentials
            savedCredentials.pairingSecret = nil
            try CredentialStore.saveValue(savedCredentials, account: identity.keychainAccount)
            UserDefaults.standard.set(try JSONEncoder().encode(savedSettings), forKey: Self.connectionKey)
            profiles = bots
            settings = savedSettings
            if !restoring {
                cachedContent = ContentSnapshot()
                selectedProfile = nil; selectedSession = nil
                sessions = []; messages = []; resetHistoryPagination(); resetCommands()
            }
            cacheProfiles(bots)
            // Warm conversation lists while onboarding still shows connection progress.
            preparedSessions = [:]
            preparedSessionsClient = connection
            for profile in restoring ? [] : bots {
                let conversations = try? await connection.sessions(profile: profile.id)
                guard client === connection, connectionAttemptID == connectionID else { return }
                preparedSessions[profile.id] = conversations
            }
            // Load local notification identity/preferences before exposing a ready connection.
            // Opening a chat may save follow preferences before push registration finishes.
            let restoredNotificationPreferences = restoreNotificationPreferences()
            phase = .connected
            if PushNotifications.shared.pendingReference != nil { await processPendingNotification() }
            else { await refreshVisibleCachedContent() }
            if restoredNotificationPreferences && notificationsEnabled { await setNotificationsEnabled(true) }
            await refreshCompanionUpdate()
        } catch {
            guard client === connection, connectionAttemptID == connectionID else { return }
            connection.disconnect()
            phase = .disconnected
            markContentUnavailable()
            if restoring {
                connectionNotice = ConnectionRecovery.companionFailure(error)
            } else { errorMessage = error.localizedDescription }
        }
    }

    var visibleCompanionUpdate: CompanionUpdateNotice? {
        guard let notice = companionUpdate,
              UserDefaults.standard.string(forKey: notificationAccount + "/dismissed-companion-update") != notice.version else { return nil }
        return notice
    }

    func dismissCompanionUpdate() {
        guard let notice = companionUpdate else { return }
        UserDefaults.standard.set(notice.version, forKey: notificationAccount + "/dismissed-companion-update")
        companionUpdate = nil
    }

    func refreshCompanionUpdate(force: Bool = false) async {
        guard let context = notificationContext(), !checkingCompanionUpdate else { return }
        checkingCompanionUpdate = true
        defer { checkingCompanionUpdate = false }
        do {
            let capabilities = try await context.client.companionAPI("capabilities")
            guard isCurrent(context) else { return }
            let update = capabilities["update"] as? [String: Any] ?? [:]
            installedCompanionVersion = update["installed"] as? String
            updateTrackingSupported = update["tracking"] as? Int == 1
            companionUpdate = CompanionUpdateNotice(capabilities: capabilities)
            if updateProgress == nil, let data = UserDefaults.standard.data(forKey: context.account + "/update-request") {
                updateProgress = try? JSONDecoder().decode(CompanionUpdateProgress.self, from: data)
            }
            if let progress = updateProgress, progress.status != "completed", updateTrackingSupported {
                do {
                    let result = try await context.client.companionAPI("update-requests/" + progress.receipt.id, enrollment: context.enrollment)
                    guard isCurrent(context), updateProgress?.receipt.id == progress.receipt.id,
                          let status = result["status"] as? String,
                          ["queued", "running", "completed", "failed"].contains(status) else { return }
                    // A queued receipt does not undo a confirmed model failure.
                    // A running installer or verified completion still takes precedence.
                    if status != "queued" || updateProgress?.status != "failed" {
                        updateProgress?.status = status
                        updateProgress?.installed = result["installed"] as? String
                        updateProgress?.error = result["error"] as? String
                    }
                    saveUpdateProgress()
                } catch let failure as HermesHTTPError where failure.statusCode == 404 {
                    // A backend restart can erase its in-memory failed-turn
                    // snapshot. An explicitly reopened, idle chat plus a missing
                    // installer receipt still gives the user a recovery path.
                    if isCurrent(context), updateProgress?.receipt.id == progress.receipt.id,
                       selectedUpdateProgress != nil, sessionReady, !isSending,
                       !startingCompanionUpdate, !context.client.isRemoteTurnRunning {
                        failCompanionUpdate("Hermes is no longer working on this request, and the update hasn’t been verified. Try again.")
                    }
                } catch {
                    // An unavailable status endpoint is not evidence of failure.
                }
            }
            guard isCurrent(context) else { return }
            if let progress = updateProgress,
               ["requested", "queued", "failed", "unconfirmed"].contains(progress.status),
               let installed = installedCompanionVersion.flatMap(CompanionUpdateNotice.components),
               let target = CompanionUpdateNotice.components(progress.receipt.target),
               !installed.lexicographicallyPrecedes(target) {
                // A separate host update can satisfy an older request without
                // completing its receipt. Retire the obsolete attempt rather
                // than claim that its installer verified completion.
                updateProgress = nil
                UserDefaults.standard.removeObject(forKey: context.account + "/update-request")
            }
            if installedCompanionVersion != nil && (force || update["checks_enabled"] as? Bool != false) {
                let release = try await CompanionReleaseFeed.shared.latest(force: force)
                guard isCurrent(context) else { return }
                if let installed = installedCompanionVersion {
                    companionUpdate = CompanionUpdateNotice(installed: installed, latest: release.version)
                }
                updateCheckMessage = companionUpdate == nil ? "Your companion is up to date." : nil
            } else {
                updateCheckMessage = "Automatic update checks are disabled on this Hermes host."
            }
        } catch {
            if force, isCurrent(context) { updateCheckMessage = "Couldn’t check for updates. Check the connection and try again." }
        }
    }

    private func saveUpdateProgress() {
        UserDefaults.standard.set(try? JSONEncoder().encode(updateProgress), forKey: notificationAccount + "/update-request")
    }

    func dismissFinishedUpdate() {
        guard updateProgress?.pending == false else { return }
        updateProgress = nil
        UserDefaults.standard.removeObject(forKey: notificationAccount + "/update-request")
    }

    var canStartCompanionUpdate: Bool {
        phase == .connected && profiles.contains(where: { $0.id == "default" }) &&
        (settings?.companion?.deviceID ?? enrollment?.deviceID) != nil &&
        !startingCompanionUpdate && !isSending && !isRunningCommand && !isLoadingMessages &&
        !isSwitchingConversation && openingBotProfileID == nil && updateProgress?.pending != true
    }

    var canRetryCompanionUpdate: Bool {
        phase == .connected && updateProgress?.status == "failed" &&
        profiles.contains(where: { $0.id == updateProgress?.receipt.profile }) &&
        !startingCompanionUpdate && !isSending && !isRunningCommand &&
        !checkingCompanionUpdate && !isLoadingMessages && !isSwitchingConversation && openingBotProfileID == nil
    }

    var selectedUpdateProgress: CompanionUpdateProgress? {
        guard let progress = updateProgress, progress.receipt.profile == selectedProfile?.id,
              progress.receipt.session_id == selectedSession?.id else { return nil }
        return progress
    }

    private var isSelectedUpdateUnfinished: Bool {
        selectedUpdateProgress.map { $0.status != "completed" } ?? false
    }

    private func failCompanionUpdate(_ message: String) {
        guard updateProgress?.status != "completed" else { return }
        updateProgress?.status = "failed"
        let visible = message.components(separatedBy: "\nDetails:").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        updateProgress?.error = visible.isEmpty ? "The update did not complete. Try again." : visible
        saveUpdateProgress()
    }

    func startCompanionUpdate(_ notice: CompanionUpdateNotice) async {
        guard canStartCompanionUpdate, let context = notificationContext(),
              let profile = profiles.first(where: { $0.id == "default" }),
              let deviceID = settings?.companion?.deviceID ?? enrollment?.deviceID else { return }
        startingCompanionUpdate = true
        defer { startingCompanionUpdate = false }
        updateDestination = nil
        // Select and create through the normal conversation lifecycle. No prompt is sent before this explicit action.
        // The full session list and notification follow request are unnecessary
        // prerequisites for opening a new update conversation.
        await selectProfile(profile, refresh: false)
        guard isCurrent(context), selectedProfile?.id == profile.id else { return }
        await createSession(followInBackground: true)
        guard isCurrent(context), sessionReady, let session = selectedSession else { return }
        let receipt = CompanionUpdateReceipt(id: UUID().uuidString.lowercased(), device_id: deviceID.lowercased(),
            profile: profile.id, session_id: session.id, target: notice.version, notify: notificationsEnabled,
            created: Date().timeIntervalSince1970)
        updateProgress = CompanionUpdateProgress(receipt: receipt)
        saveUpdateProgress()
        do {
            guard isCurrent(context), selectedSession?.id == session.id else { return }
            let prompt = try receipt.prompt
            showingSettings = false
            updateDestination = FollowedConversation(profile: profile.id, sessionID: session.id)
            // Keep the short user-facing message when persisted history is reloaded.
            let accepted = await sendPrompt(prompt, displayText: receipt.displayText, photos: [])
            guard isCurrent(context) else { return }
            if !accepted {
                failCompanionUpdate(errorMessage ?? "The update request was not sent. Check the connection and try again.")
                errorMessage = nil
            }
            await refreshCompanionUpdate()
        } catch {
            guard isCurrent(context) else { return }
            updateProgress?.status = "failed"
            updateProgress?.error = "The update request could not be started. No update prompt was sent. Try again when connected."
            saveUpdateProgress()
            updateCheckMessage = updateProgress?.error
        }
    }

    func retryCompanionUpdate() async {
        guard canRetryCompanionUpdate, let context = notificationContext(), let receipt = updateProgress?.receipt else { return }
        startingCompanionUpdate = true
        defer { startingCompanionUpdate = false }
        // Recheck the durable installer receipt before resubmitting. Reuse its
        // identity so a retried tool cannot start a duplicate verified install.
        await refreshCompanionUpdate()
        guard isCurrent(context), updateProgress?.receipt.id == receipt.id,
              updateProgress?.status == "failed" else { return }
        await openUpdateConversation()
        guard isCurrent(context), sessionReady, selectedSession?.id == receipt.session_id,
              updateProgress?.status == "failed", !client.isRemoteTurnRunning else { return }
        do {
            let retryReceipt = Date().timeIntervalSince1970 - receipt.created >= 86400
                ? CompanionUpdateReceipt(id: UUID().uuidString.lowercased(), device_id: receipt.device_id,
                    profile: receipt.profile, session_id: receipt.session_id, target: receipt.target,
                    notify: receipt.notify, created: Date().timeIntervalSince1970)
                : receipt
            let prompt = try retryReceipt.prompt
            updateProgress = CompanionUpdateProgress(receipt: retryReceipt)
            errorMessage = nil
            saveUpdateProgress()
            let accepted = await sendPrompt(prompt, displayText: retryReceipt.displayText, photos: [])
            guard isCurrent(context) else { return }
            if !accepted {
                failCompanionUpdate(errorMessage ?? "The update request was not sent. Check the connection and try again.")
                errorMessage = nil
            }
            await refreshCompanionUpdate()
        } catch {
            if isCurrent(context) { failCompanionUpdate("The update request could not be started. Check the connection and try again.") }
        }
    }

    func openUpdateConversation() async {
        guard let receipt = updateProgress?.receipt,
              let profile = profiles.first(where: { $0.id == receipt.profile }), !isSending else { return }
        let session = sessions.first(where: { selectedProfile?.id == profile.id && $0.id == receipt.session_id })
            ?? HermesSession(id: receipt.session_id, title: "Companion update", preview: "", lastActive: .now, messageCount: 0, source: "desktop")
        showingSettings = false
        await openSession(session, in: profile, notificationReference: nil)
        if selectedSession?.id == session.id {
            updateDestination = nil
            updateDestination = FollowedConversation(profile: profile.id, sessionID: session.id)
            await refreshCompanionUpdate()
        }
    }

    func cancelPairing() {
        guard phase == .connecting else { return }
        generation += 1
        client.disconnect()
        phase = .disconnected
    }

    private func restoreNotificationPreferences() -> Bool {
        notificationPreference.reset()
        presenceTask?.cancel()
        notificationOperationID = nil
        notificationBusy = false
        notificationStatus = nil
        enrollment = nil
        let prefs = UserDefaults.standard.dictionary(forKey: notificationPreferencesKey) ?? [:]
        notificationsEnabled = prefs["enabled"] as? Bool ?? false
        allSessionNotifications = notificationsEnabled && (prefs["allSessions"] as? Bool ?? false)
        followedConversations = decodeFollows(prefs["followed"] as? Data)
        mutedConversations = decodeFollows(prefs["muted"] as? Data)
        do {
            enrollment = try CredentialStore.readValue(CompanionEnrollment.self, account: notificationAccount)
        } catch {
            notificationStatus = "Couldn’t restore the saved notification registration: \(error.localizedDescription)"
            return false
        }
        return true
    }

    private func decodeFollows(_ data: Data?) -> Set<FollowedConversation> {
        guard let data, let values = try? JSONDecoder().decode([FollowedConversation].self, from: data) else { return [] }
        return Set(values)
    }

    private func saveNotificationPreferences() {
        UserDefaults.standard.set(["enabled": notificationsEnabled, "allSessions": allSessionNotifications,
            "followed": (try? JSONEncoder().encode(Array(followedConversations))) ?? Data(),
            "muted": (try? JSONEncoder().encode(Array(mutedConversations))) ?? Data()], forKey: notificationPreferencesKey)
    }

    func setAllSessionNotifications(_ enabled: Bool) async {
        guard let context = notificationContext(), !notificationScopeBusy, !notificationBusy,
              !notificationPreference.isSaving else { return }
        let operationID = UUID()
        notificationScopeOperationID = operationID
        notificationScopeBusy = true
        defer {
            if notificationScopeOperationID == operationID {
                notificationScopeBusy = false
                notificationScopeOperationID = nil
            }
        }
        do {
            let capabilities = try await context.client.companionAPI("capabilities")
            guard isCurrent(context) else { return }
            guard capabilities["notification_scope"] as? Int == 1 else {
                throw HermesError.message("Update the companion to enable notifications for all sessions.")
            }
            if enabled && !notificationsEnabled {
                if let error = await setNotificationsEnabled(true) { throw HermesError.message(error) }
                guard isCurrent(context), notificationsEnabled else { return }
            }
            _ = try await context.client.companionAPI("devices/self/notification-scope", method: "PUT",
                body: ["all_sessions": enabled], enrollment: enrollment ?? context.enrollment)
            guard isCurrent(context) else { return }
            allSessionNotifications = enabled
            notificationStatus = nil
            saveNotificationPreferences()
        } catch { if isCurrent(context) { notificationStatus = error.localizedDescription } }
    }

    func requestNotificationsEnabled(_ enabled: Bool) {
        guard let context = notificationContext() else { return }
        notificationPreference.request(enabled) { [weak self] requested in
            guard let self else { return nil }
            // Restoration may already be registering this connection. Wait for it
            // before applying user changes; never overlap server writes.
            while self.notificationBusy {
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { return nil }
                guard self.isCurrent(context) else { return nil }
            }
            guard self.isCurrent(context), !Task.isCancelled else { return nil }
            return await self.setNotificationsEnabled(requested)
        }
    }

    @discardableResult
    func setNotificationsEnabled(_ enabled: Bool) async -> String? {
        guard let context = notificationContext(), !notificationBusy else { return nil }
        let operationID = UUID()
        notificationOperationID = operationID
        notificationBusy = true
        notificationStatus = nil
        defer {
            if notificationOperationID == operationID {
                notificationOperationID = nil
                notificationBusy = false
            }
        }
        do {
            var registeredEnrollment = context.enrollment
            if settings?.companion == nil && registeredEnrollment == nil {
                registeredEnrollment = try CredentialStore.readValue(CompanionEnrollment.self, account: context.account)
            }
            if enabled {
                let capabilities = try await context.client.companionAPI("capabilities")
                guard capabilities["push_enabled"] as? Bool == true else {
                    throw HermesError.message("Enable push in the Hermes Jr. companion on your host first. Its push service must be configured for this app.")
                }
                guard isCurrent(context) else { return nil }
                if settings?.companion == nil && registeredEnrollment == nil {
                    let result = try await context.client.companionAPI("enroll", method: "POST", body: ["device_name": "Hermes Jr. iPhone"])
                    guard isCurrent(context) else { return nil }
                    guard let id = result["device_id"] as? String, UUID(uuidString: id) != nil,
                          let token = result["device_token"] as? String, !token.isEmpty,
                          let installation = result["installation_id"] as? String else {
                        throw HermesError.message("The companion returned an invalid device registration.")
                    }
                    let registered = CompanionEnrollment(deviceID: id, deviceToken: token, installationID: installation)
                    try CredentialStore.saveValue(registered, account: context.account)
                    enrollment = registered
                    registeredEnrollment = registered
                }
                let token = try await PushNotifications.shared.requestToken()
                guard isCurrent(context) else { return nil }
                var pushBody: [String: Any] = ["apns_token": token, "environment": PushNotifications.shared.environment]
                if capabilities["notification_encryption"] as? Int == 1,
                   settings?.companion != nil || URL(string: settings?.address ?? "")?.scheme?.lowercased() == "https" {
                    pushBody["notification_key"] = try NotificationPreview.key(account: context.account).registration
                }
                _ = try await context.client.companionAPI("devices/self/push", method: "PUT",
                    body: pushBody, enrollment: registeredEnrollment)
                guard isCurrent(context) else { return nil }
                if capabilities["notification_scope"] as? Int == 1 {
                    _ = try await context.client.companionAPI("devices/self/notification-scope", method: "PUT",
                        body: ["all_sessions": allSessionNotifications], enrollment: registeredEnrollment)
                    guard isCurrent(context) else { return nil }
                }
                notificationsEnabled = true
                saveNotificationPreferences()
                try await syncFollows(context, enrollment: registeredEnrollment)
                guard isCurrent(context) else { return nil }
                notificationStatus = nil
                startPresence()
            } else {
                _ = try await context.client.companionAPI("devices/self/push", method: "DELETE", enrollment: registeredEnrollment)
                guard isCurrent(context) else { return nil }
                NotificationPreview.remove(account: context.account)
                notificationsEnabled = false
                allSessionNotifications = false
                presenceTask?.cancel(); presenceTask = nil
                saveNotificationPreferences()
                notificationStatus = nil
            }
        } catch {
            if isCurrent(context) {
                notificationStatus = error.localizedDescription
                return error.localizedDescription
            }
        }
        return nil
    }

    private func syncFollows(_ context: NotificationContext, enrollment: CompanionEnrollment?) async throws {
        guard isCurrent(context) else { return }
        let result = try await context.client.companionAPI("follows", enrollment: enrollment)
        guard isCurrent(context) else { return }
        let remote = (result["follows"] as? [[String: Any]] ?? []).compactMap { row -> FollowedConversation? in
            guard let profile = row["profile"] as? String, let id = row["session_id"] as? String else { return nil }
            return FollowedConversation(profile: profile, sessionID: id)
        }
        for follow in Set(remote).subtracting(followedConversations) {
            guard isCurrent(context) else { return }
            _ = try await context.client.companionAPI("follows", method: "DELETE", query: ["profile": follow.profile, "session_id": follow.sessionID], enrollment: enrollment)
        }
        for follow in followedConversations {
            guard isCurrent(context) else { return }
            _ = try await context.client.companionAPI("follows", method: "PUT", body: ["profile": follow.profile, "session_id": follow.sessionID], enrollment: enrollment)
        }
    }

    private func noteOpened(profile: String, sessionID: String) async {
        let follow = FollowedConversation(profile: profile, sessionID: sessionID)
        guard !mutedConversations.contains(follow) else { return }
        followedConversations.insert(follow)
        saveNotificationPreferences()
        if notificationsEnabled, let context = notificationContext() {
            await updateFollow(follow, enabled: true, context: context)
        }
    }

    func isFollowing(profile: String, sessionID: String) -> Bool {
        followedConversations.contains(FollowedConversation(profile: profile, sessionID: sessionID))
    }

    func setFollowing(profile: String, sessionID: String, enabled: Bool) async {
        let follow = FollowedConversation(profile: profile, sessionID: sessionID)
        if enabled { followedConversations.insert(follow); mutedConversations.remove(follow) }
        else { followedConversations.remove(follow); mutedConversations.insert(follow) }
        saveNotificationPreferences()
        if notificationsEnabled, let context = notificationContext() { await updateFollow(follow, enabled: enabled, context: context) }
    }

    private func updateFollow(_ follow: FollowedConversation, enabled: Bool, context: NotificationContext) async {
        guard isCurrent(context) else { return }
        do {
            if enabled {
                _ = try await context.client.companionAPI("follows", method: "PUT", body: ["profile": follow.profile, "session_id": follow.sessionID], enrollment: context.enrollment)
            } else {
                _ = try await context.client.companionAPI("follows", method: "DELETE", query: ["profile": follow.profile, "session_id": follow.sessionID], enrollment: context.enrollment)
            }
        } catch {
            if isCurrent(context) { notificationStatus = "Couldn’t update notification preferences: \(error.localizedDescription)" }
        }
    }

    func setAppActive(_ active: Bool) {
        appIsActive = active
        if !wasBackgrounded, notificationsEnabled, let context = notificationContext() { Task { await updatePresence(context) } }
    }

    /// Finish the presence update before iOS suspends networking. The remote task keeps running.
    func enterBackground() {
        guard phase == .connected, !wasBackgrounded else { return }
        wasBackgrounded = true
        sessionReady = false
        conversationRefresh.phase = .connecting
        recoveryTask?.cancel()
        presenceTask?.cancel()
        let connection = client
        let context = notificationContext()
        var identifier = UIBackgroundTaskIdentifier.invalid
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Update conversation presence") {
            if identifier != .invalid {
                UIApplication.shared.endBackgroundTask(identifier)
                identifier = .invalid
            }
        }
        backgroundTransition = Task { @MainActor in
            defer {
                if identifier != .invalid { UIApplication.shared.endBackgroundTask(identifier); identifier = .invalid }
            }
            if let context { await updatePresence(context, active: false) }
            guard !Task.isCancelled, client === connection, wasBackgrounded else { return }
            connection.suspendForBackground()
        }
    }

    func returnToForeground() {
        guard wasBackgrounded, phase == .connected else { return }
        let connection = client
        let attempt = generation
        let transition = backgroundTransition
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor in
            await transition?.value
            guard !Task.isCancelled, generation == attempt, client === connection else { return }
            // Let the suspended send unwind before resuming the server's existing session.
            while isSending || isRunningCommand {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard generation == attempt, client === connection else { return }
            }
            guard appIsActive else { return }
            wasBackgrounded = false
            // A notification tap owns the destination. Do not first hydrate the
            // previously open conversation and then start a second navigation load.
            if PushNotifications.shared.pendingReference != nil {
                await processPendingNotification()
                if notificationsEnabled { startPresence() }
                return
            }
            if let profile = selectedProfile, let session = selectedSession, visibleSessionID == session.id {
                isLoadingMessages = true
                conversationRefresh.phase = .checking
                defer { if generation == attempt { isLoadingMessages = false } }
                do {
                    try await connection.openSession(profile: profile.id, sessionID: session.id)
                    if notificationsEnabled { startPresence() }
                    repeat {
                        let wasRunning = connection.isRemoteTurnRunning
                        let page = try await connection.visibleMessagePage(profile: profile.id, sessionID: session.id)
                        guard !Task.isCancelled, generation == attempt, selectedSession?.id == session.id else { return }
                        if !page.messages.isEmpty { mergeRecentMessages(page) }
                        sessionReady = true
                        cacheConversation(messages, profile: profile.id, sessionID: session.id)
                        if !wasRunning { break }
                        try await Task.sleep(for: .seconds(2))
                    } while appIsActive
                } catch {
                    guard !Task.isCancelled, generation == attempt else { return }
                    conversationRefresh.phase = .failed
                    sessionReady = false
                }
            } else if selectedProfile != nil {
                await refreshSessions()
            } else {
                await refreshProfiles()
            }
            if notificationsEnabled { startPresence() }
            await processPendingNotification()
        }
    }

    private func startPresence() {
        presenceTask?.cancel()
        guard let context = notificationContext() else { return }
        presenceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.notificationsEnabled, self.isCurrent(context) else { return }
                await self.updatePresence(context)
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }

    private func updatePresence(_ context: NotificationContext, active: Bool? = nil) async {
        guard isCurrent(context), notificationsEnabled else { return }
        let body: [String: Any] = ["profile": selectedProfile?.id ?? "", "session_id": selectedSession?.id ?? "",
                                   "active": active ?? (appIsActive && selectedSession != nil)]
        _ = try? await context.client.companionAPI("presence", method: "PUT", body: body, enrollment: context.enrollment)
    }

    func openNotification(reference: String) async {
        PushNotifications.shared.rememberNotificationOpen(reference)
        await processPendingNotification()
    }

    /// Runs on connection restoration and when an action finishes. A cold-launch tap survives view creation.
    func processPendingNotification() async {
        guard let reference = PushNotifications.shared.pendingReference,
              let context = notificationContext(), !wasBackgrounded, !isSending, !isRunningCommand,
              !isLoadingMessages, !isSwitchingConversation, openingBotProfileID == nil,
              openingNotificationReference == nil else { return }
        openingNotificationReference = reference
        let lookupGeneration = generation
        defer {
            if openingNotificationReference == reference { openingNotificationReference = nil }
            if let newer = PushNotifications.shared.pendingReference, newer != reference {
                Task { await processPendingNotification() }
            }
        }
        do {
            let result = try await context.client.companionAPI("notifications/" + reference, enrollment: context.enrollment)
            guard isCurrent(context), PushNotifications.shared.pendingReference == reference else { return }
            guard generation == lookupGeneration else {
                // Explicit navigation during resolution wins over an older tap.
                PushNotifications.shared.acknowledgeNotificationOpen(reference)
                return
            }
            guard !isSending, !isRunningCommand, !isLoadingMessages else { return }
            guard let profileID = result["profile"] as? String, let sessionID = result["session_id"] as? String,
                  let profile = profiles.first(where: { $0.id == profileID }) else {
                throw HermesError.message("This notification is no longer available. Open the conversation from its profile.")
            }
            // The authenticated reference already identifies the conversation. A full,
            // potentially paginated session list must not delay opening it.
            let knownSessions = selectedProfile?.id == profileID ? sessions
                : (preparedSessionsClient === client ? preparedSessions[profileID] : nil)
                    ?? cachedContent.sessions[profileID]?.value ?? []
            let session = knownSessions.first(where: { $0.id == sessionID })
                ?? HermesSession(id: sessionID, title: "", preview: "", lastActive: .now, messageCount: 0, source: "")
            await openSession(session, in: profile, notificationReference: reference)
        } catch {
            guard isCurrent(context), generation == lookupGeneration,
                  PushNotifications.shared.pendingReference == reference else { return }
            notificationStatus = error.localizedDescription
            errorMessage = error.localizedDescription
            // An attempted, unavailable destination must not keep replacing subsequent navigation.
            PushNotifications.shared.acknowledgeNotificationOpen(reference)
        }
    }

    func disconnectWithNotifications() async -> DisconnectOutcome {
        guard !notificationBusy, !notificationPreference.isSaving, !Task.isCancelled else { return .canceled }
        let connection = client
        let account = notificationAccount
        let attempt = generation
        if notificationsEnabled {
            await setNotificationsEnabled(false)
            guard client === connection, notificationAccount == account, generation == attempt,
                  !Task.isCancelled else { return .canceled }
            if notificationsEnabled {
                return .needsLocalRemoval(LocalDisconnectConfirmation(client: connection, account: account, generation: attempt))
            }
        }
        disconnect()
        return .disconnected
    }

    /// Only the explicit confirmation can bypass failed remote notification cleanup.
    /// A confirmation from an older connection must never remove a replacement.
    func removeLocalConnection(_ confirmation: LocalDisconnectConfirmation) -> Bool {
        guard client === confirmation.client, notificationAccount == confirmation.account,
              generation == confirmation.generation else { return false }
        disconnect()
        return true
    }
}

struct PendingClarification: Identifiable {
    var id: String
    var question: String
    var choices: [String]
}

struct HermesCommandOutput: Identifiable {
    let id = UUID()
    var title: String
    var text: String
}

struct HermesCommandConfirmation: Identifiable {
    let id = UUID()
    var command: String
    var message: String
    fileprivate var sessionID: String
    fileprivate var generation: Int
}

@MainActor @Observable
final class AppStore {
    var phase: ConnectionPhase = .restoring
    var profiles: [BotProfile] = []
    var sessions: [HermesSession] = []
    var messages: [ChatMessage] = []
    var selectedProfile: BotProfile?
    var selectedSession: HermesSession?
    var visibleSessionID: String?
    var settings: ConnectionSettings? { didSet { loadReadState() } }
    var isLoadingSessions = false
    var isLoadingMessages = false
    var isLoadingOlderMessages = false
    var hasOlderMessages = false
    var olderPageVersion = 0
    var messageWindowStart = 0
    private static let messageWindowSize = 40
    var visibleWindowMessages: [ChatMessage] {
        Array(messages.dropFirst(messageWindowStart).prefix(Self.messageWindowSize))
    }
    var hasEarlierLoadedMessages: Bool { messageWindowStart > 0 }
    var hasNewerLoadedMessages: Bool { messageWindowStart + Self.messageWindowSize < messages.count }
    @ObservationIgnored private var historyOffset = 0
    @ObservationIgnored private var rawMessagePositions: [String: Int] = [:]
    var profileRefresh = ContentRefreshStatus()
    var sessionRefresh = ContentRefreshStatus()
    var conversationRefresh = ContentRefreshStatus()
    var sessionReady = false
    var canBrowseCachedContent: Bool { settings != nil && !profiles.isEmpty }
    @ObservationIgnored private let contentCache: ContentCache
    init(contentCache: ContentCache? = nil) { self.contentCache = contentCache ?? ContentCache() }
    @ObservationIgnored private var connectionAttemptID = UUID()
    @ObservationIgnored private var cachedContent = ContentSnapshot()

    var isSending = false
    var activity: String?
    var sessionActivities: [FollowedConversation: String] = [:]
    var sentPreviews: [FollowedConversation: String] = [:]
    @ObservationIgnored private var conversationWatch: Task<Void, Never>?

    func sessionPreview(_ session: HermesSession, profile: String) -> String {
        let key = FollowedConversation(profile: profile, sessionID: session.id)
        return sessionActivities[key] ?? sentPreviews[key] ?? (session.preview.isEmpty ? "No messages" : session.preview)
    }

    struct ConversationReadState: Codable {
        var unread: Set<FollowedConversation> = []
        var awaitingReply: [FollowedConversation: String] = [:]
        var lastReadMessageIDs: [FollowedConversation: String] = [:]

        enum CodingKeys: String, CodingKey { case unread, awaitingReply, lastReadMessageIDs }
        init() {}
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            unread = try values.decodeIfPresent(Set<FollowedConversation>.self, forKey: .unread) ?? []
            awaitingReply = try values.decodeIfPresent([FollowedConversation: String].self, forKey: .awaitingReply) ?? [:]
            lastReadMessageIDs = try values.decodeIfPresent([FollowedConversation: String].self, forKey: .lastReadMessageIDs) ?? [:]
        }
    }
    var conversationReadState = ConversationReadState()

    private var readStateKey: String { notificationAccount + "/conversation-read-state.v1" }

    private func loadReadState() {
        conversationReadState = UserDefaults.standard.data(forKey: readStateKey)
            .flatMap { try? JSONDecoder().decode(ConversationReadState.self, from: $0) } ?? ConversationReadState()
    }

    private func persistReadState() {
        guard settings != nil, let data = try? JSONEncoder().encode(conversationReadState) else { return }
        UserDefaults.standard.set(data, forKey: readStateKey)
    }

    func isSessionUnread(_ id: String, profile: String) -> Bool {
        conversationReadState.unread.contains(FollowedConversation(profile: profile, sessionID: id))
    }

    func markSessionRead(_ id: String, profile: String) {
        let key = FollowedConversation(profile: profile, sessionID: id)
        var changed = false
        if let latestID = messages.last?.id, selectedSession?.id == id, selectedProfile?.id == profile {
            changed = conversationReadState.lastReadMessageIDs[key] != latestID
            conversationReadState.lastReadMessageIDs[key] = latestID
        }
        if conversationReadState.unread.remove(key) != nil { changed = true }
        if changed { persistReadState() }
    }

    func unreadBoundary(profile: String, sessionID: String) -> String? {
        let key = FollowedConversation(profile: profile, sessionID: sessionID)
        guard conversationReadState.unread.contains(key) else { return nil }
        return conversationReadState.lastReadMessageIDs[key]
    }

    private func assistantMarker(_ rows: [ChatMessage]) -> String {
        guard let message = rows.last(where: { $0.role == "assistant" && !$0.text.isEmpty }) else { return "" }
        return SHA256.hash(data: Data((message.id + "\n" + message.text).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func noteAssistantReply(profile: String, sessionID: String) {
        let key = FollowedConversation(profile: profile, sessionID: sessionID)
        conversationReadState.awaitingReply[key] = nil
        if appIsActive && visibleSessionID == sessionID && selectedProfile?.id == profile {
            conversationReadState.unread.remove(key)
        } else {
            if !conversationReadState.unread.contains(key), conversationReadState.lastReadMessageIDs[key] == nil {
                conversationReadState.lastReadMessageIDs[key] = cachedContent.conversations[profile]?[sessionID]?.value.last?.id
            }
            conversationReadState.unread.insert(key)
        }
        persistReadState()
    }

    private func checkMissedReplies(profile: String) async {
        let account = notificationAccount
        let connection = client
        let pending = conversationReadState.awaitingReply.filter { $0.key.profile == profile }
        for (key, previous) in pending {
            guard !Task.isCancelled, account == notificationAccount, client === connection else { return }
            guard let rows = try? await connection.messages(profile: profile, sessionID: key.sessionID) else { continue }
            guard account == notificationAccount, client === connection,
                  conversationReadState.awaitingReply[key] == previous else { continue }
            let latest = assistantMarker(rows)
            if !latest.isEmpty && latest != previous { noteAssistantReply(profile: profile, sessionID: key.sessionID) }
        }
    }

    private func trackSessionEvent(profile: String, sessionID: String, type: String, payload: [String: Any]) {
        let key = FollowedConversation(profile: profile, sessionID: sessionID)
        switch type {
        case "message.start": sessionActivities[key] = "Thinking…"
        case "message.delta": sessionActivities[key] = "Writing…"
        case "tool.start", "tool.generating": sessionActivities[key] = "Using \(payload["name"] as? String ?? "a tool")"
        case "tool.complete": sessionActivities[key] = "Thinking…"
        case "status.update": sessionActivities[key] = payload["text"] as? String
        case "approval.request": sessionActivities[key] = "Waiting for your approval"
        case "clarify.request": sessionActivities[key] = "Waiting for your answer"
        case "message.complete":
            sessionActivities[key] = nil
            if updateProgress?.receipt.profile == profile, updateProgress?.receipt.session_id == sessionID,
               ["error", "interrupted"].contains(payload["status"] as? String ?? "") {
                failCompanionUpdate(payload["text"] as? String ?? "Hermes could not complete the update request. Try again.")
            }
            if payload["status"] as? String != "error" && payload["status"] as? String != "interrupted" {
                noteAssistantReply(profile: profile, sessionID: sessionID)
            }
        default: break
        }
    }

    @discardableResult
    private func prepareConversationSwitch() async -> Int {
        guard !Task.isCancelled else { return generation }
        if let profile = selectedProfile, let session = selectedSession, !messages.isEmpty {
            cacheConversation(messages.filter { !$0.isStreaming || !$0.text.isEmpty }, profile: profile.id, sessionID: session.id)
        }
        conversationWatch?.cancel(); conversationWatch = nil
        generation += 1
        isLoadingOlderMessages = false
        let attempt = generation
        await client.detachConversation()
        guard generation == attempt else { return attempt }
        isSending = false
        activity = nil
        pendingApproval = nil
        pendingClarification = nil
        pendingSessionHandoff = nil
        return attempt
    }

    private func watchRunningConversation(profile: BotProfile, session: HermesSession) {
        guard client.isRemoteTurnRunning else { return }
        let connection = client
        let attempt = generation
        isSending = true
        activity = sessionActivities[FollowedConversation(profile: profile.id, sessionID: session.id)] ?? "Thinking…"
        conversationWatch = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if generation == attempt { isSending = false; activity = nil } }
            repeat {
                let running = connection.isRemoteTurnRunning
                do {
                    let page = try await connection.visibleMessagePage(profile: profile.id, sessionID: session.id)
                    guard !Task.isCancelled, generation == attempt, client === connection else { return }
                    if !page.messages.isEmpty { mergeRecentMessages(page) }
                    cacheConversation(messages, profile: profile.id, sessionID: session.id)
                    activity = sessionActivities[FollowedConversation(profile: profile.id, sessionID: session.id)]
                    if !running { break }
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    guard !Task.isCancelled, generation == attempt else { return }
                    errorMessage = error.localizedDescription
                    break
                }
            } while appIsActive
        }
    }

    var errorMessage: String?
    var pendingApproval: PendingApproval?
    var pendingClarification: PendingClarification?
    var availableCommands: [HermesCommandSuggestion] = []
    var commandSuggestions: [HermesCommandSuggestion] = []
    var isLoadingCommands = false
    var commandError: String?
    var isRunningCommand = false
    var commandResult: HermesCommandOutput?
    var pendingCommandConfirmation: HermesCommandConfirmation?
    var commandDraft: String?
    var companionUpdate: CompanionUpdateNotice?
    var installedCompanionVersion: String?
    var updateProgress: CompanionUpdateProgress?
    var updateDestination: FollowedConversation?
    var checkingCompanionUpdate = false
    var startingCompanionUpdate = false
    var updateCheckMessage: String?
    private var updateTrackingSupported = false
    let notificationPreference = NotificationPreferenceUpdate()
    var showingSettings = false
    var notificationsEnabled = false
    var allSessionNotifications = false
    var notificationScopeBusy = false
    private var notificationScopeOperationID: UUID?
    var notificationBusy = false
    var notificationStatus: String?
    var notificationDestination: FollowedConversation?
    var followedConversations: Set<FollowedConversation> = []
    var connectionNotice: ConnectionRecovery?
    var pairingPhonePublicKey: Data?

    @ObservationIgnored private var client = HermesClient()
    @ObservationIgnored private var preparedSessions: [String: [HermesSession]] = [:]
    @ObservationIgnored private weak var preparedSessionsClient: HermesClient?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var sessionLoadID = 0
    @ObservationIgnored private var didRestore = false
    @ObservationIgnored private var commandLoadID = 0
    @ObservationIgnored private var commandCatalogLoaded = false
    @ObservationIgnored private var enrollment: CompanionEnrollment?
    @ObservationIgnored private var mutedConversations: Set<FollowedConversation> = []
    @ObservationIgnored private var presenceTask: Task<Void, Never>?
    @ObservationIgnored private var appIsActive = true
    @ObservationIgnored private var backgroundTransition: Task<Void, Never>?
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var wasBackgrounded = false
    @ObservationIgnored private var notificationOperationID: UUID?
    private(set) var openingNotificationReference: String?
    private static let connectionKey = "hermes.connection.settings.v1"

    func retrySavedConnection() async {
        guard phase == .disconnected, connectionNotice?.canRetry == true else { return }
        didRestore = false
        connectionNotice = nil
        errorMessage = nil
        phase = .restoring
        await restoreConnection()
    }

    func restoreConnection() async {
        guard !didRestore, phase == .restoring else { return }
        didRestore = true
        guard let data = UserDefaults.standard.data(forKey: Self.connectionKey),
              let saved = try? JSONDecoder().decode(ConnectionSettings.self, from: data) else {
            phase = .disconnected
            return
        }
        settings = saved
        cachedContent = contentCache.load(saved)
        profiles = cachedContent.profiles?.value ?? []
        profileRefresh = ContentRefreshStatus(phase: .connecting, updatedAt: cachedContent.profiles?.updatedAt)
        do {
            if let companion = saved.companion {
                guard let credentials = try CredentialStore.readValue(CompanionCredentials.self, account: companion.keychainAccount) else {
                    connectionNotice = .pairAgain
                    phase = .disconnected
                    markContentUnavailable()
                    return
                }
                await connectCompanion(companion, credentials: credentials, restoring: true)
                return
            }
            let credentials = saved.usesSavedCredentials == true ? try CredentialStore.read(account: saved.address) : nil
            await connect(address: saved.address, username: saved.username,
                          password: credentials?.password ?? "", token: credentials?.token ?? "",
                          phaseDuringAttempt: .restoring)
        } catch {
            phase = .disconnected
            connectionNotice = ConnectionRecovery.credentialFailure(error)
            markContentUnavailable()
        }
    }

    /// Called only after the user confirms removing the saved local connection.
    func forgetSavedConnection() {
        guard phase == .disconnected, connectionNotice != nil else { return }
        SetupPairing().cancel()
        disconnect()
    }

    func connect(address: String, username: String, password: String, token: String) async {
        await connect(address: address, username: username, password: password, token: token,
                      phaseDuringAttempt: .connecting)
    }

    private func connect(address: String, username: String, password: String, token: String,
                         phaseDuringAttempt: ConnectionPhase) async {
        guard phase != .connecting || phaseDuringAttempt == .restoring else { return }
        resetNotificationRuntime()
        generation += 1
        let connectionID = UUID()
        connectionAttemptID = connectionID
        client.disconnect()
        client = HermesClient()
        let connection = client
        connection.onConnected = { [weak self, weak connection] in
            guard let self, let connection, self.client === connection else { return }
            self.profileRefresh.phase = .checking
            if self.selectedProfile != nil { self.sessionRefresh.phase = .checking }
            if self.selectedSession != nil { self.conversationRefresh.phase = .checking }
        }
        connection.onSessionEvent = { [weak self, weak connection] profile, sessionID, type, payload in
            guard let self, let connection, self.client === connection else { return }
            self.trackSessionEvent(profile: profile, sessionID: sessionID, type: type, payload: payload)
        }
        connection.onInteraction = { [weak self, weak connection] event in
            guard let self, let connection, self.client === connection else { return }
            self.receive(event, assistantID: "")
        }
        phase = phaseDuringAttempt
        connectionNotice = nil
        errorMessage = nil
        let cleanAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let bots = try await connection.connect(address: cleanAddress, username: username,
                                                    password: password, token: token)
            guard client === connection, connectionAttemptID == connectionID else { return }
            let saved = ConnectionSettings(address: cleanAddress, username: username,
                                           usesSavedCredentials: !password.isEmpty || !token.isEmpty)
            profiles = bots
            settings = saved
            if phaseDuringAttempt != .restoring {
                selectedProfile = nil; selectedSession = nil
                sessions = []; messages = []; resetHistoryPagination(); resetCommands()
                cachedContent = ContentSnapshot()
            }
            cacheProfiles(bots)
            // Load local notification identity/preferences before exposing a ready connection.
            // Opening a chat may save follow preferences before push registration finishes.
            let restoredNotificationPreferences = restoreNotificationPreferences()
            phase = .connected
            if PushNotifications.shared.pendingReference != nil { await processPendingNotification() }
            else { await refreshVisibleCachedContent() }
            do {
                if !password.isEmpty || !token.isEmpty {
                    try CredentialStore.save(SavedCredentials(password: password, token: token), account: cleanAddress)
                } else {
                    // Loopback credentials are bootstrapped anew for each server process.
                    // Only the non-secret address needs to persist for this connection.
                    CredentialStore.delete(account: cleanAddress)
                }
                UserDefaults.standard.set(try JSONEncoder().encode(saved), forKey: Self.connectionKey)
                if restoredNotificationPreferences && notificationsEnabled { await setNotificationsEnabled(true) }
            await refreshCompanionUpdate()
            } catch {
                errorMessage = "Connected, but this sign-in couldn't be saved securely. You'll need to connect again after closing the app."
            }
        } catch {
            guard client === connection, connectionAttemptID == connectionID else { return }
            connection.disconnect()
            phase = .disconnected
            markContentUnavailable()
            if phaseDuringAttempt == .restoring {
                connectionNotice = ConnectionRecovery.companionFailure(error)
            } else { errorMessage = error.localizedDescription }
        }
    }

    func refreshProfiles() async {
        guard phase == .connected else { return }
        let connection = client
        let attempt = connectionAttemptID
        profileRefresh.phase = .checking
        do {
            let result = try await connection.profiles()
            guard client === connection, attempt == connectionAttemptID else { return }
            profiles = result
            cacheProfiles(result)
            await refreshCompanionUpdate()
        } catch {
            if client === connection, attempt == connectionAttemptID { profileRefresh.phase = .failed }
        }
    }

    private(set) var openingBotProfileID: String?
    @ObservationIgnored private var botOpenID: UUID?

    func openBotConversation(_ profile: BotProfile) async {
        guard !isRunningCommand, !isLoadingMessages, !isSwitchingConversation,
              openingBotProfileID == nil, openingNotificationReference == nil, !Task.isCancelled else { return }
        let openID = UUID()
        botOpenID = openID
        openingBotProfileID = profile.id
        defer {
            if botOpenID == openID { botOpenID = nil; openingBotProfileID = nil }
        }
        let connection = client
        let attempt = await prepareConversationSwitch()
        guard !Task.isCancelled, client === connection, generation == attempt, botOpenID == openID else { return }
        selectedProfile = profile
        selectedSession = nil
        sessions = cachedContent.sessions[profile.id]?.value ?? []
        messages = []
        sessionReady = false
        resetHistoryPagination()
        resetCommands()
        errorMessage = nil
        conversationRefresh = ContentRefreshStatus(phase: .checking)
        do {
            guard phase == .connected else {
                throw HermesError.message("Reconnect to Hermes to open this bot conversation.")
            }
            let session = try await connection.botSession(profile: profile.id)
            guard !Task.isCancelled, client === connection, generation == attempt,
                  botOpenID == openID, phase == .connected else { return }
            cacheBotSession(session, profile: profile.id)
            persistContent()
            // The detail screen is already visible. Use the normal history and resume path.
            await openSession(session, in: profile, notificationReference: nil, preparedGeneration: attempt)
        } catch {
            guard !Task.isCancelled, client === connection, generation == attempt, botOpenID == openID else { return }
            conversationRefresh.phase = .failed
            errorMessage = error.localizedDescription
        }
    }

    func selectProfile(_ profile: BotProfile, refresh: Bool = true) async {
        guard !isRunningCommand, !isLoadingMessages, !isSwitchingConversation, openingBotProfileID == nil else { return }
        let switchID = UUID()
        conversationSwitchID = switchID
        defer { if conversationSwitchID == switchID { conversationSwitchID = nil } }
        let connection = client
        let attempt = await prepareConversationSwitch()
        guard !Task.isCancelled, generation == attempt, client === connection,
              conversationSwitchID == switchID else { return }
        selectedProfile = profile
        selectedSession = nil
        let prepared = preparedSessionsClient === client ? preparedSessions.removeValue(forKey: profile.id) : nil
        sessions = prepared ?? cachedContent.sessions[profile.id]?.value ?? []
        sessionReady = false
        sessionRefresh = ContentRefreshStatus(phase: phase == .connected ? .checking : phase == .restoring ? .connecting : .unavailable,
                                              updatedAt: cachedContent.sessions[profile.id]?.updatedAt)
        messages = []
        resetHistoryPagination()
        resetCommands()
        errorMessage = nil
        if let prepared { cacheSessions(prepared, profile: profile.id) }
        else if phase == .connected && refresh { await refreshSessions() }
    }

    func refreshSessions() async {
        guard let profile = selectedProfile else { return }
        guard phase == .connected else { await retryContentConnection(); return }
        sessionRefresh.phase = .checking
        let connection = client
        sessionLoadID += 1
        let loadID = sessionLoadID
        isLoadingSessions = true
        defer { if client === connection, sessionLoadID == loadID { isLoadingSessions = false } }
        do {
            let result = try await connection.sessions(profile: profile.id) { [weak self] page in
                guard let self, self.client === connection, self.selectedProfile?.id == profile.id, self.sessionLoadID == loadID else { return }
                // Preserve cached rows until all pages arrive; a partial page
                // is not evidence that an older conversation was deleted.
                let ids = Set(page.map(\.id))
                self.sessions = page + self.sessions.filter { !ids.contains($0.id) }
                self.isLoadingSessions = false
                if let id = self.selectedSession?.id, let updated = page.first(where: { $0.id == id }) {
                    self.selectedSession = updated
                }
            }
            guard client === connection, selectedProfile?.id == profile.id, sessionLoadID == loadID else { return }
            let returnedIDs = Set(result.map(\.id))
            sessions = result + sessions.filter {
                !returnedIDs.contains($0.id) && sessionActivities[FollowedConversation(profile: profile.id, sessionID: $0.id)] != nil
            }
            cacheSessions(sessions, profile: profile.id)
            await checkMissedReplies(profile: profile.id)
        } catch { if client === connection, selectedProfile?.id == profile.id, sessionLoadID == loadID, !wasBackgrounded { sessionRefresh.phase = .failed } }
    }

    func openSession(_ session: HermesSession) async {
        guard openingBotProfileID == nil else { return }
        guard let profile = selectedProfile else { return }
        await openSession(session, in: profile, notificationReference: nil)
    }

    /// Prepend one page when the top of the transcript becomes visible.
    /// Returns the previous first row so the view can keep it in place.
    func loadOlderMessages() async -> String? {
        guard phase == .connected, sessionReady, hasOlderMessages, !hasEarlierLoadedMessages, !isLoadingOlderMessages,
              let profile = selectedProfile, let session = selectedSession else { return nil }
        let connection = client
        let attempt = generation
        let anchor = messages.first?.id
        let startingOffset = historyOffset
        isLoadingOlderMessages = true
        defer { if attempt == generation { isLoadingOlderMessages = false } }
        do {
            while historyOffset - startingOffset < 100_000 {
                let offset = historyOffset
                let page = try await connection.visibleMessagePage(profile: profile.id, sessionID: session.id, offset: offset, visibleLimit: 30)
                guard attempt == generation, client === connection, selectedSession?.id == session.id,
                      historyOffset == offset else { return nil }
                historyOffset += page.returned
                hasOlderMessages = page.hasOlder
                olderPageVersion += 1
                for (message, position) in zip(page.messages, page.offsetsFromNewest) {
                    rawMessagePositions[message.id] = offset + position
                }
                let existing = Set(messages.map(\.id))
                let older = page.messages.filter { !existing.contains($0.id) }
                if !older.isEmpty {
                    messages.insert(contentsOf: older, at: 0)
                    return anchor
                }
                guard page.hasOlder && page.returned > 0 else { return nil }
            }
            throw HermesError.message("This conversation has too many overlapping history records to locate earlier messages.")
        } catch {
            if attempt == generation, selectedSession?.id == session.id { errorMessage = error.localizedDescription }
            return nil
        }
    }

    func showEarlierLoadedMessages() -> String? {
        guard hasEarlierLoadedMessages else { return nil }
        let anchor = visibleWindowMessages.first?.id
        messageWindowStart = max(0, messageWindowStart - 30)
        return anchor
    }

    func showNewerLoadedMessages() -> String? {
        guard hasNewerLoadedMessages else { return nil }
        let anchor = visibleWindowMessages.last?.id
        messageWindowStart = min(max(0, messages.count - Self.messageWindowSize), messageWindowStart + 30)
        return anchor
    }

    private func setLatestPage(_ page: HermesClient.MessagePage) {
        messages = updateDisplayMessages(page.messages)
        messageWindowStart = 0
        historyOffset = page.returned
        hasOlderMessages = page.hasOlder
        rawMessagePositions = Dictionary(uniqueKeysWithValues: zip(page.messages.map(\.id), page.offsetsFromNewest))
    }

    private func resetHistoryPagination() {
        messageWindowStart = 0
        historyOffset = 0
        rawMessagePositions = [:]
        hasOlderMessages = false
        isLoadingOlderMessages = false
    }

    private func mergeRecentMessages(_ page: HermesClient.MessagePage) {
        let recent = updateDisplayMessages(page.messages)
        guard !recent.isEmpty else { return }
        let wasShowingNewest = !hasNewerLoadedMessages
        let recentIDs = Set(recent.map(\.id))
        if let overlap = messages.firstIndex(where: { recentIDs.contains($0.id) }),
           let shared = zip(recent, page.offsetsFromNewest).first(where: { rawMessagePositions[$0.0.id] != nil }),
           let oldPosition = rawMessagePositions[shared.0.id], shared.1 >= oldPosition {
            // The server offset includes hidden/tool rows too. Move the older
            // page boundary by the raw change, not the visible message count.
            let shift = shared.1 - oldPosition
            historyOffset += shift
            rawMessagePositions = rawMessagePositions.mapValues { $0 + shift }
            for (message, position) in zip(recent, page.offsetsFromNewest) {
                rawMessagePositions[message.id] = position
            }
            messages = Array(messages[..<overlap]) + recent
            let keptIDs = Set(messages.map(\.id))
            rawMessagePositions = rawMessagePositions.filter { keptIDs.contains($0.key) }
        } else {
            messages = recent
            historyOffset = page.returned
            hasOlderMessages = page.hasOlder
            rawMessagePositions = Dictionary(uniqueKeysWithValues: zip(recent.map(\.id), page.offsetsFromNewest))
        }
        messageWindowStart = wasShowingNewest ? max(0, messages.count - Self.messageWindowSize)
                                              : min(messageWindowStart, max(0, messages.count - Self.messageWindowSize))
    }

    private func updateDisplayMessages(_ rows: [ChatMessage]) -> [ChatMessage] {
        guard let progress = selectedUpdateProgress else { return rows }
        return rows.map { row in
            guard row.role == "user", row.text.hasPrefix("Update my Hermes Jr. companion to version "),
                  row.text.contains("--receipt ") else { return row }
            var visible = row
            visible.text = progress.receipt.displayText
            return visible
        }
    }

    private func openSession(_ session: HermesSession, in profile: BotProfile, notificationReference: String?,
                             preparedGeneration: Int? = nil) async {
        guard !isRunningCommand, !isLoadingMessages, !isSwitchingConversation else { return }
        let switchID = UUID()
        conversationSwitchID = switchID
        defer { if conversationSwitchID == switchID { conversationSwitchID = nil } }
        let connection = client
        let reopeningCurrentSession = selectedProfile?.id == profile.id && selectedSession?.id == session.id
        let attempt: Int
        if let preparedGeneration {
            attempt = preparedGeneration
        } else if !reopeningCurrentSession {
            attempt = await prepareConversationSwitch()
        } else {
            guard !isSending else { return }
            attempt = generation
        }
        guard !Task.isCancelled, generation == attempt, client === connection else { return }
        if let notificationReference {
            guard PushNotifications.shared.pendingReference == notificationReference else { return }
        }
        if selectedProfile?.id != profile.id {
            selectedProfile = profile
            let prepared = preparedSessionsClient === connection ? preparedSessions.removeValue(forKey: profile.id) : nil
            sessions = prepared ?? cachedContent.sessions[profile.id]?.value ?? []
            sessionRefresh = ContentRefreshStatus(phase: phase == .connected ? .checking : .unavailable,
                                                  updatedAt: cachedContent.sessions[profile.id]?.updatedAt)
        }
        if !sessions.contains(where: { $0.id == session.id }) { sessions.insert(session, at: 0) }
        selectedSession = session
        sessionReady = false
        resetHistoryPagination()
        conversationRefresh = ContentRefreshStatus(phase: phase == .connected ? .checking : phase == .restoring ? .connecting : .unavailable,
                                                    updatedAt: cachedContent.conversations[profile.id]?[session.id]?.updatedAt)
        if !reopeningCurrentSession {
            messages = Array((cachedContent.conversations[profile.id]?[session.id]?.value ?? []).suffix(10))
            resetCommands()
        }
        errorMessage = nil
        guard phase == .connected else { return }
        isLoadingMessages = true
        // Publish the route with cached content and the load guard already in place.
        // ChatView's onAppear cannot start a duplicate resume/history request.
        if let notificationReference {
            notificationDestination = nil
            notificationDestination = FollowedConversation(profile: profile.id, sessionID: session.id)
            PushNotifications.shared.acknowledgeNotificationOpen(notificationReference)
        }
        defer { if attempt == generation { isLoadingMessages = false } }
        do {
            try await connection.openSession(profile: profile.id, sessionID: session.id)
            guard attempt == generation, client === connection, selectedSession?.id == session.id else { return }
            if selectedUpdateProgress != nil, let failure = connection.lastTurnFailure {
                failCompanionUpdate(failure)
            }
            let page = try await connection.visibleMessagePage(profile: profile.id, sessionID: session.id)
            guard attempt == generation, client === connection, selectedSession?.id == session.id else { return }
            setLatestPage(page)
            sessionReady = true
            cacheConversation(messages, profile: profile.id, sessionID: session.id)
            await noteOpened(profile: profile.id, sessionID: session.id)
            watchRunningConversation(profile: profile, session: session)
        } catch {
            if attempt == generation {
                conversationRefresh.phase = .failed
                if messages.isEmpty || error.localizedDescription.contains("This chat is open in another Hermes window/terminal") { errorMessage = error.localizedDescription }
            }
        }
    }

    struct SessionHandoff {
        let ticket: String
        let profileID: String
        let session: HermesSession
        let generation: Int
    }

    var pendingSessionHandoff: SessionHandoff?
    var isPreparingHandoff = false
    private var conversationSwitchID: UUID?
    private var isSwitchingConversation: Bool { conversationSwitchID != nil }

    var canRequestSessionHandoff: Bool {
        pendingSessionHandoff == nil && !isPreparingHandoff && selectedSession != nil &&
        selectedSession?.title != "Bot Chat" &&
        (errorMessage?.contains("This chat is open in another Hermes window/terminal") == true)
    }

    @discardableResult
    func prepareSessionHandoff() async -> Bool {
        guard !isPreparingHandoff, let context = notificationContext(),
              let profile = selectedProfile, let session = selectedSession else { return false }
        let attempt = generation
        isPreparingHandoff = true
        errorMessage = nil
        defer { isPreparingHandoff = false }
        do {
            let result = try await context.client.companionAPI("session-handoff",
                query: ["profile": profile.id, "session_id": session.id], enrollment: context.enrollment)
            guard attempt == generation, isCurrent(context), selectedSession?.id == session.id else { return false }
            if result["ready"] as? Bool == true {
                await openSession(session)
                return sessionReady && selectedSession?.id == session.id && attempt == generation
            } else if let ticket = result["ticket"] as? String, let message = result["message"] as? String {
                pendingSessionHandoff = SessionHandoff(ticket: ticket, profileID: profile.id,
                                                       session: session, generation: attempt)
                errorMessage = message
            } else {
                errorMessage = result["error"] as? String ?? "This companion does not support session handoff. Update it and try again."
            }
        } catch {
            guard attempt == generation, isCurrent(context), selectedSession?.id == session.id else { return false }
            errorMessage = "Couldn’t prepare the handoff. Check that the companion is up to date. \(error.localizedDescription)"
        }
        return false
    }

    @discardableResult
    func confirmSessionHandoff() async -> Bool {
        guard let handoff = pendingSessionHandoff, let context = notificationContext(),
              generation == handoff.generation, selectedProfile?.id == handoff.profileID,
              selectedSession?.id == handoff.session.id, !isSending, !isRunningCommand else { return false }
        pendingSessionHandoff = nil
        errorMessage = nil
        isLoadingMessages = true
        sessionReady = false
        conversationRefresh.phase = .checking
        do {
            let result = try await context.client.companionAPI("session-handoff", method: "PUT",
                body: ["profile": handoff.profileID, "session_id": handoff.session.id,
                       "ticket": handoff.ticket, "confirm_close_cli": true], enrollment: context.enrollment)
            guard generation == handoff.generation, isCurrent(context), selectedSession?.id == handoff.session.id else { return false }
            isLoadingMessages = false
            guard result["ready"] as? Bool == true else {
                conversationRefresh.phase = .failed
                errorMessage = result["error"] as? String ?? "The handoff could not be completed. Reopen this chat to check its state."
                return false
            }
            await openSession(handoff.session)
            return sessionReady && selectedSession?.id == handoff.session.id && generation == handoff.generation
        } catch {
            guard generation == handoff.generation, isCurrent(context), selectedSession?.id == handoff.session.id else { return false }
            isLoadingMessages = false
            conversationRefresh.phase = .failed
            errorMessage = "The handoff result couldn’t be confirmed. Reopen this chat before trying again."
        }
        return false
    }

    func createSession(followInBackground: Bool = false) async {
        guard phase == .connected else { return }
        guard let profile = selectedProfile, !isRunningCommand, !isLoadingMessages, !isSwitchingConversation else { return }
        let switchID = UUID()
        conversationSwitchID = switchID
        defer { if conversationSwitchID == switchID { conversationSwitchID = nil } }
        let connection = client
        let attempt = await prepareConversationSwitch()
        guard !Task.isCancelled, generation == attempt, client === connection,
              conversationSwitchID == switchID else { return }
        errorMessage = nil
        isLoadingMessages = true
        defer { if attempt == generation { isLoadingMessages = false } }
        do {
            let session = try await connection.createSession(profile: profile.id)
            guard attempt == generation else { return }
            sessions.insert(session, at: 0)
            selectedSession = session
            sessionReady = true
            conversationRefresh = ContentRefreshStatus(phase: .idle, updatedAt: Date())
            messages = []
            resetHistoryPagination()
            resetCommands()
            if followInBackground {
                let connection = client
                Task { [weak self] in
                    guard let self, self.client === connection else { return }
                    await self.noteOpened(profile: profile.id, sessionID: session.id)
                }
            } else { await noteOpened(profile: profile.id, sessionID: session.id) }
        } catch { if attempt == generation { errorMessage = error.localizedDescription } }
    }

    @discardableResult
    func send(_ text: String, photos: [DraftPhoto] = []) async -> Bool {
        guard phase == .connected, sessionReady else { return false }
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunningCommand, pendingCommandConfirmation == nil else { return false }
        if prompt.hasPrefix("/") {
            guard photos.isEmpty else {
                errorMessage = "Remove the attachments before running a Hermes command."
                return false
            }
            return await runCommand(prompt)
        }
        return await sendPrompt(prompt, photos: photos)
    }

    private func sendPrompt(_ text: String, displayText: String? = nil, photos: [DraftPhoto] = []) async -> Bool {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!prompt.isEmpty || !photos.isEmpty), !isSending, !isLoadingMessages,
              let session = selectedSession, let profile = selectedProfile else { return false }
        let attempt = generation
        let connection = client
        let userID = UUID().uuidString
        let assistantID = UUID().uuidString
        let visibleText = displayText ?? prompt
        isSending = true
        activity = "Thinking…"
        let previewKey = FollowedConversation(profile: profile.id, sessionID: session.id)
        let previousPreview = sentPreviews[previewKey]
        conversationReadState.awaitingReply[previewKey] = assistantMarker(messages)
        persistReadState()
        sentPreviews[previewKey] = visibleText.isEmpty ? "Photo" : visibleText
        sessionActivities[previewKey] = "Thinking…"
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index].lastActive = .now
            sessions[index].preview = visibleText.isEmpty ? "Photo" : visibleText
            sessions[index].messageCount = max(1, sessions[index].messageCount)
        }
        pendingApproval = nil
        pendingClarification = nil
        errorMessage = nil
        messages.append(ChatMessage(id: userID, role: "user", text: visibleText, photos: photos, timestamp: Date(), delivery: .sending))
        messages.append(ChatMessage(id: assistantID, role: "assistant", text: "", isStreaming: true))
        defer {
            if attempt == generation {
                isSending = false
                activity = nil
                pendingApproval = nil
                pendingClarification = nil
                if let index = messages.firstIndex(where: { $0.id == assistantID }) {
                    messages[index].isStreaming = false
                    if messages[index].text.isEmpty { messages.remove(at: index) }
                }
            }
        }

        do {
            if (photos.contains(where: { $0.isFile == true }) || connection.isBotConversation), settings?.companion == nil, enrollment == nil {
                do {
                    let result = try await connection.companionAPI("enroll", method: "POST", body: ["device_name": "Hermes Jr. iPhone"])
                    guard attempt == generation, client === connection else { return false }
                    guard let id = result["device_id"] as? String, UUID(uuidString: id) != nil,
                          let token = result["device_token"] as? String, !token.isEmpty,
                          let installation = result["installation_id"] as? String else {
                        throw HermesError.message("The companion returned an invalid device registration.")
                    }
                    let registered = CompanionEnrollment(deviceID: id, deviceToken: token, installationID: installation)
                    try CredentialStore.saveValue(registered, account: notificationAccount)
                    enrollment = registered
                } catch { throw HermesSendError.notSubmitted(error.localizedDescription) }
            }
            try await connection.send(text: prompt, photos: photos, enrollment: enrollment) { [weak self] event in
                guard let self, self.generation == attempt, self.client === connection else { return }
                self.receive(event, assistantID: assistantID)
            }
            guard attempt == generation, client === connection else { return true }
            if wasBackgrounded { return true }
            let photoPaths = connection.lastSentPhotoPaths
            let currentID = connection.storedSessionID ?? session.id
            if currentID != session.id {
                var current = session
                current.id = currentID
                selectedSession = current
                if var bot = profiles.first(where: { $0.id == profile.id })?.botSession, bot.id == session.id {
                    bot.id = currentID
                    cacheBotSession(bot, profile: profile.id)
                }
            }
            // Read the persisted transcript after the server completes. Hermes remains the source
            // of truth for tool output, compaction, and messages from other clients.
            if let page = try? await connection.visibleMessagePage(profile: profile.id, sessionID: currentID),
               !page.messages.isEmpty, attempt == generation, client === connection {
                var transcript = page.messages
                // Keep this device's preview for the just-sent photo. Older server images still
                // use the transcript's attachment placeholder until media history is supported.
                if !photos.isEmpty, !photoPaths.isEmpty, let index = transcript.lastIndex(where: {
                    $0.role == "user" && photoPaths.allSatisfy($0.text.contains)
                }) {
                    transcript[index].photos = photos
                    transcript[index].text = prompt
                }
                mergeRecentMessages(HermesClient.MessagePage(messages: transcript, returned: page.returned,
                                                            hasOlder: page.hasOlder, offsetsFromNewest: page.offsetsFromNewest))
                cacheConversation(messages, profile: profile.id, sessionID: currentID)
            }
            guard attempt == generation, client === connection else { return true }
            Task { [weak self] in
                guard let self, self.generation == attempt, self.client === connection, !self.wasBackgrounded else { return }
                await self.refreshSessions()
            }
            return true
        } catch {
            guard attempt == generation, client === connection else { return true }
            if case HermesSendError.notSubmitted = error {
                conversationReadState.awaitingReply[previewKey] = nil
                persistReadState()
                sentPreviews[previewKey] = previousPreview
                if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index] = session }
                sessionActivities[previewKey] = nil
                messages.removeAll { $0.id == userID || $0.id == assistantID }
                errorMessage = error.localizedDescription
                return false
            }
            if let index = messages.firstIndex(where: { $0.id == userID }), messages[index].delivery == .sending {
                messages[index].delivery = .unknown
            }
            if error is ConversationSuspended || wasBackgrounded { return true }
            if case HermesSendError.turnFailed(let text) = error {
                conversationReadState.awaitingReply[previewKey] = nil
                persistReadState()
                sessionActivities[previewKey] = nil
                if isSelectedUpdateUnfinished {
                    failCompanionUpdate(text)
                    errorMessage = nil
                } else { errorMessage = text }
                return true
            }
            if isSelectedUpdateUnfinished {
                updateProgress?.status = "unconfirmed"
                saveUpdateProgress()
                errorMessage = nil
            }
            // Never automatically resubmit an uncertain turn: it may already be executing tools.
            if let page = try? await connection.visibleMessagePage(profile: profile.id, sessionID: session.id),
               !page.messages.isEmpty, attempt == generation, client === connection {
                mergeRecentMessages(page)
            }
            guard attempt == generation, client === connection else { return true }
            if !isSelectedUpdateUnfinished {
                errorMessage = "\(error.localizedDescription) Check the session before sending again; Hermes may have received your message."
            }
            return true
        }
    }

    func updateCommandSuggestions(_ text: String) async {
        commandLoadID += 1
        let loadID = commandLoadID
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        commandSuggestions = []
        commandError = nil
        guard query.hasPrefix("/"), let session = selectedSession,
              !isSending, !isRunningCommand, !isLoadingMessages else {
            isLoadingCommands = false
            return
        }
        let attempt = generation
        isLoadingCommands = true
        defer { if commandLoadID == loadID { isLoadingCommands = false } }
        do {
            try await Task.sleep(for: .milliseconds(150))
            guard commandLoadID == loadID, !Task.isCancelled else { return }
            if !commandCatalogLoaded {
                let catalog = try await client.commandCatalog()
                guard attempt == generation, selectedSession?.id == session.id,
                      commandLoadID == loadID, !Task.isCancelled else { return }
                availableCommands = catalog.commands
                commandCatalogLoaded = true
                commandError = catalog.warning
            }
            // Preserve the trailing space so Hermes can suggest arguments for an exact command.
            let suggestions = try await client.completeCommand(text)
            guard attempt == generation, selectedSession?.id == session.id,
                  commandLoadID == loadID, !Task.isCancelled else { return }
            commandSuggestions = suggestions
        } catch {
            guard attempt == generation, selectedSession?.id == session.id,
                  commandLoadID == loadID, !Task.isCancelled else { return }
            commandError = error.localizedDescription
        }
    }

    func confirmPendingCommand() {
        guard let confirmation = pendingCommandConfirmation,
              confirmation.generation == generation,
              selectedSession?.id == confirmation.sessionID else {
            pendingCommandConfirmation = nil
            return
        }
        pendingCommandConfirmation = nil
        Task { [weak self] in
            guard let self, confirmation.generation == self.generation,
                  self.selectedSession?.id == confirmation.sessionID else { return }
            let accepted = await self.runCommand(confirmation.command, confirmed: true)
            if !accepted { self.commandDraft = confirmation.command }
        }
    }

    func cancelPendingCommand() {
        if let confirmation = pendingCommandConfirmation,
           confirmation.generation == generation, selectedSession?.id == confirmation.sessionID {
            commandDraft = confirmation.command
        }
        pendingCommandConfirmation = nil
    }

    private func runCommand(_ command: String, confirmed: Bool = false) async -> Bool {
        guard phase == .connected, sessionReady else { return false }
        guard !isSending, !isRunningCommand, !isLoadingMessages,
              let session = selectedSession, let profile = selectedProfile else { return false }
        let attempt = generation
        isRunningCommand = true
        commandLoadID += 1
        isLoadingCommands = false
        commandSuggestions = []
        commandError = nil
        commandResult = nil
        errorMessage = nil
        defer { if attempt == generation { isRunningCommand = false } }
        do {
            let result = try await client.executeCommand(command, confirmed: confirmed)
            guard attempt == generation, selectedSession?.id == session.id else { return true }
            let needsHistory = client.lastCommandNeedsHistoryRefresh
            let needsSessions = client.lastCommandNeedsSessionRefresh
            switch result {
            case .output(let output):
                commandResult = HermesCommandOutput(title: commandTitle(command), text: output)
                if needsHistory || needsSessions {
                    await reloadAfterCommand(profile: profile, session: session, attempt: attempt,
                                             history: needsHistory, sessionList: needsSessions)
                }
            case let .send(message, display, notice):
                if needsHistory || needsSessions {
                    await reloadAfterCommand(profile: profile, session: session, attempt: attempt,
                                             history: needsHistory, sessionList: needsSessions)
                    guard attempt == generation else { return true }
                }
                commandCatalogLoaded = false
                isRunningCommand = false
                let accepted = await sendPrompt(message, displayText: display)
                if attempt == generation, !accepted {
                    // /retry may already have undone a turn. Restore the resulting prompt,
                    // rather than inviting a second execution of the original command.
                    commandDraft = message
                }
                if attempt == generation, let notice, !notice.isEmpty {
                    commandResult = HermesCommandOutput(title: commandTitle(command), text: notice)
                }
                return true
            case let .prefill(message, notice):
                await reloadAfterCommand(profile: profile, session: session, attempt: attempt)
                guard attempt == generation else { return true }
                commandDraft = message
                if !notice.isEmpty {
                    commandResult = HermesCommandOutput(title: commandTitle(command), text: notice)
                }
            case .confirmation(let message):
                pendingCommandConfirmation = HermesCommandConfirmation(
                    command: command, message: message, sessionID: session.id, generation: attempt
                )
            case .newSession:
                isRunningCommand = false
                await createSession()
                return selectedSession?.id != session.id
            case .stopped:
                await reloadAfterCommand(profile: profile, session: session, attempt: attempt, sessionList: false)
                guard attempt == generation else { return true }
                commandResult = HermesCommandOutput(title: commandTitle(command), text: "Asked Hermes to stop the current task and background processes.")
            }
            // Commands can change models, skills, or session state, so the next lookup is fresh.
            guard attempt == generation else { return true }
            commandCatalogLoaded = false
            return true
        } catch {
            guard attempt == generation else { return true }
            if error is ConversationSuspended || wasBackgrounded { return true }
            if case HermesCommandError.outcomeUnknown = error {
                if client.lastCommandNeedsHistoryRefresh || client.lastCommandNeedsSessionRefresh {
                    await reloadAfterCommand(profile: profile, session: session, attempt: attempt,
                                             history: client.lastCommandNeedsHistoryRefresh,
                                             sessionList: client.lastCommandNeedsSessionRefresh)
                }
                guard attempt == generation else { return true }
                errorMessage = error.localizedDescription
                return true
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func reloadAfterCommand(profile: BotProfile, session: HermesSession, attempt: Int,
                                    history: Bool = true, sessionList: Bool = true) async {

        // Compression may replace the persisted session ID. Follow Hermes' new session rather
        // than reloading the stale history or executing the next command in the old session.
        let currentID = client.storedSessionID ?? session.id
        if var bot = profiles.first(where: { $0.id == profile.id })?.botSession, bot.id == session.id {
            bot.id = currentID
            cacheBotSession(bot, profile: profile.id)
        }
        if history {
            do {
                let page = try await client.visibleMessagePage(profile: profile.id, sessionID: currentID)
                guard attempt == generation else { return }
                setLatestPage(page)
                cacheConversation(messages, profile: profile.id, sessionID: currentID)
            } catch {
                guard attempt == generation else { return }
                errorMessage = "The conversation couldn't be refreshed. \(error.localizedDescription)"
            }
        }
        guard attempt == generation else { return }
        if sessionList { await refreshSessions() }
        guard attempt == generation else { return }
        if let updated = sessions.first(where: { $0.id == currentID }) {
            selectedSession = updated
        } else if currentID != session.id {
            var updated = session
            updated.id = currentID
            selectedSession = updated
        }
    }

    private func commandTitle(_ command: String) -> String {
        String(command.split(whereSeparator: \.isWhitespace).first ?? "/")
    }

    private func resetCommands() {
        commandLoadID += 1
        commandCatalogLoaded = false
        availableCommands = []
        commandSuggestions = []
        isLoadingCommands = false
        commandError = nil
        isRunningCommand = false
        commandResult = nil
        pendingCommandConfirmation = nil
        commandDraft = nil
    }

    private func receive(_ event: ChatEvent, assistantID: String) {
        switch event {
        case .accepted:
            if let assistant = messages.firstIndex(where: { $0.id == assistantID }),
               let user = messages[..<assistant].lastIndex(where: { $0.role == "user" }) {
                messages[user].delivery = .delivered
            }
        case .delta(let text):
            if let index = messages.firstIndex(where: { $0.id == assistantID }) { messages[index].text += text }
            activity = "Writing…"
        case .finalText(let text):
            if let index = messages.firstIndex(where: { $0.id == assistantID }) { messages[index].text = text }
        case .activity(let text):
            activity = text
            if let profile = selectedProfile, let session = selectedSession {
                sessionActivities[FollowedConversation(profile: profile.id, sessionID: session.id)] = text
            }
        case .completed: activity = nil
        case let .approval(requestID, command, choices):
            pendingApproval = PendingApproval(id: requestID, command: command, choices: choices)
            activity = "Waiting for your approval"
        case let .clarification(requestID, question, choices):
            pendingClarification = PendingClarification(id: requestID, question: question, choices: choices)
            activity = "Waiting for your answer"
        case let .clarificationExpired(requestID):
            if pendingClarification?.id == requestID { pendingClarification = nil }
        case let .approvalExpired(requestID):
            if pendingApproval?.id == requestID { pendingApproval = nil }
        case .failure(let text): if !wasBackgrounded && !isSelectedUpdateUnfinished { errorMessage = text }
        }
    }

    func resolveApproval(_ choice: String) async {
        guard let approval = pendingApproval, approval.choices.contains(choice) else { return }
        let attempt = generation
        do {
            try await client.respondToApproval(requestID: approval.id, choice: choice)
            guard generation == attempt, pendingApproval?.id == approval.id else { return }
            pendingApproval = nil
            activity = "Continuing…"
        } catch { if generation == attempt { errorMessage = error.localizedDescription } }
    }

    func stop() async {
        guard isSending else { return }
        let attempt = generation
        do {
            try await client.stop()
            guard attempt == generation, isSending else { return }
            pendingApproval = nil
            pendingClarification = nil
            activity = "Stopping…"
        } catch { if generation == attempt { errorMessage = error.localizedDescription } }
    }

    func resolveClarification(_ answer: String) async {
        guard let question = pendingClarification, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let attempt = generation
        do {
            try await client.respondToClarification(requestID: question.id, answer: answer)
            guard attempt == generation, pendingClarification?.id == question.id else { return }
            pendingClarification = nil
            activity = "Continuing…"
        } catch { if attempt == generation { errorMessage = error.localizedDescription } }
    }

    func backToBots() {
        botOpenID = nil
        openingBotProfileID = nil
        guard !isSending, !isRunningCommand else { return }
        generation += 1
        conversationSwitchID = nil
        notificationDestination = nil
        selectedProfile = nil
        selectedSession = nil
        sessions = []
        messages = []
        resetHistoryPagination()
        resetCommands()
        isLoadingSessions = false
        isLoadingMessages = false
        errorMessage = nil
    }

    func backToSessions() {
        guard !isSending, !isRunningCommand else { return }
        generation += 1
        conversationSwitchID = nil
        notificationDestination = nil
        selectedSession = nil
        messages = []
        resetHistoryPagination()
        resetCommands()
        isLoadingMessages = false
        isLoadingSessions = false
        errorMessage = nil
    }

    func disconnect() {
        conversationWatch?.cancel(); conversationWatch = nil
        sessionActivities = [:]; sentPreviews = [:]
        connectionAttemptID = UUID()
        generation += 1
        botOpenID = nil
        openingBotProfileID = nil
        conversationSwitchID = nil
        presenceTask?.cancel(); presenceTask = nil
        client.disconnect()
        if let settings {
            contentCache.remove(settings)
            UserDefaults.standard.removeObject(forKey: notificationPreferencesKey)
            CredentialStore.delete(account: settings.address)
            NotificationPreview.remove(account: notificationAccount)
            CredentialStore.delete(account: notificationAccount)
            if let companion = settings.companion { CredentialStore.delete(account: companion.keychainAccount) }
            UserDefaults.standard.removeObject(forKey: Self.connectionKey)
        }
        settings = nil
        cachedContent = ContentSnapshot()
        sessionReady = false
        profileRefresh = ContentRefreshStatus()
        connectionNotice = nil
        didRestore = true
        phase = .disconnected
        profiles = []
        selectedProfile = nil
        selectedSession = nil
        sessions = []
        messages = []
        resetHistoryPagination()
        resetCommands()
        isSending = false
        isLoadingMessages = false
        isLoadingSessions = false
        pendingApproval = nil
        pendingClarification = nil
        activity = nil
        errorMessage = nil
        notificationsEnabled = false
        enrollment = nil
        notificationStatus = nil
        resetNotificationRuntime()
    }


}


extension AppStore {
    func retryContentConnection() async {
        if phase == .connected {
            if let session = selectedSession { await openSession(session) }
            else if selectedProfile != nil { await refreshSessions() }
            else { await refreshProfiles() }
        } else if phase == .disconnected {
            if connectionNotice?.canRetry == true { await retrySavedConnection() }
            else { showingSettings = true }
        }
    }

    private func markContentUnavailable() {
        profileRefresh.phase = .unavailable
        sessionRefresh.phase = .unavailable
        conversationRefresh.phase = .unavailable
        sessionReady = false
    }
    private func persistContent() {
        if let settings { contentCache.save(cachedContent, for: settings) }
    }
    private func cacheProfiles(_ rows: [BotProfile]) {
        let now = Date()
        cachedContent.profiles = CachedContent(value: Array(rows.prefix(100)), updatedAt: now)
        let ids = Set(rows.map(\.id))
        cachedContent.sessions = cachedContent.sessions.filter { ids.contains($0.key) }
        cachedContent.conversations = cachedContent.conversations.filter { ids.contains($0.key) }
        profileRefresh = ContentRefreshStatus(phase: .idle, updatedAt: now)
        persistContent()
    }
    private func cacheSessions(_ rows: [HermesSession], profile: String) {
        let now = Date()
        cachedContent.sessions[profile] = CachedContent(value: Array(rows.filter { !client.isDraft(profile: profile, sessionID: $0.id) }.prefix(500)), updatedAt: now)
        let ids = Set(rows.map(\.id))
        cachedContent.conversations[profile] = cachedContent.conversations[profile]?.filter { ids.contains($0.key) }
        sessionRefresh = ContentRefreshStatus(phase: .idle, updatedAt: now)
        persistContent()
    }
    private func cacheBotSession(_ session: HermesSession, profile: String) {
        if let index = profiles.firstIndex(where: { $0.id == profile }) { profiles[index].botSession = session }
        if selectedProfile?.id == profile { selectedProfile?.botSession = session }
        if let index = cachedContent.profiles?.value.firstIndex(where: { $0.id == profile }) {
            cachedContent.profiles?.value[index].botSession = session
        }
    }
    private func cacheConversation(_ rows: [ChatMessage], profile: String, sessionID: String) {
        if var bot = profiles.first(where: { $0.id == profile })?.botSession, bot.id == sessionID,
           let latest = rows.last(where: { ["user", "assistant"].contains($0.role) && !$0.text.isEmpty }) {
            bot.preview = latest.text
            cacheBotSession(bot, profile: profile)
        }
        if appIsActive && visibleSessionID == sessionID && selectedProfile?.id == profile {
            let key = FollowedConversation(profile: profile, sessionID: sessionID)
            if !conversationReadState.unread.contains(key), let latestID = rows.last?.id {
                if conversationReadState.lastReadMessageIDs[key] != latestID {
                    conversationReadState.lastReadMessageIDs[key] = latestID
                    persistReadState()
                }
            }
            if let previous = conversationReadState.awaitingReply[key] {
                let latest = assistantMarker(rows)
                if !latest.isEmpty && latest != previous {
                    conversationReadState.awaitingReply[key] = nil
                    persistReadState()
                }
            }
        }
        let now = Date()
        conversationRefresh = ContentRefreshStatus(phase: .idle, updatedAt: now)
        guard !client.isDraft(profile: profile, sessionID: sessionID) else { return }
        if rows.isEmpty {
            cachedContent.conversations[profile]?[sessionID] = nil
            persistContent()
            return
        }
        let safeRows = ContentCache.conversationRows(rows)
        guard !safeRows.isEmpty else { return }
        cachedContent.conversations[profile, default: [:]][sessionID] = CachedContent(value: safeRows, updatedAt: now)
        let recent = cachedContent.conversations.flatMap { profile, sessions in sessions.map { (profile, $0.key, $0.value.updatedAt) } }.sorted { $0.2 > $1.2 }
        for row in recent.dropFirst(20) { cachedContent.conversations[row.0]?[row.1] = nil }
        persistContent()
    }
    private func refreshVisibleCachedContent() async {
        if let profile = selectedProfile {
            guard let updated = profiles.first(where: { $0.id == profile.id }) else {
                selectedProfile = nil; selectedSession = nil; sessions = []; messages = []; sessionReady = false
                resetHistoryPagination()
                return
            }
            selectedProfile = updated
            await refreshSessions()
            if let session = selectedSession { await openSession(session) }
        }
    }
}
