import Foundation

private struct FixtureConfiguration: Decodable {
    let connection: CompanionConnection
    let credentials: CompanionCredentials
    let dashboardURL: String
    let legacyCompanion: Bool
}

@main
struct CompanionSmoke {
    @MainActor
    static func main() async throws {
        let config = try JSONDecoder().decode(FixtureConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let client = HermesClient()
        let profiles = try await client.connect(companion: config.connection, credentials: config.credentials)
        precondition(profiles.map(\.id).contains("research"))
        print("PASS: real Swift client connects through the relay Worker and Python companion")
        let capabilities = try await client.companionAPI("capabilities")
        precondition(capabilities["relay_enabled"] as? Bool == true)
        let sessions = try await client.sessions(profile: "research")
        precondition(sessions.count == 101)
        let history = try await client.messages(profile: "research", sessionID: "saved-0")
        precondition(history.count == 501 && history.last?.text == "Message 500")
        print("PASS: encrypted REST discovery, pagination, history, and companion capabilities")
        try await client.openSession(profile: "research", sessionID: "saved-0")
        var text = ""
        try await client.send(text: "hello") { event in
            if case .delta(let delta) = event { text += delta }
        }
        precondition(text == "Hello Hermes")
        var approved = false
        try await client.send(text: "approval") { event in
            if case let .approval(requestID, _, choices) = event {
                precondition(choices.contains("once"))
                Task { @MainActor in
                    do { try await client.respondToApproval(requestID: requestID, choice: "once"); approved = true }
                    catch { fatalError("Approval failed: \(error)") }
                }
            }
        }
        precondition(approved)
        print("PASS: explicit tool approval")
        var clarified = false
        try await client.send(text: "clarify") { event in
            if case let .clarification(requestID, _, choices) = event {
                precondition(choices.contains("Staging"))
                Task { @MainActor in
                    do { try await client.respondToClarification(requestID: requestID, answer: "Staging"); clarified = true }
                    catch { fatalError("Clarification failed: \(error)") }
                }
            }
        }
        precondition(clarified)
        print("PASS: native clarification answer")
        if !config.legacyCompanion {
        approved = false
        try await client.send(text: "modern-approval") { event in
            if case let .approval(requestID, _, choices) = event {
                precondition(choices.contains("once"))
                Task { @MainActor in
                    do { try await client.respondToApproval(requestID: requestID, choice: "once"); approved = true }
                    catch { fatalError("Approval failed: \(error)") }
                }
            }
        }
        precondition(approved)
        print("PASS: explicit tool approval")
        clarified = false
        try await client.send(text: "modern-clarify") { event in
            if case let .clarification(requestID, _, choices) = event {
                precondition(choices.contains("Staging"))
                Task { @MainActor in
                    do { try await client.respondToClarification(requestID: requestID, answer: "Staging"); clarified = true }
                    catch { fatalError("Clarification failed: \(error)") }
                }
            }
        }
        precondition(clarified)
        print("PASS: native clarification answer")
        }
        let photo = DraftPhoto(data: Data(repeating: 137, count: 600_000), filename: "fixture.png")
        var final = ""
        try await client.send(text: "", photos: [photo]) { event in
            if case .finalText(let value) = event { final = value }
        }
        precondition(final == "Received 1 photos")
        print("PASS: encrypted streaming and 600KB photo transfer across multiple records")
        let cancelledCreation = Task { @MainActor in try await client.createSession(profile: "default") }
        cancelledCreation.cancel()
        do {
            _ = try await cancelledCreation.value
            preconditionFailure("A cancelled session creation was executed")
        } catch is CancellationError { }
        var statsRequest = URLRequest(url: URL(string: config.dashboardURL + "/api/fixture/stats")!)
        statsRequest.setValue("Bearer fixture-dashboard-token", forHTTPHeaderField: "Authorization")
        let (statsData, _) = try await URLSession.shared.data(for: statsRequest)
        let stats = try JSONSerialization.jsonObject(with: statsData) as! [String: Any]
        let requests = stats["requests"] as! [[String: Any]]
        precondition(!requests.contains { $0["method"] as? String == "session.create" })
        print("PASS: cancelling a queued RPC prevents session creation on Hermes")
        client.disconnect()

        let transport = CompanionTransport(connection: config.connection, credentials: config.credentials)
        try await transport.connect()
        try await transport.negotiateMobileProtocol()
        if config.legacyCompanion {
            precondition(transport.mobileProtocolVersion == nil)
            print("PASS: explicit 404 preserves legacy companion connectivity")
        } else {
            precondition(transport.mobileProtocolVersion == 1)
            try await transport.negotiateMobileProtocol()
            precondition(transport.mobileFeatures["interaction_replay"] as? Bool == true)
            print("PASS: versioned mobile protocol and unchanged capability cache")
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask { @MainActor in
                    let (data, status) = try await transport.request(path: "api/profiles", method: "GET", query: [:], body: nil)
                    precondition(status == 200 && !data.isEmpty)
                }
            }
            try await group.waitForAll()
        }
        print("PASS: concurrent requests preserve ciphertext ordering and correlation")
        let olderRequest = Task { @MainActor in
            try await transport.request(path: "api/sessions", method: "GET", query: ["profile": "research", "search": "fixture-delay"], body: nil)
        }
        let cancelledFollow = Task { @MainActor in
            try await transport.request(path: "api/plugins/hermes-jr/v1/follows", method: "PUT", query: [:],
                                        body: ["profile": "research", "session_id": "must-not-be-followed"])
        }
        cancelledFollow.cancel()
        do {
            _ = try await cancelledFollow.value
            preconditionFailure("A cancelled follow mutation was executed")
        } catch is CancellationError { }
        _ = try await olderRequest.value
        let (followsData, followsStatus) = try await transport.request(path: "api/plugins/hermes-jr/v1/follows", method: "GET", query: [:], body: nil)
        let follows = try JSONSerialization.jsonObject(with: followsData) as! [String: Any]
        precondition(followsStatus == 200 && (follows["follows"] as? [[String: Any]])?.isEmpty == true)
        print("PASS: cancelling a queued HTTP mutation prevents host subscription changes")
        let pending = Task { @MainActor in
            try await transport.request(path: "api/sessions", method: "GET", query: ["profile": "research", "search": "fixture-delay"], body: nil)
        }
        try await Task.sleep(for: .milliseconds(50))
        pending.cancel()
        do {
            _ = try await pending.value
            preconditionFailure("Cancelled request unexpectedly returned a result")
        } catch is CancellationError { }
        try await Task.sleep(for: .milliseconds(350))
        let (_, status) = try await transport.request(path: "api/profiles", method: "GET", query: [:], body: nil)
        precondition(status == 200 && transport.isConnected)
        print("PASS: cancelled HTTP request settles once; its late reply leaves the channel healthy")

        var disconnectObserved = false
        transport.onDisconnect = { _ in disconnectObserved = true }
        var revoke = URLRequest(url: URL(string: config.dashboardURL + "/api/fixture/revoke")!)
        revoke.httpMethod = "POST"
        revoke.setValue("Bearer fixture-dashboard-token", forHTTPHeaderField: "Authorization")
        let (_, revokeResponse) = try await URLSession.shared.data(for: revoke)
        precondition((revokeResponse as? HTTPURLResponse)?.statusCode == 200)
        for _ in 0..<50 {
            if disconnectObserved { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        precondition(disconnectObserved && !transport.isConnected)
        print("PASS: device revocation closes the live encrypted connection")
        transport.close()
    }
}
