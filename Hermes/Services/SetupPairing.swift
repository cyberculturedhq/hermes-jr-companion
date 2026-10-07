import Foundation
import CryptoKit
import Observation

enum SetupFailure: String, Codable {
    case expired, cancelled, unavailable, rejected, verification, unknown

    var title: String {
        switch self {
        case .expired: "Setup expired"
        case .cancelled: "Setup canceled"
        case .unavailable: "Setup no longer available"
        case .rejected: "Setup was not accepted"
        case .verification: "Couldn’t verify this connection"
        case .unknown: "Setup did not finish"
        }
    }
    var message: String {
        switch self {
        case .expired: "This setup timed out. Send Hermes a fresh setup prompt; there is no need to reinstall Companion."
        case .cancelled: "This setup was canceled. Copy a fresh prompt when you’re ready to connect."
        case .unavailable: "This attempt is no longer available from the setup service. Start again with a fresh prompt."
        case .rejected: "The service did not accept this request. Ask Hermes to check Companion’s setup before trying again."
        case .verification: "The connection could not be verified. Do not approve it. Start a new setup with your intended Hermes."
        case .unknown: "Hermes Jr. could not determine why this attempt ended. Ask Hermes to check Companion before trying again."
        }
    }
    static func terminal(_ error: Error) -> SetupFailure? {
        if let failure = error as? SetupFailureError { return failure.reason }
        if error is CompanionCryptoError || error is DecodingError { return .verification }
        switch (error as? SetupHTTPError)?.status {
        case 410: return .expired
        case 404: return .unavailable
        case 401, 403, 409: return .rejected
        default: return nil
        }
    }
}

private struct SetupFailureError: Error { let reason: SetupFailure }

private struct SavedSetupClaim: Codable {
    var claim: SetupClaim
    let ephemeralPrivate: Data
    let expiresAt: Double
}
private struct SavedSetup: Codable {
    let service: String
    let ticket: String
    let prompt: String? // Optional for pending attempts saved by older app versions.
    let intentID: String
    let ownerToken: String
    let phonePrivate: Data
    let expiresAt: Double
    var claims: [String: SavedSetupClaim] = [:]
    var selected: String?
    var failed = false // Decode setup state saved by earlier app versions.
    var failure: SetupFailure?
    var connectionRetry: Bool?
}

struct SetupHTTPError: LocalizedError {
    let status: Int
    var code: String? = nil
    var errorDescription: String? {
        if code == "app_verification_key_limit" {
            return "This device created too many app verification keys. Keep the app installed. Existing connections remain available. Try new setup later."
        }
        if code == "app_verification_unavailable" {
            return "App verification is unavailable. Try new setup later. Existing connections remain available."
        }
        return switch status {
        case 503: "Pairing is unavailable at the service. Please try again later."
        case 404: "This setup attempt is no longer available. Create a fresh setup prompt."
        case 410: "This setup attempt expired. Create a fresh setup prompt."
        case 401, 403, 409: "This setup attempt is no longer valid. Cancel it and create a new setup prompt."
        case 429: "Too many setup requests. Wait a minute and try again."
        default: "The setup service is unavailable. Your current attempt will resume when it reconnects."
        }
    }
}

@MainActor
protocol SetupNetworking {
    func request(service: String, path: String, method: String, body: Data?, token: String?, ticket: String?) async throws -> Data
}

private final class SetupRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class SetupHTTPClient: SetupNetworking {
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config, delegate: SetupRedirectGuard(), delegateQueue: nil)
    }
    func request(service: String, path: String, method: String, body: Data?, token: String?, ticket: String?) async throws -> Data {
        _ = try CompanionInvitation.validatedRelayURL(service)
        guard let url = URL(string: service + path) else { throw CompanionCryptoError.invalidHandshake }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let ticket { request.setValue(ticket, forHTTPHeaderField: "X-Hermes-Setup") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw CompanionCryptoError.invalidHandshake }
        guard (200..<300).contains(response.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                if data.count >= 4096 { bytes.task.cancel(); break }
                data.append(byte)
            }
            let fields = try? JSONDecoder().decode([String: String].self, from: data)
            let allowed = ["app_verification_key_limit", "app_verification_unavailable"]
            let code = (fields?["error"]).flatMap { allowed.contains($0) ? $0 : nil }
            throw SetupHTTPError(status: response.statusCode, code: code)
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 16_384 else { bytes.task.cancel(); throw CompanionCryptoError.messageTooLarge }
            data.append(byte)
        }
        return data
    }
}

@MainActor @Observable
final class SetupPairing {
    nonisolated static let service = "https://hermes-jr-companion.cybercultured.com"
    private let network: any SetupNetworking
    private let appVerification: any AppVerifying
    private let account: String
    private let service: String
    private var pending: SavedSetup?
    private var needsRestore = false
    private var savedSetupInvalid = false
    private var revision = 0
    private(set) var busy = false
    private(set) var confirming = false
    private(set) var comparisons: [SetupComparison] = []
    private(set) var hasSelection = false
    private(set) var pushEnabled = false
    private(set) var pushPermissionDenied = false
    private(set) var setupServiceUnreachable = false
    private(set) var error: String?
    private(set) var promptServiceUnavailable = false
    private(set) var promptRateLimited = false
    var hasAttempt: Bool { pending != nil }
    var failure: SetupFailure? {
        if savedSetupInvalid { return .verification }
        guard let state = pending else { return nil }
        if let reason = state.failure { return reason }
        if state.failed { return .unknown }
        if state.expiresAt <= Date.now.timeIntervalSince1970 || state.claims.values.contains(where: { $0.expiresAt <= Date.now.timeIntervalSince1970 }) { return .expired }
        return nil
    }
    var isFailed: Bool { failure != nil }
    var needsConnectionRetry: Bool { pending?.connectionRetry == true }
    func connectionFailed() {
        guard var state = pending else { return }
        state.connectionRetry = true; try? save(state)
    }
    func retryConnection() {
        guard var state = pending, !isFailed else { return }
        state.connectionRetry = false; try? save(state)
    }
    var prompt: String? {
        // Compatibility for older relays and already-saved attempts only.
        pending.map { $0.prompt ?? HermesCompanionSetup.prompt(ticket: $0.ticket) }
    }

    init(network: (any SetupNetworking)? = nil, account: String = "setup/pending/v1", service: String = SetupPairing.service, appVerification: (any AppVerifying)? = nil) {
        self.network = network ?? SetupHTTPClient(); self.account = account; self.service = service
        self.appVerification = appVerification ?? AppAttestClient()
        _ = restorePending()
    }

    private func restorePending() -> Bool {
        do {
            pending = try CredentialStore.readValue(SavedSetup.self, account: account)
            if let pending, pending.service != service {
                self.pending = nil; CredentialStore.delete(account: account)
            }
            hasSelection = pending?.selected != nil
            needsRestore = false
            savedSetupInvalid = false
            error = nil
            return true
        } catch {
            // A failed read does not prove that the saved attempt is absent.
            // Keep its keys and retry the read before creating another attempt.
            needsRestore = true
            if let failure = error as? CredentialReadError, case .invalidData = failure {
                savedSetupInvalid = true
            }
            self.error = error.localizedDescription
            return false
        }
    }

    private func save(_ state: SavedSetup) throws {
        try CredentialStore.saveValue(state, account: account)
        pending = state; hasSelection = state.selected != nil
    }
    private func call(_ state: SavedSetup, _ method: String, _ suffix: String = "", body: [String: String]? = nil) async throws -> Data {
        try await network.request(service: state.service, path: "/v1/pairing/" + state.intentID + suffix, method: method,
            body: try body.map { try JSONEncoder().encode($0) }, token: state.ownerToken, ticket: state.ticket)
    }
    private func current(_ state: SavedSetup) -> Bool { pending?.intentID == state.intentID && !Task.isCancelled }

    func prepare() async {
        guard !busy else { return }
        if needsRestore, !restorePending() { return }
        guard pending == nil else { return }
        busy = true; error = nil; promptServiceUnavailable = false; promptRateLimited = false
        let attempt = revision
        defer { busy = false }
        do {
            let privateKey = try CredentialStore.readValue(Data.self, account: account + "/admission") ?? CompanionCrypto.generatePrivateKey()
            try CredentialStore.saveValue(privateKey, account: account + "/admission")
            let phoneKey = try CompanionCrypto.publicKey(for: privateKey).companionBase64
            let issuerData = try await network.request(service: service, path: "/v1/pairing/key", method: "GET", body: nil, token: nil, ticket: nil)
            let issuer = try JSONDecoder().decode([String: String].self, from: issuerData)
            let body = issuer["app_attest"] == "required"
                ? try await appVerification.proof(service: service, phoneKey: phoneKey, network: network)
                : try JSONEncoder().encode(["phone_public_key": phoneKey])
            let data = try await network.request(service: service, path: "/v1/pairing/intents", method: "POST",
                body: body, token: nil, ticket: nil)
            struct Created: Decodable { let ticket: String; let owner_token: String; let prompt: String? }
            let created = try JSONDecoder().decode(Created.self, from: data)
            let verified = try SetupTicket.verify(created.ticket, publicKey: issuer["public_key"] ?? "", service: service)
            guard verified.phonePublicKey == phoneKey else { throw CompanionCryptoError.authenticationFailed }
            _ = try SetupCrypto.decode(created.owner_token, count: 32)
            if let prompt = created.prompt {
                guard prompt.utf8.count <= 8_192, prompt.contains(created.ticket),
                      !prompt.contains(created.owner_token) else { throw CompanionCryptoError.invalidHandshake }
            }
            guard attempt == revision, !Task.isCancelled else { return }
            try save(SavedSetup(service: service, ticket: created.ticket, prompt: created.prompt, intentID: verified.intentID,
                ownerToken: created.owner_token, phonePrivate: privateKey, expiresAt: verified.expiresAt))
            CredentialStore.delete(account: account + "/admission")
            try appVerification.didIssueTicket(service: service)
        } catch {
            if attempt == revision {
                promptServiceUnavailable = (error as? SetupHTTPError)?.status == 503
                promptRateLimited = (error as? SetupHTTPError)?.status == 429
                self.error = (promptServiceUnavailable || promptRateLimited) ? nil : error.localizedDescription
            }
        }
    }

    func enablePush() async {
        pushPermissionDenied = false
        guard let state = pending, !isFailed else { return }
        do {
            let token = try await PushNotifications.shared.requestToken()
            guard current(state) else { return }
            _ = try await call(state, "PUT", "/push", body: ["apns_token": token, "environment": PushNotifications.shared.environment])
            if current(state) { pushEnabled = true; error = nil }
        } catch {
            guard current(state) else { return }
            if let failure = error as? PushNotificationError, failure == .permissionDenied {
                pushPermissionDenied = true
                self.error = nil
            } else {
                self.error = error.localizedDescription
            }
        }
    }

    func refresh() async {
        guard !busy, var state = pending, !isFailed else { return }
        busy = true
        defer { busy = false }
        do {
            guard state.expiresAt > Date.now.timeIntervalSince1970 else { throw SetupFailureError(reason: .expired) }
            struct Snapshot: Decodable { let status: String; let selected: String?; let claims: [SetupClaim] }
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: await call(state, "GET"))
            guard current(state) else { return }
            if snapshot.status == "cancelled" { throw SetupFailureError(reason: .cancelled) }
            if snapshot.status == "expired" { throw SetupFailureError(reason: .expired) }
            if snapshot.status == "complete" { throw SetupFailureError(reason: .unavailable) }
            guard snapshot.status == "pending", snapshot.claims.count <= 3,
                  Set(snapshot.claims.map(\.id)).count == snapshot.claims.count,
                  snapshot.selected == nil || snapshot.selected == state.selected else { throw CompanionCryptoError.invalidHandshake }
            var codes: [SetupComparison] = []
            for claim in snapshot.claims {
                try claim.validate()
                if let selected = state.selected, selected != claim.id { continue }
                if state.claims[claim.id] == nil {
                    guard state.claims.count < 3, claim.host_ephemeral == nil, claim.phone_ephemeral == nil else {
                        throw CompanionCryptoError.invalidHandshake
                    }
                    state.claims[claim.id] = SavedSetupClaim(claim: claim, ephemeralPrivate: CompanionCrypto.generatePrivateKey(),
                        expiresAt: min(state.expiresAt, Date.now.timeIntervalSince1970 + 300))
                    try save(state) // Persist before sending the fresh phone key; never re-roll it on retry.
                }
                guard var local = state.claims[claim.id], local.claim.matchesIdentity(claim) else { throw CompanionCryptoError.invalidHandshake }
                guard local.expiresAt > Date.now.timeIntervalSince1970 else { throw SetupFailureError(reason: .expired) }
                let phone = try CompanionCrypto.publicKey(for: local.ephemeralPrivate)
                if let previous = local.claim.host_ephemeral, previous != claim.host_ephemeral { throw CompanionCryptoError.invalidHandshake }
                if let remotePhone = claim.phone_ephemeral {
                    guard remotePhone == phone.companionBase64 else { throw CompanionCryptoError.invalidHandshake }
                } else {
                    _ = try await call(state, "PUT", "/claims/" + claim.id + "/key", body: ["phone_ephemeral": phone.companionBase64])
                    guard current(state) else { return }
                }
                if let encodedHost = claim.host_ephemeral {
                    let host = try SetupCrypto.decode(encodedHost, count: 32)
                    let context = try claim.context(ticket: state.ticket)
                    guard SetupCrypto.commitment(context: context, hostEphemeral: host) == (try SetupCrypto.decode(claim.commitment, count: 32)) else {
                        throw CompanionCryptoError.authenticationFailed
                    }
                    let transcript = SetupCrypto.transcript(context: context, hostEphemeral: host, phoneEphemeral: phone)
                    let code = try SetupCrypto.comparisonCode(privateKey: local.ephemeralPrivate, peer: host, transcript: transcript)
                    codes.append(SetupComparison(id: claim.id, name: claim.host_name, code: code))
                    if state.selected == claim.id {
                        let proof = try SetupCrypto.confirmation(privateKey: local.ephemeralPrivate, peer: host, transcript: transcript)
                        if let received = claim.confirmation, received != proof { throw CompanionCryptoError.authenticationFailed }
                        if claim.confirmation == nil {
                            _ = try await call(state, "PUT", "/claims/" + claim.id + "/confirm", body: ["confirmation": proof])
                            guard current(state) else { return }
                        }
                    }
                }
                local.claim = claim; state.claims[claim.id] = local
            }
            try save(state); comparisons = codes; error = nil; setupServiceUnreachable = false
        } catch {
            guard current(state) else { return }
            if let reason = SetupFailure.terminal(error) {
                state.failed = true; state.failure = reason; try? save(state); comparisons = []
            }
            setupServiceUnreachable = failure == nil
            self.error = failure?.message ?? "The setup service is unreachable."
        }
    }

    /// Only a direct tap on the currently displayed comparison may select a host.
    func confirm(_ id: String) async {
        guard !confirming, let displayed = comparisons.first(where: { $0.id == id }) else { return }
        let attempt = revision
        confirming = true
        defer { confirming = false }
        // Polling owns a snapshot of pending state. Let it finish before saving
        // consent, otherwise that snapshot could overwrite the user's selection.
        while busy {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            guard revision == attempt else { return }
        }
        guard !Task.isCancelled, revision == attempt,
              comparisons.contains(where: { $0.id == id && $0.code == displayed.code }),
              var state = pending, !isFailed, state.selected == nil,
              comparisons.contains(where: { $0.id == id }), let local = state.claims[id],
              local.expiresAt > Date.now.timeIntervalSince1970 else { return }
        do {
            state.selected = id
            try save(state) // Persist the human decision before its proof can leave the phone.
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func enrollment() throws -> (CompanionInvitation, Data)? {
        guard let state = pending, !isFailed, let selected = state.selected,
              let local = state.claims[selected], let encodedHost = local.claim.host_ephemeral,
              let envelope = local.claim.envelope else { return nil }
        do {
            guard local.expiresAt > Date.now.timeIntervalSince1970 else { throw SetupHTTPError(status: 410) }
            let transcript = SetupCrypto.transcript(context: try local.claim.context(ticket: state.ticket),
                hostEphemeral: try SetupCrypto.decode(encodedHost, count: 32), phoneEphemeral: try CompanionCrypto.publicKey(for: local.ephemeralPrivate))
            let data = try SetupCrypto.decryptEnrollment(envelope, phonePrivate: state.phonePrivate,
                hostPublic: SetupCrypto.decode(local.claim.host_public_key, count: 32), transcript: transcript)
            guard let text = String(data: data, encoding: .utf8) else { throw CompanionCryptoError.invalidHandshake }
            let invitation = try CompanionInvitation.parse(text)
            guard invitation.host_public_key == local.claim.host_public_key, invitation.installation_id == local.claim.installation_id,
                  invitation.relay_url == state.service, invitation.expires_at <= state.expiresAt else { throw CompanionCryptoError.authenticationFailed }
            return (invitation, state.phonePrivate)
        } catch {
            var failed = state; failed.failed = true; failed.failure = SetupFailure.terminal(error) ?? .unknown
            try? save(failed); comparisons = []; self.error = error.localizedDescription
            throw error
        }
    }

    func completed() async {
        guard let state = pending else { return }
        clear()
        _ = try? await call(state, "POST", "/complete", body: [:])
    }
    func cancel() {
        let previous = pending
        clear()
        CredentialStore.delete(account: account + "/admission")
        try? appVerification.didIssueTicket(service: service)
        if let previous { Task { _ = try? await call(previous, "POST", "/cancel", body: [:]) } }
    }
    private func clear() {
        promptServiceUnavailable = false
        promptRateLimited = false
        pushPermissionDenied = false
        setupServiceUnreachable = false
        needsRestore = false
        savedSetupInvalid = false
        revision += 1; pending = nil; comparisons = []; hasSelection = false; error = nil; pushEnabled = false
        CredentialStore.delete(account: account)
    }
}
