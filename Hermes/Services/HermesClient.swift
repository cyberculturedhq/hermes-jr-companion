import Foundation
import CoreFoundation

struct ConversationSuspended: Error {}

enum ChatEvent {
    case accepted
    case delta(String)
    case finalText(String)
    case activity(String)
    case completed
    case approval(requestID: String, command: String, choices: [String])
    case clarification(requestID: String, question: String, choices: [String])
    case clarificationExpired(requestID: String)
    case approvalExpired(requestID: String)
    case failure(String)
}

/// Hermes dashboard REST reads and the same JSON-RPC gateway used by its desktop app.
/// API-server keys (port 8642) are a separate credential and cannot authenticate here.
@MainActor
final class HermesClient {
    private struct RPCRejection: LocalizedError {
        let code: Int
        let message: String
        var errorDescription: String? { message }
    }
    private struct PendingRPC {
        let continuation: CheckedContinuation<[String: Any], Error>
        let timeout: Task<Void, Never>
        var writer: Task<Void, Never>?
    }

    private struct ClarificationRequest {
        let clientID: String
        let serverID: String
        let questionID: String?
        let question: String
        let choices: [String]
    }

    private let redirectGuard = HermesRedirectGuard()
    private var http: URLSession
    private var baseURL: URL?
    private var bearerToken = ""
    private var localToken = ""
    private var requiresAuth = true
    private var socket: URLSessionWebSocketTask?
    private var companionTransport: CompanionTransport?
    private var openingSocket: (id: UUID, task: Task<Void, Error>)?
    private var socketGeneration = UUID()
    private var hasSocket: Bool { socket != nil || companionTransport?.isConnected == true }
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var pending: [String: PendingRPC] = [:]
    private var eventHandler: (@MainActor (ChatEvent) -> Void)?
    var onConnected: (@MainActor () -> Void)?
    var onSessionEvent: (@MainActor (String, String, String, [String: Any]) -> Void)?
    private var sessionCoordinates: [String: (profile: String, stored: String)] = [:]
    private var submissionPending = false
    var onInteraction: (@MainActor (ChatEvent) -> Void)?
    private var turnContinuation: CheckedContinuation<Void, Error>?
    private var runtimeSessionID: String?
    private var remoteTurnRunning = false
    var isRemoteTurnRunning: Bool { remoteTurnRunning }
    private(set) var lastTurnFailure: String?
    private var isPreparingSend = false
    private var preparationCancelled = false
    private var uncertainAttachmentSessions = Set<String>()
    private(set) var storedSessionID: String?
    private(set) var lastSentPhotoPaths: [String] = []
    // Only drafts created by this client are exempt from persisted-history reads.
    // Never infer draft status from title or message count on server-listed sessions.
    private var draftSessions: [String: [String: String]] = [:]
    private var botSessionIDs: [String: Set<String>] = [:]
    private var selectedProfile: String?
    var isBotConversation: Bool {
        guard let profile = selectedProfile, let id = storedSessionID else { return false }
        return botSessionIDs[profile]?.contains(id) == true
    }
    private var verifiedGatewayProfile: String?
    private var avatarCache: [String: String] = [:]
    private var clarifications: [ClarificationRequest] = []
    private var cachedCommandCatalog: (sessionID: String, catalog: HermesCommandCatalog)?
    private var isExecutingCommand = false
    private struct BotReply {
        let id: String
        let enrollment: CompanionEnrollment?
    }
    private var activeBotReply: BotReply?
    private var cachedModelOptions: (sessionID: String, result: [String: Any])?
    private(set) var lastCommandNeedsHistoryRefresh = false
    private(set) var lastCommandNeedsSessionRefresh = false

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        http = URLSession(configuration: config, delegate: redirectGuard, delegateQueue: nil)
    }

    func connect(companion: CompanionConnection, credentials: CompanionCredentials) async throws -> [BotProfile] {
        disconnect()
        baseURL = try CompanionInvitation.validatedRelayURL(companion.relayURL)
        companionTransport = CompanionTransport(connection: companion, credentials: credentials)
        try await openSocket()
        onConnected?()
        return try await profiles()
    }

    func companionAPI(_ path: String, method: String = "GET", query: [String: String] = [:],
                      body: [String: Any]? = nil, enrollment: CompanionEnrollment? = nil) async throws -> [String: Any] {
        var headers: [String: String] = [:]
        if let enrollment {
            headers["X-Hermes-Jr-Device"] = enrollment.deviceID
            headers["X-Hermes-Jr-Token"] = enrollment.deviceToken
        }
        let (data, _) = try await request("api/plugins/hermes-jr/v1/" + path, method: method,
                                          query: query, body: body, headers: headers)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HermesError.message("The companion returned an invalid response.")
        }
        return result
    }

    func connect(address: String, username: String = "", password: String = "", token: String = "") async throws -> [BotProfile] {
        disconnect()
        baseURL = try Self.validatedURL(address)
        let health = try await json("api/health", authenticated: false)
        guard health["ok"] as? Bool == true,
              let version = health["version"] as? String, !version.isEmpty,
              let authRequired = health["auth_required"] as? Bool else {
            throw HermesError.message("This address is not a compatible Hermes dashboard. Use its dashboard address, usually port 9119.")
        }
        requiresAuth = authRequired
        let suppliedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if authRequired {
            if !suppliedToken.isEmpty {
                bearerToken = suppliedToken
            } else if !username.isEmpty && !password.isEmpty {
                let providerResponse = try await json("api/auth/providers", authenticated: false)
                let providers = providerResponse["providers"] as? [[String: Any]] ?? []
                let eligible = providers.filter { $0["supports_password"] as? Bool == true }
                guard let provider = eligible.first?["name"] as? String else {
                    throw HermesError.message("This Hermes installation uses browser sign-in. Use a dashboard access token for this version of the app.")
                }
                _ = try await json("auth/password-login", method: "POST", body: ["provider": provider, "username": username, "password": password], authenticated: false)
            } else {
                throw HermesError.message("Enter your Hermes dashboard username and password, or a dashboard access token.")
            }
            _ = try await json("api/auth/me")
        } else if !suppliedToken.isEmpty {
            localToken = suppliedToken
        } else {
            guard let host = baseURL?.host, Self.isLoopback(host) else {
                throw HermesError.message("Automatic local sign-in requires a loopback connection. Enable password authentication on your Hermes dashboard for an iPhone connection.")
            }
            // Hermes intentionally bootstraps its local clients from this exact root script;
            // there is no /api/session-token endpoint. Never follow redirects while reading it.
            let (data, _) = try await request("", authenticated: false)
            let html = String(decoding: data, as: UTF8.self)
            let pattern = #"window\.__HERMES_SESSION_TOKEN__\s*=\s*(\"[^\"\r\n]+\")"#
            let regex = try NSRegularExpression(pattern: pattern)
            guard html.contains("window.__HERMES_AUTH_REQUIRED__=false"),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html),
                  let tokenData = String(html[range]).data(using: .utf8),
                  let extracted = try JSONSerialization.jsonObject(with: tokenData, options: [.fragmentsAllowed]) as? String,
                  !extracted.isEmpty else {
                throw HermesError.message("Hermes did not provide its local dashboard token. Start the dashboard or supply its session token.")
            }
            localToken = extracted
        }
        _ = try await json("api/profiles") // Verify credentials before opening the gateway.
        try await openSocket()
        onConnected?()
        return try await profiles()
    }

    func profiles() async throws -> [BotProfile] {
        let rest = try await json("api/profiles")
        guard let rows = rest["profiles"] as? [[String: Any]] else {
            throw HermesError.message("Hermes returned an unsupported profile list.")
        }
        var avatars = avatarCache
        var botSessions: [String: HermesSession] = [:]
        // The RPC surface provides canonical bot previews and asset flags.
        // REST provides gateway status and ordinary profile descriptions.
        if let extras = try? await rpc("profiles.list", ["include_sessions": true]),
           let richProfiles = extras["profiles"] as? [[String: Any]] {
            // The launch profile need not be named "default" on a hosted installation.
            // Compare identities from the same gateway before enabling unscoped extension APIs.
            if let identity = try? await rpc("config.get", ["key": "profile"]),
               let home = identity["home"] as? String, !home.isEmpty {
                verifiedGatewayProfile = richProfiles.first(where: { $0["path"] as? String == home })?["name"] as? String
            } else { verifiedGatewayProfile = nil }
            for row in richProfiles {
                if let name = row["name"] as? String,
                   let canonical = row["canonical_session"] as? [String: Any],
                   let session = Self.decodeBotSession(canonical) {
                    botSessions[name] = session
                    botSessionIDs[name, default: []].insert(session.id)
                    if let rootID = canonical["id"] as? String { botSessionIDs[name, default: []].insert(rootID) }
                }
            }
            for row in richProfiles where row["has_avatar"] as? Bool == true {
                guard let name = row["name"] as? String, avatars[name] == nil else { continue }
                if let asset = try? await rpc("profiles.get_asset", ["name": name, "asset": "avatar"]),
                   asset["found"] as? Bool == true,
                   let dataURL = asset["data"] as? String, dataURL.utf8.count <= 3_000_000 {
                    avatars[name] = dataURL
                }
            }
        }
        avatarCache = avatars
        return rows.compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty else { return nil }
            return BotProfile(id: name, displayName: row["display_name"] as? String ?? "",
                              summary: row["description"] as? String ?? "", model: row["model"] as? String ?? "",
                              isGatewayRunning: row["gateway_running"] as? Bool ?? false,
                              avatarDataURL: avatars[name], botSession: botSessions[name])
        }
    }

    func botSession(profile: String) async throws -> HermesSession {
        try await ensureSocket()
        // Hermes resolves the exact "Bot Chat" title on the owning profile.
        // Ordinary session lists omit this hidden conversation. Resolve it again
        // on each tap so compression or another device cannot leave a stale ID.
        let response = try await rpc("profiles.list", ["include_sessions": true])
        guard let rows = response["profiles"] as? [[String: Any]],
              let row = rows.first(where: { $0["name"] as? String == profile }) else {
            throw HermesError.message("This profile is unavailable. Refresh the home screen and try again.")
        }
        guard row.keys.contains("canonical_session") else {
            throw HermesError.message("Update Hermes on your computer to open bot conversations.")
        }
        guard !(row["canonical_session"] is NSNull) else {
            throw HermesError.message("No Bot Chat is available for this profile. Open this bot in Hermes, then try again.")
        }
        guard let canonical = row["canonical_session"] as? [String: Any],
              let session = Self.decodeBotSession(canonical) else {
            throw HermesError.message("Hermes returned an invalid bot conversation. Refresh and try again.")
        }
        botSessionIDs[profile, default: []].insert(session.id)
        if let rootID = canonical["id"] as? String { botSessionIDs[profile, default: []].insert(rootID) }
        return session
    }

    static func decodeBotSession(_ row: [String: Any]) -> HermesSession? {
        // The root owns the exact title. Its compression tip can have another title.
        let title = row["root_title"] as? String ?? row["title"] as? String
        guard title == "Bot Chat", let rootID = row["id"] as? String, !rootID.isEmpty else { return nil }
        var resolved = row
        if let tipID = row["resolved_id"] as? String, !tipID.isEmpty { resolved["id"] = tipID }
        resolved["title"] = "Bot Chat"
        return decodeSession(resolved)
    }

    func sessions(profile: String, onPage: (@MainActor ([HermesSession]) -> Void)? = nil) async throws -> [HermesSession] {
        var results: [HermesSession] = []
        var seen = Set<String>()
        var offset = 0
        for _ in 0..<200 {
            try Task.checkCancellation()
            let response = try await json("api/sessions", query: ["profile": profile, "order": "recent", "limit": "100", "offset": String(offset)])
            guard let rows = response["sessions"] as? [[String: Any]] else {
                throw HermesError.message("Hermes returned an unsupported session list.")
            }
            let page = rows.compactMap(Self.decodeSession)
            results.append(contentsOf: page.filter { seen.insert($0.id).inserted })
            onPage?(results.sorted { $0.lastActive > $1.lastActive })
            offset += 100 // Pins can be backfilled past the requested page size.
            let total = response["total"] as? Int
            if rows.isEmpty || (total.map { offset >= $0 } ?? (rows.count < 100)) {
                return results.sorted { $0.lastActive > $1.lastActive }
            }
        }
        throw HermesError.message("This profile has more than 20,000 sessions. Use the Hermes dashboard to narrow the list.")
    }

    static func messageDate(_ value: Any?) -> Date? {
        let seconds: Double?
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { seconds = number.doubleValue }
        else if let string = value as? String {
            if let number = Double(string) { seconds = number }
            else {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
            }
        } else { return nil }
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
    }

    func isDraft(profile: String, sessionID: String) -> Bool { draftSessions[profile]?[sessionID] != nil }

    struct MessagePage {
        let messages: [ChatMessage] // Always in reading order.
        let returned: Int          // Raw row count, including rows hidden from the chat.
        let hasOlder: Bool
        let offsetsFromNewest: [Int]
    }

    func messagePage(profile: String, sessionID: String, offset: Int = 0, limit: Int = 10) async throws -> MessagePage {
        if draftSessions[profile]?[sessionID] != nil { return MessagePage(messages: [], returned: 0, hasOlder: false, offsetsFromNewest: []) }
        try Task.checkCancellation()
        let response = try await json("api/sessions/\(Self.pathComponent(sessionID))/messages",
                                      query: ["profile": profile, "limit": String(limit), "offset": String(offset), "order": "latest"])
        guard let rows = response["messages"] as? [[String: Any]] else {
            throw HermesError.message("Hermes returned an unsupported message history.")
        }
        let visible = rows.enumerated().compactMap { index, row -> (ChatMessage, Int)? in
            let role = row["role"] as? String ?? ""
            guard ["user", "assistant"].contains(role), row["display_kind"] as? String != "hidden" else { return nil }
            let text = Self.contentText(row["content"])
            guard !text.isEmpty else { return nil }
            let id = row["id"].map { String(describing: $0) } ?? "\(sessionID)-\(offset + index)"
            let message = ChatMessage(id: id, role: role, text: text, timestamp: Self.messageDate(row["timestamp"]),
                                      delivery: role == "user" ? .delivered : nil)
            return (message, rows.count - 1 - index)
        }
        let pagination = response["pagination"] as? [String: Any]
        let returned = pagination?["returned"] as? Int ?? rows.count
        return MessagePage(messages: visible.map { $0.0 }, returned: returned, hasOlder: returned >= limit,
                           offsetsFromNewest: visible.map { $0.1 })
    }

    /// The API counts tool and hidden rows toward `limit`. Scan only as far as needed
    /// to obtain a page of visible chat messages, preserving the raw offset boundary.
    func visibleMessagePage(profile: String, sessionID: String, offset: Int = 0, visibleLimit: Int = 10) async throws -> MessagePage {
        var scanned = 0
        var candidates: [(message: ChatMessage, position: Int)] = []
        var more = true
        // Ask for one extra raw row so an exact-size conversation does not
        // display an "Earlier messages" control with nothing behind it.
        var rawLimit = max(11, visibleLimit + 1)
        while more && scanned < 100_000 {
            let limit = min(rawLimit, 100_000 - scanned)
            let page = try await messagePage(profile: profile, sessionID: sessionID, offset: offset + scanned, limit: limit)
            candidates += zip(page.messages, page.offsetsFromNewest).map {
                (message: $0.0, position: scanned + $0.1)
            }
            scanned += page.returned
            more = page.hasOlder
            // Keep scanning until we find one extra visible message, so a page
            // ending in hidden/tool rows does not advertise empty older history.
            if candidates.count > visibleLimit || page.returned == 0 { break }
            rawLimit = min(rawLimit * 4, 500)
        }
        if candidates.isEmpty && more {
            throw HermesError.message("This conversation has too many non-chat records to locate its messages.")
        }
        let selected = candidates.sorted { $0.position < $1.position }.prefix(visibleLimit)
        let consumed = candidates.count > visibleLimit ? (selected.last.map { $0.position + 1 } ?? scanned) : scanned
        let readingOrder = selected.sorted { $0.position > $1.position }
        return MessagePage(messages: readingOrder.map { $0.message },
                           returned: consumed, hasOlder: candidates.count > visibleLimit || more,
                           offsetsFromNewest: readingOrder.map { $0.position })
    }

    func messages(profile: String, sessionID: String) async throws -> [ChatMessage] {
        try await visibleMessagePage(profile: profile, sessionID: sessionID).messages
    }

    func createSession(profile: String) async throws -> HermesSession {
        guard turnContinuation == nil, !isExecutingCommand else { throw HermesError.message("Wait for the current action before starting a new session.") }
        try await ensureSocket()
        let response = try await rpc("session.create", ["profile": profile, "source": "desktop", "close_on_disconnect": false])
        guard let runtimeID = response["session_id"] as? String,
              let storedID = response["stored_session_id"] as? String else {
            throw HermesError.message("Hermes did not return the new session identity.")
        }
        clarifications.removeAll()
        runtimeSessionID = runtimeID
        remoteTurnRunning = false
        lastTurnFailure = nil
        storedSessionID = storedID
        sessionCoordinates[runtimeID] = (profile, storedID)
        selectedProfile = profile
        replayInteractions(response)
        draftSessions[profile, default: [:]][storedID] = runtimeID
        // Hermes stores new drafts on the first prompt, avoiding empty rows on launch.
        return HermesSession(id: storedID, title: "", preview: "", lastActive: Date(), messageCount: 0, source: "desktop")
    }

    func openSession(profile: String, sessionID: String) async throws {
        lastTurnFailure = nil
        guard turnContinuation == nil, !isExecutingCommand else { throw HermesError.message("Wait for the current action before opening another session.") }
        // A live draft already belongs to this socket. It has no persisted history
        // yet, so reopening it is a local selection rather than a database resume.
        if hasSocket, let draftRuntimeID = draftSessions[profile]?[sessionID], !draftRuntimeID.isEmpty {
            clarifications.removeAll()
            runtimeSessionID = draftRuntimeID
            storedSessionID = sessionID
            selectedProfile = profile
            remoteTurnRunning = false
            cachedCommandCatalog = nil
            cachedModelOptions = nil
            return
        }
        try await ensureSocket()
        let resumingBot = botSessionIDs[profile]?.contains(sessionID) == true
        let response = try await rpc("session.resume", ["profile": profile, "session_id": sessionID, "defer_history": true, "omit_messages": true])
        guard let runtimeID = response["session_id"] as? String else {
            throw HermesError.message("Hermes did not return the resumed session identity.")
        }
        clarifications.removeAll()
        runtimeSessionID = runtimeID
        remoteTurnRunning = response["running"] as? Bool ?? false
        if !remoteTurnRunning, let inflight = response["inflight"] as? [String: Any],
           inflight["status"] as? String == "error" {
            lastTurnFailure = "Hermes could not finish this request. Try again. If it fails again, restart Hermes on your computer when its current work is finished."
        }
        storedSessionID = response["session_key"] as? String ?? response["resumed"] as? String ?? sessionID
        if resumingBot, let id = storedSessionID { botSessionIDs[profile, default: []].insert(id) }
        selectedProfile = profile
        sessionCoordinates[runtimeID] = (profile, storedSessionID ?? sessionID)
        if draftSessions[profile]?[sessionID] != nil {
            draftSessions[profile]?[sessionID] = runtimeID
        }
        replayInteractions(response)
    }

    func send(text: String, photos: [DraftPhoto] = [], enrollment: CompanionEnrollment? = nil, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        if isBotConversation {
            try await sendBotReply(text: text, photos: photos, enrollment: enrollment, onEvent: onEvent)
        } else {
            try await sendSession(text: text, photos: photos, enrollment: enrollment, onEvent: onEvent)
        }
    }

    private func sendBotReply(text: String, photos: [DraftPhoto], enrollment: CompanionEnrollment?,
                              onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        guard turnContinuation == nil, !isPreparingSend, activeBotReply == nil, !isExecutingCommand,
              let profile = selectedProfile, let sessionID = storedSessionID else {
            throw HermesSendError.notSubmitted("Wait for the current action before sending another bot reply.")
        }
        guard photos.allSatisfy({ !$0.data.isEmpty && $0.data.count <= 25 * 1024 * 1024 }) else {
            throw HermesSendError.notSubmitted("Each attachment must be nonempty and no larger than 25 MB.")
        }
        guard text.count <= 200_000, photos.count <= 20 else {
            throw HermesSendError.notSubmitted("Send no more than 200,000 characters or 20 attachments in one bot reply.")
        }
        let id = UUID().uuidString.lowercased()
        activeBotReply = BotReply(id: id, enrollment: enrollment)
        isPreparingSend = true
        submissionPending = true
        preparationCancelled = false
        lastSentPhotoPaths = []
        defer {
            if activeBotReply?.id == id {
                activeBotReply = nil
                isPreparingSend = false
                submissionPending = false
                remoteTurnRunning = false
            }
        }
        var references: [[String: String]] = []
        do {
            let capabilities = try await companionAPI("capabilities")
            guard capabilities["bot_replies"] as? Int == 1 else {
                let message = capabilities["bot_replies"] == nil
                    ? "Update the companion on your Hermes computer to send Bot Chat replies."
                    : "Update Hermes on your computer to receive Bot Chat replies from the iPhone."
                throw HermesError.message(message)
            }
            for photo in photos {
                onEvent(.activity(photo.isFile == true ? "Uploading file…" : "Sending photo…"))
                let uploadID = UUID().uuidString.lowercased()
                var offset = 0
                while offset < photo.data.count {
                    try Task.checkCancellation()
                    guard !preparationCancelled else { throw CancellationError() }
                    let end = min(offset + 512 * 1024, photo.data.count)
                    let result = try await companionAPI("uploads", method: "PUT", body: [
                        "upload_id": uploadID, "filename": photo.filename, "offset": offset, "total": photo.data.count,
                        "content_base64": photo.data.subdata(in: offset..<end).base64EncodedString()
                    ], enrollment: enrollment)
                    guard result["offset"] as? Int == end, end < photo.data.count || result["complete"] as? Bool == true else {
                        throw HermesError.message("Hermes did not confirm the attachment upload.")
                    }
                    offset = end
                }
                references.append(["upload_id": uploadID, "filename": photo.filename])
            }
            guard !preparationCancelled else { throw CancellationError() }
        } catch {
            throw HermesSendError.notSubmitted(error.localizedDescription)
        }
        let path = "bot-replies/" + id
        let body: [String: Any] = ["profile": profile, "session_id": sessionID, "text": text, "attachments": references]
        var result: [String: Any]
        do {
            result = try await companionAPI(path, method: "PUT", body: body, enrollment: enrollment)
        } catch let submissionError {
            // Read the durable receipt after a lost acknowledgement. This never submits again.
            do { result = try await companionAPI(path, enrollment: enrollment) }
            catch let lookup as HermesHTTPError where lookup.statusCode == 404 {
                throw HermesSendError.notSubmitted(submissionError.localizedDescription)
            }
            catch { throw HermesSendError.outcomeUnknown("The bot reply could not be confirmed. Check the conversation before sending again.") }
        }
        guard activeBotReply?.id == id else { throw ConversationSuspended() }
        if result["route"] as? String == "unavailable" {
            throw HermesSendError.notSubmitted(result["message"] as? String ?? "This Bot Chat owner cannot receive iPhone replies.")
        }
        lastSentPhotoPaths = result["paths"] as? [String] ?? []
        if preparationCancelled {
            if result["route"] as? String == "session" { throw HermesSendError.notSubmitted("Bot reply sending was cancelled.") }
            if result["route"] as? String == "owner" {
                result = (try? await companionAPI(path, method: "DELETE", enrollment: enrollment)) ?? result
            }
        }
        if result["route"] as? String == "session" {
            // No owner exists. The normal gateway can write to this same canonical conversation.
            if let currentID = result["session_id"] as? String, currentID != storedSessionID {
                botSessionIDs[profile, default: []].insert(currentID)
                try await openSession(profile: profile, sessionID: currentID)
            }
            let paths = lastSentPhotoPaths
            let submitted = result["text"] as? String ?? text
            activeBotReply = nil
            isPreparingSend = false
            submissionPending = false
            try await sendSession(text: submitted, enrollment: enrollment, onEvent: onEvent)
            lastSentPhotoPaths = paths
            return
        }
        guard result["route"] as? String == "owner" else {
            throw HermesSendError.outcomeUnknown("Hermes returned an unknown bot reply state. Check the conversation before sending again.")
        }
        submissionPending = false
        isPreparingSend = false
        remoteTurnRunning = true
        onEvent(.accepted)
        let deadline = Date().addingTimeInterval(1800)
        while true {
            guard activeBotReply?.id == id else { throw ConversationSuspended() }
            switch result["status"] as? String {
            case "settled":
                if let currentID = result["session_id"] as? String {
                    storedSessionID = currentID
                    botSessionIDs[profile, default: []].insert(currentID)
                    if let runtimeSessionID { sessionCoordinates[runtimeSessionID] = (profile, currentID) }
                }
                onEvent(.finalText(result["reply"] as? String ?? ""))
                onEvent(.completed)
                return
            case "cancelled":
                throw HermesSendError.notSubmitted("The bot reply was cancelled before it started.")
            case "failed":
                throw HermesSendError.turnFailed(result["error"] as? String ?? "Hermes could not complete the bot reply.")
            case "ambiguous":
                throw HermesSendError.outcomeUnknown(result["error"] as? String ?? "Check the conversation before sending again.")
            case "queued": onEvent(.activity("Message queued"))
            case "claimed": onEvent(.activity("Waiting for the bot reply…"))
            case "preparing":
                throw HermesSendError.outcomeUnknown("The bot reply is not confirmed. Check the conversation before sending again.")
            default:
                throw HermesSendError.outcomeUnknown("Hermes returned an unknown bot reply state. Check the conversation before sending again.")
            }
            guard Date() < deadline else {
                throw HermesSendError.outcomeUnknown("The bot is still replying. Check the conversation before sending again.")
            }
            do {
                try await Task.sleep(for: .seconds(1))
                result = try await companionAPI(path, enrollment: enrollment)
            } catch {
                if activeBotReply?.id != id { throw ConversationSuspended() }
                throw HermesSendError.outcomeUnknown("The connection ended while the bot was replying. Check the conversation before sending again.")
            }
        }
    }

    private func sendSession(text: String, photos: [DraftPhoto] = [], enrollment: CompanionEnrollment? = nil, onEvent: @escaping @MainActor (ChatEvent) -> Void) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty else { return }
        guard turnContinuation == nil, !isPreparingSend, !isExecutingCommand else { throw HermesSendError.notSubmitted("A reply or control action is already in progress.") }
        guard !remoteTurnRunning else { throw HermesSendError.notSubmitted("This Hermes session is already running. Wait for it to finish before sending another message.") }
        guard let runtimeID = runtimeSessionID, hasSocket else {
            throw HermesSendError.notSubmitted("Reopen this session to reconnect before sending.")
        }
        let attachmentSession = [baseURL?.absoluteString ?? "", selectedProfile ?? "", storedSessionID ?? runtimeID]
            .joined(separator: "\u{0}")
        guard !uncertainAttachmentSessions.contains(attachmentSession) else {
            throw HermesSendError.notSubmitted("A previous photo upload has an uncertain state. Clear this session’s pending photos in Hermes, then restart the app before sending.")
        }
        guard photos.allSatisfy({ !$0.data.isEmpty && $0.data.count <= 25 * 1024 * 1024 }) else {
            throw HermesSendError.notSubmitted("Each attachment must be nonempty and no larger than 25 MB.")
        }
        isPreparingSend = true
        submissionPending = true
        preparationCancelled = false
        lastSentPhotoPaths = []
        defer { isPreparingSend = false; submissionPending = false }
        var stagedPaths: [String] = []
        var filePaths: [String] = []
        var uploadInFlight = false
        do {
            if photos.contains(where: { $0.isFile == true }) {
                let capabilities = try await companionAPI("capabilities")
                guard capabilities["file_upload"] as? Int == 1 else {
                    throw HermesError.message("Update the companion to upload files.")
                }
            }
            for photo in photos {
                if photo.isFile == true {
                    onEvent(.activity("Uploading file…"))
                    let uploadID = UUID().uuidString
                    var offset = 0
                    while offset < photo.data.count {
                        try Task.checkCancellation()
                        guard !preparationCancelled else { throw CancellationError() }
                        let end = min(offset + 512 * 1024, photo.data.count)
                        let result = try await companionAPI("uploads", method: "PUT", body: [
                            "upload_id": uploadID, "filename": photo.filename,
                            "offset": offset, "total": photo.data.count,
                            "content_base64": photo.data.subdata(in: offset..<end).base64EncodedString()
                        ], enrollment: enrollment)
                        guard result["offset"] as? Int == end else {
                            throw HermesError.message("Hermes did not confirm the file upload.")
                        }
                        if end == photo.data.count {
                            guard result["complete"] as? Bool == true,
                                  let path = result["path"] as? String, !path.isEmpty else {
                                throw HermesError.message("Hermes did not confirm the file upload.")
                            }
                            filePaths.append(path)
                        }
                        offset = end
                    }
                    continue
                }
                guard !preparationCancelled else { throw HermesSendError.notSubmitted("Photo sending was canceled.") }
                try Task.checkCancellation()
                onEvent(.activity("Sending photo…"))
                uploadInFlight = true
                let result = try await rpc("image.attach_bytes", ["session_id": runtimeID,
                    "content_base64": photo.data.base64EncodedString(), "filename": photo.filename])
                guard result["attached"] as? Bool == true,
                      let path = result["path"] as? String, !path.isEmpty else {
                    throw HermesError.message("Hermes did not confirm the photo upload.")
                }
                uploadInFlight = false
                stagedPaths.append(path)
            }
            guard !preparationCancelled else { throw HermesSendError.notSubmitted("Photo sending was canceled.") }
            try Task.checkCancellation()
        } catch {
            let detached = await detachPhotos(stagedPaths, runtimeID: runtimeID)
            if !detached || (uploadInFlight && !(error is RPCRejection)) {
                uncertainAttachmentSessions.insert(attachmentSession)
                throw HermesSendError.notSubmitted("Your message was not sent, but a photo may remain attached in Hermes. Clear this session’s pending photos in Hermes, then restart the app before sending.")
            }
            throw HermesSendError.notSubmitted(error.localizedDescription)
        }
        eventHandler = onEvent
        lastSentPhotoPaths = stagedPaths + filePaths
        let submittedText = ([text] + filePaths.map { "[User attached file: \($0)]" }).filter { !$0.isEmpty }.joined(separator: "\n")
        remoteTurnRunning = true
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    turnContinuation = continuation
                    Task { @MainActor in
                        do {
                            let draftProfile = selectedProfile
                            let draftID = storedSessionID
                            let draftRuntime = draftProfile.flatMap { draftSessions[$0]?[draftID ?? ""] }
                            if let draftProfile, let draftID { draftSessions[draftProfile]?[draftID] = nil }
                            let result: [String: Any]
                            do {
                                result = try await rpc("prompt.submit", ["session_id": runtimeID, "text": submittedText])
                            } catch let rejection as RPCRejection {
                                if let draftProfile, let draftID, let draftRuntime {
                                    draftSessions[draftProfile, default: [:]][draftID] = draftRuntime
                                }
                                throw rejection
                            }
                            submissionPending = false
                            onEvent(.accepted)
                            if result["status"] as? String == "queued" { eventHandler?(.activity("Message queued")) }
                        } catch let error as RPCRejection {
                            let detached = await detachPhotos(stagedPaths, runtimeID: runtimeID)
                            remoteTurnRunning = false
                            if !detached { uncertainAttachmentSessions.insert(attachmentSession) }
                            let cleanup = detached ? "" : " Clear this session’s pending photos in Hermes, then restart the app before sending."
                            finishTurn(error: HermesSendError.notSubmitted(error.localizedDescription + cleanup))
                        } catch {
                            // An acknowledgement may be lost after Hermes starts tools. Never retry.
                            closeSocket(error: error)
                        }
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.closeSocket(error: CancellationError()) }
            }
        } catch is ConversationSuspended {
            throw ConversationSuspended()
        } catch let error as HermesSendError {
            throw error
        } catch {
            if photos.contains(where: { $0.isFile != true }) { uncertainAttachmentSessions.insert(attachmentSession) }
            throw HermesSendError.outcomeUnknown(error.localizedDescription)
        }
    }

    private func detachPhotos(_ paths: [String], runtimeID: String) async -> Bool {
        var succeeded = true
        for path in paths {
            do { _ = try await rpc("image.detach", ["session_id": runtimeID, "path": path]) }
            catch { succeeded = false }
        }
        return succeeded
    }

    func stop() async throws {
        if isPreparingSend, turnContinuation == nil {
            preparationCancelled = true
            return
        }
        if let reply = activeBotReply {
            let result = try await companionAPI("bot-replies/" + reply.id, method: "DELETE", enrollment: reply.enrollment)
            if result["status"] as? String == "claimed" {
                throw HermesError.message("This bot reply has started. Stop it in Hermes on your computer.")
            }
            return
        }
        guard let runtimeID = runtimeSessionID else { return }
        _ = try await rpc("session.interrupt", ["session_id": runtimeID])
        // This only acknowledges the interrupt request. The in-flight prompt remains
        // owned until message.complete arrives, so its final frame cannot finish a new turn.
    }

    /// Discovery comes from this installation, so plugin and skill descriptions stay current.
    func commandCatalog() async throws -> HermesCommandCatalog {
        let params = try commandSessionParams()
        let sessionID = params["session_id"] as! String
        let response = try await rpc("commands.catalog", params)
        guard let pairs = response["pairs"] as? [[String]], runtimeSessionID == sessionID else {
            throw HermesCommandError.rejected("Hermes could not load commands for this session. Reopen it to try again.")
        }
        let metadata = response["commands"] as? [String: [String: Any]] ?? [:]
        let skills = response["skills"] as? [String: Any] ?? [:]
        var extensionNames = Set(skills.keys)
        for category in response["categories"] as? [[String: Any]] ?? [] {
            if ["User commands", "Plugin commands"].contains(category["name"] as? String ?? "") {
                for pair in category["pairs"] as? [[String]] ?? [] {
                    if let name = pair.first { extensionNames.insert(name) }
                }
            }
        }
        var seen = Set<String>()
        let usesGatewayProfile = verifiedGatewayProfile != nil && selectedProfile == verifiedGatewayProfile
        let commands = pairs.compactMap { pair -> HermesCommandSuggestion? in
            guard pair.count >= 2 else { return nil }
            let name = pair[0].lowercased()
            guard !isBotConversation || !["/new", "/title"].contains(name) else { return nil }
            let isExtension = extensionNames.contains(pair[0]) || metadata[pair[0]] == nil
            // Older gateways discover extensions in their launch profile, even when profile is
            // supplied. Do not execute that potentially different profile's custom commands.
            guard usesGatewayProfile || !isExtension,
                  usesGatewayProfile || !["/loop", "/moa", "/personality"].contains(name),
                  Self.commandIsSupported(name, desktop: metadata[pair[0]]?["desktop"] as? String),
                  seen.insert(name).inserted else { return nil }
            let description = Self.commandDescriptions[name] ?? pair[1]
            return HermesCommandSuggestion(text: name, display: name, description: description,
                kind: skills[pair[0]] == nil ? "command" : "skill",
                argumentMode: metadata[pair[0]]?["argument_mode"] as? String)
        }
        let warning = [response["warning"] as? String,
            usesGatewayProfile ? nil : "Some commands are unavailable because this Hermes version does not isolate them by profile."]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        let catalog = HermesCommandCatalog(commands: commands,
            aliases: response["canon"] as? [String: String] ?? [:], warning: warning.isEmpty ? nil : warning)
        cachedCommandCatalog = (sessionID, catalog)
        return catalog
    }

    func completeCommand(_ text: String) async throws -> [HermesCommandSuggestion] {
        guard text.hasPrefix("/"), !text.contains("\n") else { return [] }
        let params = try commandSessionParams()
        let sessionID = params["session_id"] as! String
        let catalog = try await currentCommandCatalog()
        let isCommandToken = !text.contains(where: \.isWhitespace)
        let typedCommand = catalog.canonicalName(for: text)
        if !isCommandToken, ["/new", "/save", "/status", "/usage", "/context", "/stop"].contains(typedCommand) { return [] }
        if text.lowercased().hasPrefix("/model ") {
            let result = try await modelOptions(params)
            guard runtimeSessionID == sessionID else { return [] }
            let query = String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces).lowercased()
            return (result["providers"] as? [[String: Any]] ?? []).flatMap { provider -> [HermesCommandSuggestion] in
                guard provider["authenticated"] as? Bool != false,
                      let slug = provider["slug"] as? String, !slug.isEmpty else { return [] }
                let label = provider["name"] as? String ?? slug
                return (provider["models"] as? [String] ?? []).compactMap { model in
                    let command = "/model \(model) --provider \(slug)"
                    guard query.isEmpty || model.lowercased().contains(query) || command.lowercased().hasPrefix(text.lowercased()) else { return nil }
                    return HermesCommandSuggestion(text: command, display: model,
                        description: label + (model == result["model"] as? String && slug == result["provider"] as? String ? " · Current model" : ""), argumentMode: "options")
                }
            }
        }
        // Completion is gateway-wide: its wire contract accepts only text. Keep
        // profile/session scoping in the catalog filter below, not in this request.
        let response: [String: Any]
        if companionTransport?.mobileProtocolVersion == 1 && companionTransport?.mobileFeatures["slash_completion"] as? Bool == false {
            response = [:]
        } else {
            do { response = try await rpc("complete.slash", ["text": text]) }
            catch let error as RPCRejection where [-32601, -32602, 4000].contains(error.code) {
                // Name completion remains useful when a backend changes its
                // optional autocomplete API. Mutations never use this fallback.
                response = [:]
            }
        }
        guard runtimeSessionID == sessionID else { return [] }
        let offset = response["replace_from"] as? Int ?? 1
        // The gateway offset counts Python Unicode code points, not UTF-16 units or Swift graphemes.
        let prefix = String(String.UnicodeScalarView(text.unicodeScalars.prefix(max(0, offset))))
        var seen = Set<String>()
        var suggestions = (response["items"] as? [[String: Any]] ?? []).compactMap { row -> HermesCommandSuggestion? in
            guard let replacement = row["text"] as? String, !replacement.isEmpty else { return nil }
            let rawInsertion = replacement.hasPrefix("/") ? replacement : prefix + replacement
            let canonical = catalog.canonicalName(for: rawInsertion)
            guard let command = catalog.commands.first(where: { $0.text == canonical }),
                  seen.insert(isCommandToken ? canonical : rawInsertion).inserted else { return nil }
            let insertion = isCommandToken ? canonical + (rawInsertion.hasSuffix(" ") ? " " : "") : rawInsertion
            let argument = insertion.split(maxSplits: 1, whereSeparator: \.isWhitespace).dropFirst().first.map(String.init)?.lowercased() ?? ""
            if canonical == "/reasoning", Self.reasoningDisplayArguments.contains(argument) || argument.hasPrefix("--") || argument.contains(where: \.isWhitespace) { return nil }
            if canonical == "/usage", !argument.isEmpty { return nil }
            if canonical == "/tools", !argument.isEmpty && argument != "list" { return nil }
            if canonical == "/compress", argument.contains("--preview") || argument.contains("--dry-run") { return nil }
            let description = row["meta"] as? String ?? ""
            return HermesCommandSuggestion(text: insertion, display: isCommandToken ? command.display : row["display"] as? String ?? insertion,
                description: isCommandToken || description.isEmpty ? command.description : description,
                kind: row["kind"] as? String ?? command.kind, argumentMode: command.argumentMode)
        }
        // Catalog entries are unbounded; complete.slash may cap its result before filtering out
        // terminal commands. Preserve all supported command choices when browsing or searching.
        if isCommandToken {
            let query = String(text.dropFirst()).lowercased()
            for command in catalog.commands where (query.isEmpty || command.text.contains(query) || command.description.localizedCaseInsensitiveContains(query)) {
                if !suggestions.contains(where: { catalog.canonicalName(for: $0.text) == command.text }) {
                    suggestions.append(command)
                }
            }
        }
        return suggestions
    }

    func executeCommand(_ command: String, confirmed: Bool = false) async throws -> HermesCommandResult {
        let params = try commandSessionParams()
        let sessionID = params["session_id"] as! String
        let catalog = try await currentCommandCatalog()
        guard runtimeSessionID == sessionID else { throw HermesCommandError.rejected("The active session changed. Try the command in its new session.") }
        guard !isExecutingCommand, !isPreparingSend else { throw HermesCommandError.rejected("Wait for the current action to finish.") }
        lastCommandNeedsHistoryRefresh = false
        lastCommandNeedsSessionRefresh = false
        isExecutingCommand = true
        defer { isExecutingCommand = false }
        do {
            return try await runCommand(command, confirmed: confirmed, catalog: catalog, params: params, depth: 0)
        } catch let error as HermesCommandError { throw error }
        catch let error as RPCRejection {
            // Worker / server failures can be reported after side effects, unlike validation
            // and busy refusals. Preserve that uncertainty instead of inviting a blind replay.
            if error.code >= 5000 || error.code == -32000 {
                throw HermesCommandError.outcomeUnknown("Hermes reported a command failure. Check its state before running the command again. \(error.message)")
            }
            throw HermesCommandError.rejected(error.message)
        }
        catch {
            // A timeout or lost socket can arrive after a control has changed server state.
            // Never fall back to another route or retry automatically in that case.
            throw HermesCommandError.outcomeUnknown("The command’s result is unknown. Check this session in Hermes before running it again. \(error.localizedDescription)")
        }
    }

    private func runCommand(_ command: String, confirmed: Bool, catalog: HermesCommandCatalog,
                            params: [String: Any], depth: Int) async throws -> HermesCommandResult {
        guard depth < 8 else { throw HermesCommandError.rejected("This command has too many alias redirects.") }
        let words = command.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let token = words.first, token.hasPrefix("/") else { throw HermesCommandError.rejected("Commands start with /.") }
        let name = catalog.canonicalName(for: String(token))
        if isBotConversation && ["/new", "/title"].contains(name) {
            throw HermesCommandError.rejected("Bot Chat keeps one conversation and its fixed title. Use /compress to reduce its context. Use Profiles to start a separate session.")
        }
        guard catalog.commands.contains(where: { $0.text == name }) else {
            throw HermesCommandError.rejected("\(token) is not available in this app. Type / to see this installation’s supported commands.")
        }
        let arg = words.count > 1 ? String(words[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if ["/usage", "/status", "/context"].contains(name), !arg.isEmpty {
            throw HermesCommandError.rejected("Use \(name) without arguments to inspect this session.")
        }
        if name == "/tools", !arg.isEmpty && arg != "list" {
            throw HermesCommandError.rejected("Use /tools to inspect this session’s available tools. Change tool configuration in Hermes.")
        }
        let isRead = ["/status", "/usage", "/context", "/help", "/tools"].contains(name) && arg.isEmpty
        guard name == "/stop" || name == "/model" || isRead || (turnContinuation == nil && !remoteTurnRunning) else {
            throw HermesCommandError.rejected("This session is busy. Stop its current reply before running \(name).")
        }
        var request = params
        switch name {
        case "/new":
            guard arg.isEmpty else { throw HermesCommandError.rejected("Use /new to start a session, then /title <name> to name it.") }
            return .newSession
        case "/stop":
            _ = try await rpc("session.interrupt", params)
            _ = try await rpc("process.stop", params)
            return .stopped
        case "/help":
            let matching = catalog.commands.filter { arg.isEmpty || $0.text.localizedCaseInsensitiveContains(arg) || $0.description.localizedCaseInsensitiveContains(arg) }
            return .output(matching.isEmpty ? "No commands match \(arg)." : matching.map { "\($0.display)\n\($0.description)" }.joined(separator: "\n\n"))
        case "/status":
            let result = try await rpc("session.status", params)
            return try await decodeCommandResult(result, command: command, catalog: catalog, params: params, depth: depth)
        case "/title":
            if !arg.isEmpty { request["title"] = arg }
            lastCommandNeedsSessionRefresh = !arg.isEmpty
            let result = try await rpc("session.title", request)
            return .output(arg.isEmpty ? "Session title: \(result["title"] as? String ?? "Untitled session")" : "Session renamed to \(result["title"] as? String ?? arg).")
        case "/model" where arg.isEmpty:
            let result = try await modelOptions(params)
            return .output("Current model: \(result["model"] as? String ?? "Unknown")\nProvider: \(result["provider"] as? String ?? "Unknown")\n\nType /model followed by a space to choose an available model.")
        case "/model":
            request["key"] = "model"
            request["value"] = arg
            request["confirm_expensive_model"] = confirmed
            let result = try await rpc("config.set", request)
            cachedModelOptions = nil
            if result["confirm_required"] as? Bool == true {
                return .confirmation(message: result["confirm_message"] as? String ?? result["warning"] as? String ?? "Confirm this model change?")
            }
            let value = result["value"] as? String ?? arg
            let output = result["deferred"] as? Bool == true ? "Model set to \(value) for the next reply." : "Model set to \(value)."
            return .output(Self.withWarning(output, result))
        case "/reasoning" where arg.isEmpty:
            return .output("Use /reasoning <level> to change this session’s reasoning effort. Type /reasoning followed by a space to see available levels.")
        case "/reasoning":
            guard !Self.reasoningDisplayArguments.contains(arg.lowercased()), !arg.hasPrefix("--"), !arg.contains(where: \.isWhitespace) else {
                throw HermesCommandError.rejected("Use /reasoning <effort> to set this session’s reasoning effort. Terminal reasoning display controls do not apply on iOS.")
            }
            request["key"] = "reasoning"
            request["value"] = arg
            request["scope"] = "session"
            let result = try await rpc("config.set", request)
            return .output("Reasoning effort set to \(result["value"] as? String ?? arg).")
        case "/compress":
            guard !arg.contains("--preview"), !arg.contains("--dry-run") else {
                throw HermesCommandError.rejected("Compression previews are not supported by this Hermes session API. Use /context to inspect context, or /compress to compress it.")
            }
            if !arg.isEmpty { request["focus_topic"] = arg }
            lastCommandNeedsHistoryRefresh = true
            lastCommandNeedsSessionRefresh = true
            let compressingBot = isBotConversation
            let result = try await rpc("session.compress", request, timeoutSeconds: 600)
            if let info = result["info"] as? [String: Any], let id = info["stored_session_id"] as? String, !id.isEmpty {
                storedSessionID = id
                if compressingBot, let profile = selectedProfile { botSessionIDs[profile, default: []].insert(id) }
            }
            if let summary = result["summary"] as? [String: Any] {
                return .output(["headline", "token_line", "note"].compactMap { summary[$0] as? String }.filter { !$0.isEmpty }.joined(separator: "\n"))
            }
            return .output(result["message"] as? String ?? "Conversation context compressed.")
        case "/save":
            guard arg.isEmpty else { throw HermesCommandError.rejected("Use /save to export this session as JSON on your Hermes host.") }
            let result = try await rpc("session.save", params)
            return .output("Saved transcript to \(result["file"] as? String ?? "your Hermes host").")
        default:
            if ["/undo", "/retry"].contains(name) {
                lastCommandNeedsHistoryRefresh = true
                lastCommandNeedsSessionRefresh = true
            }
            request["command"] = String(name.dropFirst()) + (arg.isEmpty ? "" : " \(arg)")
            let result: [String: Any]
            do { result = try await rpc("slash.exec", request) }
            catch let rejection as RPCRejection where rejection.code == 4018 &&
                (rejection.message.hasPrefix("skill command: use command.dispatch for /") ||
                 rejection.message.lowercased().hasPrefix("unknown command")) {
                var dispatch = params
                dispatch["name"] = String(name.dropFirst())
                dispatch["arg"] = arg
                result = try await rpc("command.dispatch", dispatch)
            }
            return try await decodeCommandResult(result, command: command, catalog: catalog, params: params, depth: depth)
        }
    }

    private func decodeCommandResult(_ result: [String: Any], command: String, catalog: HermesCommandCatalog,
                                     params: [String: Any], depth: Int) async throws -> HermesCommandResult {
        switch result["type"] as? String {
        case "alias":
            guard let target = result["target"] as? String, !target.isEmpty else { throw HermesCommandError.rejected("Hermes returned an empty command alias.") }
            let parts = command.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            let suffix = parts.count > 1 ? " " + parts[1] : ""
            return try await runCommand((target.hasPrefix("/") ? target : "/" + target) + suffix,
                confirmed: false, catalog: catalog, params: params, depth: depth + 1)
        case "skill", "send":
            guard let message = result["message"] as? String, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HermesCommandError.rejected("Hermes returned an empty command prompt.")
            }
            return .send(message: message, display: result["display"] as? String ?? command, notice: result["notice"] as? String)
        case "prefill":
            guard let message = result["message"] as? String else { throw HermesCommandError.rejected("Hermes returned an invalid undo result.") }
            return .prefill(message: message, notice: result["notice"] as? String ?? "Edit and resend this message.")
        case nil, "exec", "plugin":
            if result["confirm_required"] as? Bool == true || result["status"] as? String == "confirm_required" {
                throw HermesCommandError.rejected(result["message"] as? String ?? "Complete this confirmation in Hermes.")
            }
            guard let output = result["output"] as? String else { throw HermesCommandError.outcomeUnknown("Hermes returned an unsupported command response. Check its result before repeating the command.") }
            return .output(Self.withWarning(output.isEmpty ? "Command completed." : output, result))
        default:
            throw HermesCommandError.outcomeUnknown("Hermes returned an unsupported command action. Check the session before repeating the command.")
        }
    }

    private func commandSessionParams() throws -> [String: Any] {
        guard let runtimeID = runtimeSessionID, let profile = selectedProfile, hasSocket else {
            throw HermesCommandError.rejected("Reopen this session to reconnect before using commands.")
        }
        return ["session_id": runtimeID, "profile": profile]
    }

    private func currentCommandCatalog() async throws -> HermesCommandCatalog {
        if let cache = cachedCommandCatalog, cache.sessionID == runtimeSessionID { return cache.catalog }
        return try await commandCatalog()
    }

    private func modelOptions(_ params: [String: Any]) async throws -> [String: Any] {
        let sessionID = params["session_id"] as! String
        if let cache = cachedModelOptions, cache.sessionID == sessionID { return cache.result }
        let result = try await rpc("model.options", params)
        if runtimeSessionID == sessionID { cachedModelOptions = (sessionID, result) }
        return result
    }

    private static func withWarning(_ output: String, _ result: [String: Any]) -> String {
        guard let warning = result["warning"] as? String, !warning.isEmpty else { return output }
        return output + "\n\n" + warning
    }

    private static let commandDescriptions: [String: String] = [
        "/new": "Start a new session with this profile", "/stop": "Stop this reply and Hermes background processes",
        "/help": "Show available commands and explanations", "/title": "View or change this session’s title [name]",
        "/model": "View or change this session’s model [model]", "/reasoning": "Set this session’s reasoning effort [level]",
        "/save": "Export this conversation as JSON on your Hermes host", "/usage": "Show token usage for this session",
        "/tools": "List tools available to this session", "/compress": "Compress conversation context [focus topic | here N | --keep N]"
    ]

    private static let reasoningDisplayArguments: Set<String> = ["show", "hide", "on", "off", "full", "all", "clamp", "collapse", "short", "--global"]

    private static func commandIsSupported(_ name: String, desktop: String?) -> Bool {
        if ["/new", "/stop", "/help", "/status", "/usage", "/model", "/reasoning", "/title", "/compress", "/save"].contains(name) { return true }
        if let desktop, !desktop.isEmpty { return false }
        // These depend on a terminal/editor, desktop panel, or lifecycle/stream handling
        // which this client does not own. Never route them through an unrelated slash worker.
        let unsupported: Set<String> = ["/branch", "/fork", "/profile", "/resume", "/sessions", "/switch", "/prompt", "/compose",
            "/handoff", "/skin", "/wake", "/browser", "/journey", "/learning", "/memory-graph", "/pet", "/hatch", "/generate-pet",
            "/btw", "/voice", "/yolo", "/approvals", "/export", "/import", "/rollback", "/worktree", "/review",
            "/bg", "/heartbeat", "/refine", "/subgoal", "/codex-runtime", "/battery", "/timestamps", "/focus", "/palette", "/subscription", "/topup", "/debug",
            "/busy", "/clear", "/config", "/copy", "/cron", "/density", "/details", "/exit", "/footer", "/gateway",
            "/history", "/image", "/indicator", "/logs", "/mouse", "/paste", "/platforms", "/plugins", "/quit", "/redraw",
            "/reload", "/restart", "/sb", "/set-home", "/sethome", "/snap", "/snapshot", "/statusbar", "/toolsets", "/update", "/verbose"]
        return !unsupported.contains(name)
    }

    func respondToApproval(requestID: String, choice: String) async throws {
        guard let runtimeID = runtimeSessionID else { throw HermesError.message("Reopen the session before responding.") }
        let response = try await rpc("approval.respond", ["session_id": runtimeID, "request_id": requestID, "choice": choice, "all": false])
        guard response["resolved"] as? Bool == true else { throw HermesError.message("This approval is no longer pending.") }
    }

    func respondToClarification(requestID: String, answer: String) async throws {
        guard let clarification = clarifications.first, clarification.clientID == requestID,
              let runtimeID = runtimeSessionID else {
            throw HermesError.message("This question is no longer pending.")
        }
        var params: [String: Any] = ["session_id": runtimeID, "request_id": clarification.serverID, "answer": answer]
        if let questionID = clarification.questionID { params["question_id"] = questionID }
        let result = try await rpc("clarify.respond", params)
        if result["status"] as? String == "expired" {
            expireClarifications(serverID: clarification.serverID)
            throw HermesError.message("This question expired before the answer reached Hermes.")
        }
        guard result["status"] as? String == "ok" else {
            throw HermesError.message("Hermes did not confirm your answer. Try again after checking the connection.")
        }
        clarifications.removeAll { $0.clientID == requestID }
        // The caller clears only the answered clientID: this next event may replace its card
        // before the async reply returns. Batch replies must retain their server question_id.
        presentNextClarification()
    }

    /// Release only the local wait. Hermes keeps executing on the same socket.
    func detachConversation() async {
        // Do not switch underneath photo staging or an unacknowledged submit.
        while submissionPending {
            try? await Task.sleep(for: .milliseconds(30))
            if Task.isCancelled { return }
        }
        finishTurn(error: ConversationSuspended())
        activeBotReply = nil
        runtimeSessionID = nil
        remoteTurnRunning = false
        clarifications.removeAll()
        while isPreparingSend {
            try? await Task.sleep(for: .milliseconds(10))
            if Task.isCancelled { return }
        }
    }

    func suspendForBackground() {
        activeBotReply = nil
        isPreparingSend = false
        submissionPending = false
        closeSocket(error: ConversationSuspended())
    }

    func disconnect() {
        activeBotReply = nil
        isPreparingSend = false
        submissionPending = false
        closeSocket(error: HermesError.message("Disconnected from Hermes."))
        companionTransport = nil
        http.configuration.httpCookieStorage?.cookies?.forEach { http.configuration.httpCookieStorage?.deleteCookie($0) }
        baseURL = nil
        bearerToken = ""
        localToken = ""
        selectedProfile = nil
        verifiedGatewayProfile = nil
        storedSessionID = nil
        avatarCache = [:]
        draftSessions = [:]
        botSessionIDs = [:]
        sessionCoordinates = [:]
    }

    private func ensureSocket() async throws {
        if !hasSocket { try await openSocket() }
    }

    private func openSocket() async throws {
        if let openingSocket { try await openingSocket.task.value; return }
        let id = UUID()
        let task = Task { @MainActor in try await self.openSocketImpl() }
        openingSocket = (id, task)
        defer { if openingSocket?.id == id { openingSocket = nil } }
        try await task.value
    }

    private func openSocketImpl() async throws {
        if let transport = companionTransport {
            transport.onRPC = { [weak self] in self?.receive($0) }
            transport.onDisconnect = { [weak self] in self?.closeSocket(error: $0) }
            try await transport.connect()
            try await transport.negotiateMobileProtocol()
            _ = try await rpc("gateway.ping", [:])
            heartbeatTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(15))
                        guard let self, self.companionTransport === transport, transport.isConnected else { return }
                        _ = try await self.rpc("gateway.ping", [:])
                    } catch {
                        guard !Task.isCancelled, let self, self.companionTransport === transport else { return }
                        self.closeSocket(error: HermesError.message("Hermes stopped responding. Reopen the conversation to reconnect."))
                        return
                    }
                }
            }
            return
        }
        var query: [String: String]
        if requiresAuth {
            let ticket = try await json("api/auth/ws-ticket", method: "POST", body: [:])
            guard let value = ticket["ticket"] as? String, !value.isEmpty else {
                throw HermesError.message("Hermes could not authorize the chat connection.")
            }
            query = ["ticket": value]
        } else { query = ["token": localToken] }
        let url = try endpoint("api/ws", query: query)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.scheme = url.scheme == "https" ? "wss" : "ws"
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        let task = http.webSocketTask(with: request)
        task.maximumMessageSize = 4_000_000
        socket = task
        task.resume()
        receiveTask = Task { @MainActor [weak self] in
            do {
                while !Task.isCancelled {
                    let frame = try await task.receive()
                    guard let self, self.socket === task else { return }
                    let data: Data
                    switch frame {
                    case .string(let string): data = Data(string.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: continue
                    }
                    self.receive(data)
                }
            } catch {
                guard let self, self.socket === task else { return }
                self.closeSocket(error: HermesError.message("The Hermes connection was interrupted. Reopen the session to reconnect; your messages remain on the server."))
            }
        }
        _ = try await rpc("gateway.ping", [:])
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    guard let self, self.socket === task else { return }
                    _ = try await self.rpc("gateway.ping", [:])
                } catch {
                    guard !Task.isCancelled, let self, self.socket === task else { return }
                    self.closeSocket(error: HermesError.message("Hermes stopped responding. Reopen the session to reconnect."))
                    return
                }
            }
        }
    }

    private func rpc(_ method: String, _ params: [String: Any], timeoutSeconds: UInt64 = 60) async throws -> [String: Any] {
        guard hasSocket else { throw HermesError.message("The Hermes chat connection is closed.") }
        let task = socket
        let relay = companionTransport
        let generation = socketGeneration
        let id = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        return try await withTaskCancellationHandler {
          try Task.checkCancellation()
          return try await withCheckedThrowingContinuation { continuation in
            guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
            let timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000) } catch { return }
                guard let request = self?.pending.removeValue(forKey: id) else { return }
                request.writer?.cancel()
                request.continuation.resume(throwing: HermesError.message("Hermes took too long to respond to \(method). Check the session before sending again."))
            }
            pending[id] = PendingRPC(continuation: continuation, timeout: timeout)
            let writer = Task { @MainActor [weak self] in
                do {
                    try Task.checkCancellation()
                    guard let self, self.pending[id] != nil, self.socketGeneration == generation else { return }
                    if let relay { try await relay.sendRPC(data) }
                    else if let task { try await task.send(.string(String(decoding: data, as: UTF8.self))) }
                    else { throw HermesError.message("The Hermes chat connection is closed.") }
                }
                catch {
                    guard let request = self?.pending.removeValue(forKey: id) else { return }
                    request.timeout.cancel()
                    request.continuation.resume(throwing: HermesError.message("Could not send to Hermes. Reopen the session to reconnect."))
                }
            }
            pending[id]?.writer = writer
          }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelRPC(id) }
        }
    }

    private func cancelRPC(_ id: String) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.writer?.cancel()
        request.continuation.resume(throwing: CancellationError())
    }

    private func receive(_ data: Data) {
        guard let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if frame["method"] as? String == "jr.backend.disconnected" {
            closeSocket(error: HermesError.message("Hermes restarted or its connection changed. Reopen the conversation and check its history before repeating an action."))
            return
        }
        if let id = frame["id"] as? String, let request = pending.removeValue(forKey: id) {
            request.timeout.cancel()
            if let error = frame["error"] as? [String: Any] {
                request.continuation.resume(throwing: RPCRejection(code: error["code"] as? Int ?? -32000, message: error["message"] as? String ?? "Hermes rejected the request."))
            } else { request.continuation.resume(returning: frame["result"] as? [String: Any] ?? [:]) }
            return
        }
        guard frame["method"] as? String == "event", let params = frame["params"] as? [String: Any],
              let eventSession = params["session_id"] as? String,
              let type = params["type"] as? String else { return }
        let payload = params["payload"] as? [String: Any] ?? [:]
        if let coordinate = sessionCoordinates[eventSession] {
            onSessionEvent?(coordinate.profile, coordinate.stored, type, payload)
        }
        guard eventSession == runtimeSessionID else { return }
        switch type {
        case "message.delta": eventHandler?(.delta(payload["text"] as? String ?? ""))
        case "message.complete":
            remoteTurnRunning = false
            if payload["status"] as? String == "error" {
                finishTurn(error: HermesSendError.turnFailed(payload["text"] as? String ?? "Hermes could not complete this turn. Try again."))
            } else {
                if payload["status"] as? String != "interrupted", let text = payload["text"] as? String { eventHandler?(.finalText(text)) }
                finishTurn()
            }
        case "message.start": eventHandler?(.activity("Thinking"))
        case "tool.start", "tool.generating": eventHandler?(.activity("Using \(payload["name"] as? String ?? "a tool")"))
        case "tool.complete": eventHandler?(.activity("Thinking"))
        case "status.update": if let text = payload["text"] as? String { (eventHandler ?? onInteraction)?(.activity(text)) }
        case "session.info": if let id = payload["stored_session_id"] as? String, !id.isEmpty { storedSessionID = id }
        case "approval.request":
            guard let id = payload["request_id"] as? String else { return }
            let choices = payload["choices"] as? [String] ?? ["once", "deny"]
            (eventHandler ?? onInteraction)?(.approval(requestID: id, command: payload["command"] as? String ?? "Hermes requests approval", choices: choices))
            if let runtimeID = runtimeSessionID {
                Task { _ = try? await rpc("approval.received", ["session_id": runtimeID, "request_id": id]) }
            }
        case "clarify.request":
            enqueueClarifications(payload)
        case "clarify.expire":
            if let requestID = payload["request_id"] as? String { expireClarifications(serverID: requestID) }
        case "approval.expire":
            if let requestID = payload["request_id"] as? String { (eventHandler ?? onInteraction)?(.approvalExpired(requestID: requestID)) }
        case "sudo.request", "secret.request":
            (eventHandler ?? onInteraction)?(.activity("Hermes needs input in its dashboard. Open the dashboard to respond."))
        case "error": closeSocket(error: HermesError.message(payload["message"] as? String ?? "Hermes encountered an error."))
        default: break
        }
    }

    private func finishTurn(error: Error? = nil) {
        guard let continuation = turnContinuation else { return }
        turnContinuation = nil
        clarifications = []
        if let error {
            if !(error is ConversationSuspended) { eventHandler?(.failure(error.localizedDescription)) }
            continuation.resume(throwing: error)
        } else {
            eventHandler?(.completed)
            continuation.resume()
        }
        eventHandler = nil
    }

    private func closeSocket(error: Error) {
        socketGeneration = UUID()
        openingSocket?.task.cancel()
        openingSocket = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        companionTransport?.close()
        runtimeSessionID = nil
        // Keep knowledge of empty drafts across a temporary disconnect, but their
        // runtime must be rebound through Hermes before reuse on another socket.
        draftSessions = draftSessions.mapValues { $0.mapValues { _ in "" } }
        cachedCommandCatalog = nil
        cachedModelOptions = nil
        remoteTurnRunning = false
        clarifications = []
        let outstanding = pending.values
        pending = [:]
        for request in outstanding {
            request.timeout.cancel()
            request.writer?.cancel()
            request.continuation.resume(throwing: error)
        }
        finishTurn(error: error)
    }

    private func enqueueClarifications(_ payload: [String: Any]) {
        guard let serverID = payload["request_id"] as? String, !serverID.isEmpty,
              !clarifications.contains(where: { $0.serverID == serverID }) else { return }
        let wasEmpty = clarifications.isEmpty
        let questions = payload["questions"] as? [[String: Any]]
        let rows = (questions?.isEmpty == false) ? questions! : [payload]
        let priorAnswers = payload["answers"] as? [String: Any] ?? [:]
        for row in rows {
            guard var question = row["question"] as? String, !question.isEmpty else { continue }
            let questionID = questions?.isEmpty == false ? row["qid"] as? String : nil
            // A batch without qid cannot be answered safely: a reply lacking question_id
            // would terminate the entire request instead of answering this question.
            if questions?.isEmpty == false && questionID == nil { continue }
            if let questionID, priorAnswers[questionID] != nil { continue }
            let choices = (row["choices"] as? [String] ?? []).filter { !$0.isEmpty }
            if row["multi_select"] as? Bool == true && !choices.isEmpty {
                question += "\nYou can choose several; separate multiple answers with commas."
            }
            let clientID = questionID.map { "\(serverID)/\($0)" } ?? serverID
            clarifications.append(ClarificationRequest(clientID: clientID, serverID: serverID, questionID: questionID,
                                                      question: question, choices: choices))
        }
        if wasEmpty { presentNextClarification() }
    }

    private func presentNextClarification() {
        guard let question = clarifications.first else { return }
        (eventHandler ?? onInteraction)?(.clarification(requestID: question.clientID, question: question.question, choices: question.choices))
    }

    private func replayInteractions(_ response: [String: Any]) {
        for frame in response["pending_interactions"] as? [[String: Any]] ?? [] {
            if let data = try? JSONSerialization.data(withJSONObject: frame) { receive(data) }
        }
    }

    private func expireClarifications(serverID: String) {
        let expired = clarifications.filter { $0.serverID == serverID }
        clarifications.removeAll { $0.serverID == serverID }
        for question in expired { (eventHandler ?? onInteraction)?(.clarificationExpired(requestID: question.clientID)) }
        presentNextClarification()
    }

    private func json(_ path: String, method: String = "GET", query: [String: String] = [:], body: [String: Any]? = nil, authenticated: Bool = true) async throws -> [String: Any] {
        let (data, _) = try await request(path, method: method, query: query, body: body, authenticated: authenticated)
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HermesError.message("Hermes returned an unexpected response. Check that this is its dashboard address.")
        }
        return value
    }

    private func request(_ path: String, method: String = "GET", query: [String: String] = [:], body: [String: Any]? = nil, authenticated: Bool = true,
                         headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        if let relay = companionTransport {
            if !relay.isConnected { try await ensureSocket() }
            let (data, status) = try await relay.request(path: path, method: method, query: query, body: body)
            guard (200..<300).contains(status) else {
                let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
                if status == 404 { throw HermesHTTPError(statusCode: status, message: detail ?? "The companion returned HTTP 404.") }
                throw HermesError.message(detail ?? "The companion returned HTTP \(status).")
            }
            let response = HTTPURLResponse(url: try endpoint(path, query: query), statusCode: status, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
        var request = URLRequest(url: try endpoint(path, query: query))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if authenticated {
            if !bearerToken.isEmpty { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
            else if !localToken.isEmpty { request.setValue(localToken, forHTTPHeaderField: "X-Hermes-Session-Token") }
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, rawResponse) = try await http.data(for: request)
        guard let response = rawResponse as? HTTPURLResponse else { throw HermesError.message("Invalid server response.") }
        guard (200..<300).contains(response.statusCode) else {
            switch response.statusCode {
            case 301...399: throw HermesError.message("The server redirected this request. Enter the final dashboard address directly.")
            case 401, 403: throw HermesError.message("Hermes rejected these credentials. Use dashboard credentials; API_SERVER_KEY belongs to a different service.")
            case 404: throw HermesHTTPError(statusCode: 404, message: "This Hermes dashboard does not provide the requested feature. Check the address and update Hermes if needed.")
            case 429: throw HermesError.message("Hermes is receiving too many requests. Try again shortly.")
            default: throw HermesError.message("Hermes returned HTTP \(response.statusCode). Check that the dashboard is running.")
            }
        }
        return (data, response)
    }

    private func endpoint(_ path: String, query: [String: String] = [:]) throws -> URL {
        guard let baseURL, var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw HermesError.message("Connect to Hermes first.")
        }
        let prefix = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + ([prefix, path].filter { !$0.isEmpty }.joined(separator: "/"))
        if path.isEmpty && !components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath += "/" }
        components.queryItems = query.isEmpty ? nil : query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw HermesError.message("Invalid Hermes address.") }
        return url
    }

    static func validatedURL(_ address: String) throws -> URL {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              let url = components.url else {
            throw HermesError.message("Enter a full dashboard address, such as https://hermes.example.com or http://192.168.1.10:9119.")
        }
        if scheme == "http" && !isPrivateHost(host) {
            throw HermesError.message("Use HTTPS for hosted Hermes. HTTP is supported only for local or private network addresses.")
        }
        return url
    }

    private static func isLoopback(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1"].contains(host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
    }

    private static func isPrivateHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if isLoopback(host) || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(part)
        }
        if parts.count == 4 && octets.count == 4 && octets.allSatisfy({ (0...255).contains($0) }) {
            return octets[0] == 10
                || (octets[0] == 100 && (64...127).contains(octets[1])) // Tailscale / shared-address space
                || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168)
                || (octets[0] == 169 && octets[1] == 254)
        }
        return host.contains(":") && (host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:"))
    }

    private static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
    }

    private static func decodeSession(_ row: [String: Any]) -> HermesSession? {
        guard let id = row["id"] as? String, !id.isEmpty else { return nil }
        let timestamp = (row["last_active"] as? NSNumber)?.doubleValue ?? (row["last_activity_at"] as? NSNumber)?.doubleValue ?? (row["started_at"] as? NSNumber)?.doubleValue ?? 0
        return HermesSession(id: id, title: row["title"] as? String ?? "", preview: row["preview"] as? String ?? "",
                             lastActive: Date(timeIntervalSince1970: timestamp), messageCount: row["message_count"] as? Int ?? 0,
                             source: row["source"] as? String ?? "")
    }

    private static func contentText(_ content: Any?) -> String {
        if let string = content as? String { return string }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { block in
            if let text = block["text"] as? String { return text }
            if ["image", "image_url", "input_image"].contains(block["type"] as? String ?? "") { return "[Image]" }
            return nil
        }.joined(separator: "\n")
    }
}

/// Authentication stays on the exact URL the user supplied, including WebSocket upgrades.
private final class HermesRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
