import Foundation

enum CompanionConnectionFailure: LocalizedError, Equatable {
    case pairingRequired
    case unavailable, offline, serviceUnavailable

    static func handshakeFailure(statusCode: Int?, underlying: Error? = nil) -> Self {
        switch statusCode {
        case 401, 403, 404, 410: return .pairingRequired
        case 429: return .serviceUnavailable
        case let code? where (500...599).contains(code): return .serviceUnavailable
        default:
            if (underlying as? URLError)?.code == .notConnectedToInternet { return .offline }
            return .unavailable
        }
    }

    var errorDescription: String? {
        switch self {
        case .pairingRequired: return "Pair with Hermes using a new code."
        case .unavailable: return "The connection to Hermes could not be completed. Check that Hermes and its companion are running, then try again."
        case .offline: return "This iPhone is offline. Check your internet connection and try again."
        case .serviceUnavailable: return "The connection service is temporarily unavailable. Please try again shortly."
        }
    }
}

/// A new secure channel is established for every socket. Application requests are never replayed.
@MainActor
final class CompanionTransport {
    private struct PendingHTTP {
        let continuation: CheckedContinuation<(Data, Int), Error>
        let timeout: Task<Void, Never>
        var writer: Task<Void, Never>?
    }
    private let connection: CompanionConnection
    private let credentials: CompanionCredentials
    private let redirectGuard = CompanionRedirectGuard()
    private var session: URLSession!
    private var socket: URLSessionWebSocketTask?
    private var secure: CompanionSecureChannel?
    private var reader: Task<Void, Never>?
    private var outgoing: Task<Void, Error>?
    private var pending: [String: PendingHTTP] = [:]
    var onRPC: ((Data) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var isConnected: Bool { secure != nil && socket != nil }
    private(set) var mobileProtocolVersion: Int?
    private(set) var mobileFeatures: [String: Any] = [:]
    private var capabilityCacheKey: String {
        "jr.mobile.v1.\(connection.installationID).\(connection.hostPublicKey)"
    }

    init(connection: CompanionConnection, credentials: CompanionCredentials) {
        self.connection = connection
        self.credentials = credentials
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 360
        session = URLSession(configuration: config, delegate: redirectGuard, delegateQueue: nil)
    }

    func connect() async throws {
        close()
        let base = try CompanionInvitation.validatedRelayURL(connection.relayURL)
        guard UUID(uuidString: connection.installationID) != nil, UUID(uuidString: connection.deviceID) != nil,
              let hostKey = Data(companionBase64: connection.hostPublicKey), hostKey.count == 32 else {
            throw CompanionConnectionFailure.pairingRequired
        }
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        parts.scheme = base.scheme == "https" ? "wss" : "ws"
        parts.path = "/v1/installations/\(connection.installationID)/devices/\(connection.deviceID)/connect"
        var request = URLRequest(url: parts.url!)
        request.setValue("Bearer \(credentials.deviceToken)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 65536
        socket = task
        task.resume()
        let timeoutSeconds = credentials.pairingSecret == nil ? 12 : 180
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            if !Task.isCancelled { task.cancel(with: .goingAway, reason: nil) }
        }
        defer { timeout.cancel() }
        do {
            let handshake = try CompanionClientHandshake(hostPublicKey: hostKey, devicePrivateKey: credentials.privateKey)
            try await task.send(.data(try handshake.makeHello()))
            let challenge = try await Self.readBinary(task)
            var auth: [String: Any] = ["device_id": connection.deviceID, "device_name": "Hermes Jr. iPhone"]
            if let secret = credentials.pairingSecret { auth["pairing_secret"] = secret }
            let response = try handshake.receiveChallenge(challenge, authentication: JSONSerialization.data(withJSONObject: auth))
            try await task.send(.data(response))
            let channel = try handshake.receiveReady(try await Self.readBinary(task))
            guard socket === task else { throw CancellationError() }
            secure = channel
            reader = Task { @MainActor [weak self] in
                do {
                    while !Task.isCancelled {
                        let record = try await Self.readBinary(task)
                        guard let self, self.socket === task, let secure = self.secure else { return }
                        if let data = try secure.receive(record) { try self.receive(data) }
                    }
                } catch {
                    guard let self, self.socket === task else { return }
                    self.fail(HermesError.message("The encrypted connection was interrupted. Reopen the conversation to reconnect; check its history before repeating an action."))
                }
            }
        } catch {
            let status = (task.response as? HTTPURLResponse)?.statusCode
            if socket === task { close() }
            throw CompanionConnectionFailure.handshakeFailure(statusCode: status, underlying: error)
        }
    }

    /// Capability data is scoped to the pinned host and refreshed on every connection.
    /// Only an explicit missing endpoint opts into an older companion's legacy API.
    func negotiateMobileProtocol() async throws {
        let cache = UserDefaults.standard.dictionary(forKey: capabilityCacheKey)
        var query = ["protocol": "1"]
        if let revision = cache?["revision"] as? String { query["known_revision"] = revision }
        let (data, status) = try await request(path: "api/plugins/hermes-jr/v1/mobile/capabilities",
                                             method: "GET", query: query, body: nil)
        if status == 404 { return }
        guard status == 200,
              let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              response["protocol"] as? Int == 1,
              let revision = response["revision"] as? String, !revision.isEmpty,
              let unchanged = response["unchanged"] as? Bool else {
            throw HermesError.message("The companion and app could not agree on a mobile protocol. Check for a companion update.")
        }
        let features = unchanged && revision == cache?["revision"] as? String
            ? cache?["features"] as? [String: Any] : response["features"] as? [String: Any]
        guard let features, features["chat"] as? Bool == true, features["history"] as? Bool == true else {
            UserDefaults.standard.removeObject(forKey: capabilityCacheKey)
            throw HermesError.message("The companion cannot provide this app's required chat features. Check for a companion update, then reconnect.")
        }
        mobileFeatures = features
        mobileProtocolVersion = 1
        UserDefaults.standard.set(["revision": revision, "features": features], forKey: capabilityCacheKey)
    }

    func sendRPC(_ body: Data) async throws {
        guard var object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw HermesError.message("Invalid mobile request.")
        }
        if mobileProtocolVersion == 1, let method = object["method"] as? String {
            let feature: String? = switch method {
            case "image.attach_bytes", "image.detach": "images"
            case "commands.catalog": "command_catalog"
            case "complete.slash": "slash_completion"
            case "approval.received", "approval.respond": "approval"
            case "clarify.respond": "clarification"
            default: nil
            }
            if let feature, mobileFeatures[feature] as? Bool != true {
                throw HermesError.message("This feature is unavailable on this companion. Check for a companion update.")
            }
            object["method"] = "jr.v1." + method
        }
        try await send(["type": "rpc", "body": object])
    }

    func request(path: String, method: String, query: [String: String], body: [String: Any]?) async throws -> (Data, Int) {
        guard isConnected else { throw HermesError.message("Reconnect to the companion before continuing.") }
        let id = UUID().uuidString
        var routedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if mobileProtocolVersion == 1 && (routedPath == "api/profiles" || routedPath == "api/sessions" || routedPath.hasPrefix("api/sessions/")) {
            routedPath = "api/plugins/hermes-jr/v1/mobile/" + routedPath
        }
        var message: [String: Any] = ["type": "http", "id": id, "path": "/" + routedPath, "method": method, "query": query]
        if let body { message["body"] = body }
        return try await withTaskCancellationHandler {
          try Task.checkCancellation()
          return try await withCheckedThrowingContinuation { continuation in
            guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
            let timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let request = self?.pending.removeValue(forKey: id) else { return }
                request.writer?.cancel()
                request.continuation.resume(throwing: HermesError.message("The companion request timed out. Check the result before trying again."))
            }
            pending[id] = PendingHTTP(continuation: continuation, timeout: timeout)
            let writer = Task { @MainActor [weak self] in
                do {
                    guard let self, self.pending[id] != nil else { return }
                    try Task.checkCancellation()
                    try await self.send(message)
                }
                catch {
                    guard let pending = self?.pending.removeValue(forKey: id) else { return }
                    pending.timeout.cancel()
                    pending.continuation.resume(throwing: error)
                }
            }
            pending[id]?.writer = writer
          }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelRequest(id) }
        }
    }

    private func cancelRequest(_ id: String) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.writer?.cancel()
        request.continuation.resume(throwing: CancellationError())
    }

    private func send(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let task = socket, let channel = secure else { throw HermesError.message("The companion connection is closed.") }
        let predecessor = outgoing
        let operation = Task { @MainActor [weak self] in
            // A canceled queued write must not poison subsequent writes. Any failure after
            // encryption starts closes the pipe inside that operation before it completes.
            if let predecessor { _ = await predecessor.result }
            try Task.checkCancellation()
            guard let self, self.socket === task, self.secure === channel else { throw CancellationError() }
            // Serialize whole messages, including every chunk, so HPKE sequence order matches the wire.
            do {
                for record in try channel.seal(data) {
                    try Task.checkCancellation()
                    try await task.send(.data(record))
                }
            } catch {
                // The context may have advanced even if the socket did not acknowledge a
                // write. Discard it before another queued operation can resume.
                if self.socket === task { self.fail(error) }
                throw error
            }
        }
        outgoing = operation
        try await withTaskCancellationHandler { try await operation.value }
            onCancel: { operation.cancel() }
    }

    private func receive(_ data: Data) throws {
        guard let frame = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HermesError.message("The companion sent an invalid response.")
        }
        if frame["type"] as? String == "rpc", let body = frame["body"] as? [String: Any] {
            onRPC?(try JSONSerialization.data(withJSONObject: body))
        } else if frame["type"] as? String == "http", let id = frame["id"] as? String {
            // A timed-out or cancelled request may still finish on the host. Never replay it.
            guard let request = pending.removeValue(forKey: id) else { return }
            request.timeout.cancel()
            let status = frame["status"] as? Int ?? 502
            let body = frame["body"] ?? [:]
            request.continuation.resume(returning: (try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed]), status))
        } else { throw HermesError.message("The companion sent an unsupported response.") }
    }

    private static func readBinary(_ socket: URLSessionWebSocketTask) async throws -> Data {
        guard case .data(let data) = try await socket.receive(), data.count <= 65536 else {
            throw HermesError.message("The relay sent an invalid encrypted record.")
        }
        return data
    }

    private func fail(_ error: Error) {
        close()
        onDisconnect?(error)
    }

    func close() {
        mobileProtocolVersion = nil
        mobileFeatures = [:]
        reader?.cancel(); reader = nil
        outgoing?.cancel(); outgoing = nil
        secure?.invalidate(); secure = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        let requests = pending.values
        pending = [:]
        for request in requests {
            request.timeout.cancel()
            request.writer?.cancel()
            request.continuation.resume(throwing: HermesError.message("The companion connection closed."))
        }
    }
}

private final class CompanionRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
