import Foundation

@main struct ProtocolSmoke {
    @MainActor static func main() async throws {
        let base = "http://127.0.0.1:19119/hermes"
        let invalid = HermesClient()
        do {
            _ = try await invalid.connect(address: base, token: "wrong-token")
            fatalError("Invalid credentials were accepted")
        } catch { print("PASS: rejects invalid authentication") }
        invalid.disconnect()
        let navigatingClient = HermesClient()
        _ = try await navigatingClient.connect(address: base, token: "fixture-dashboard-token")
        try await navigatingClient.openSession(profile: "research", sessionID: "saved-0")
        var navigationAcknowledged = false
        var backgroundCompleted = false
        navigatingClient.onSessionEvent = { profile, session, type, _ in
            if profile == "research" && session == "saved-0" && type == "message.complete" { backgroundCompleted = true }
        }
        let sending = Task { @MainActor in
            do {
                try await navigatingClient.send(text: "navigation-wait") { event in
                    if case .accepted = event { navigationAcknowledged = true }
                }
                preconditionFailure("Expected local detachment")
            } catch is ConversationSuspended { }
        }
        for _ in 0..<100 where !navigationAcknowledged { try await Task.sleep(for: .milliseconds(20)) }
        precondition(navigationAcknowledged)
        let beforeSwitch = try await fixtureRequests(base: base)
        await navigatingClient.detachConversation()
        try await sending.value
        try await navigatingClient.openSession(profile: "default", sessionID: "saved-default")
        for _ in 0..<100 where !backgroundCompleted { try await Task.sleep(for: .milliseconds(20)) }
        precondition(backgroundCompleted)
        let switched = try await fixtureRequests(base: base)
        precondition(!switched.dropFirst(beforeSwitch.count).contains { ($0["method"] as? String) == "session.interrupt" })
        try await navigatingClient.openSession(profile: "research", sessionID: "saved-0")
        try await navigatingClient.send(text: "hello") { _ in }
        navigatingClient.disconnect()
        print("PASS: switching chats preserves remote execution and routes background completion to its original session")
        let client = HermesClient()
        let bots = try await client.connect(address: base, token: "fixture-dashboard-token")
        precondition(bots.map(\.id) == ["default", "research"])
        precondition(bots[1].name == "Research")
        precondition(bots[0].botSession == nil)
        precondition(bots[1].summary == "Research profile")
        precondition(bots[1].botSession?.id == "bot-tip")
        precondition(bots[1].botSession?.preview == "Existing continuous bot conversation")
        print("PASS: bot roster previews use the canonical conversation and keep profile descriptions separate")
        print("PASS: authenticated profile discovery through URL prefix")
        let botBaseline = try await fixtureRequests(base: base)
        let bot = try await client.botSession(profile: "research")
        precondition(bot.id == "bot-tip" && bot.title == "Bot Chat")
        try await client.openSession(profile: "research", sessionID: bot.id)
        let botMessages = try await client.messages(profile: "research", sessionID: bot.id)
        precondition(botMessages.first?.text == "Existing continuous bot conversation")
        let botCatalog = try await client.commandCatalog()
        precondition(!botCatalog.commands.contains { ["/new", "/title"].contains($0.text) })
        for command in ["/new", "/title Renamed"] {
            do {
                _ = try await client.executeCommand(command)
                fatalError("Bot Chat identity control was accepted")
            } catch HermesCommandError.rejected { }
        }
        _ = try await client.executeCommand("/compress")
        precondition(client.storedSessionID == "bot-next-tip")
        do {
            _ = try await client.executeCommand("/new")
            fatalError("Compression removed the Bot Chat identity guard")
        } catch HermesCommandError.rejected { }
        try await setFixtureBot(base: base, mode: "advanced")
        let advancedBot = try await client.botSession(profile: "research")
        precondition(advancedBot.id == "bot-next-tip")
        for mode in ["missing", "unsupported", "malformed", "failure"] {
            try await setFixtureBot(base: base, mode: mode)
            do {
                _ = try await client.botSession(profile: "research")
                fatalError("Invalid bot lookup was accepted: \(mode)")
            } catch { }
        }
        try await setFixtureBot(base: base, mode: "available")
        do {
            _ = try await client.botSession(profile: "default")
            fatalError("Another profile's bot conversation was opened")
        } catch { }
        let botRequests = Array((try await fixtureRequests(base: base)).dropFirst(botBaseline.count))
        precondition(!botRequests.contains { ["session.create", "prompt.submit", "session.title"].contains($0["method"] as? String ?? "") })
        precondition(botRequests.filter { $0["method"] as? String == "session.resume" }.count == 1)
        print("PASS: hidden Bot Chat lookup, compression tip refresh, profile isolation, and lookup failures without creation")
        try await checkBotReplies(client: client, base: base)
        let sessions = try await client.sessions(profile: "research")
        precondition(sessions.count == 101 && sessions.first?.id == "saved-0")
        print("PASS: profile isolation and session pagination")
        let messages = try await client.messages(profile: "research", sessionID: "saved-0")
        precondition(messages.count == 10 && messages.first?.text == "Message 491" && messages.last?.text == "Message 500")
        let older = try await client.messagePage(profile: "research", sessionID: "saved-0", offset: 10, limit: 30)
        precondition(older.messages.count == 30 && older.messages.first?.text == "Message 461" && older.messages.last?.text == "Message 490" && older.hasOlder)
        let short = try await client.visibleMessagePage(profile: "research", sessionID: "saved-short")
        precondition(short.messages.map(\.text) == ["Message 0", "Message 11"] && !short.hasOlder && short.returned == 12)
        let exact = try await client.visibleMessagePage(profile: "research", sessionID: "saved-exact")
        precondition(exact.messages.count == 10 && !exact.hasOlder && exact.returned == 10)
        let sparse = try await client.visibleMessagePage(profile: "research", sessionID: "saved-sparse")
        precondition(sparse.messages.map(\.text) == ["Message 0", "Message 1"] && !sparse.hasOlder && sparse.returned == 1202)
        let trailing = try await client.visibleMessagePage(profile: "research", sessionID: "saved-trailing")
        precondition(trailing.messages.map(\.text) == ["Message 40", "Message 41"] && !trailing.hasOlder && trailing.returned == 42)
        print("PASS: newest ten messages and older history page")
        let draftClient = HermesClient()
        _ = try await draftClient.connect(address: base, token: "fixture-dashboard-token")
        let emptyDraft = try await draftClient.createSession(profile: "research")
        try await draftClient.openSession(profile: "default", sessionID: "saved-default")
        let beforeDraftOpen = try await fixtureRequests(base: base)
        try await draftClient.openSession(profile: "research", sessionID: emptyDraft.id)
        let afterDraftOpen = try await fixtureRequests(base: base)
        precondition(afterDraftOpen.count == beforeDraftOpen.count)
        let emptyHistory = try await draftClient.messages(profile: "research", sessionID: emptyDraft.id)
        precondition(emptyHistory.isEmpty)
        print("PASS: reopening an empty draft reuses its runtime without database resume or history")
        do {
            try await draftClient.send(text: "reject-submit") { _ in }
            fatalError("Expected rejected draft submission")
        } catch HermesSendError.notSubmitted { }
        let rejectedHistory = try await draftClient.messages(profile: "research", sessionID: emptyDraft.id)
        precondition(rejectedHistory.isEmpty)
        try await draftClient.send(text: "hello") { _ in }
        let savedHistory = try await draftClient.messages(profile: "research", sessionID: emptyDraft.id)
        precondition(savedHistory.count == 10)
        print("PASS: rejected submission retains draft; first sent message enables saved history")
        _ = try await draftClient.createSession(profile: "research")
        draftClient.disconnect()
        _ = try await draftClient.connect(address: base, token: "fixture-dashboard-token")
        let relaunchedHistory = try await draftClient.messages(profile: "research", sessionID: emptyDraft.id)
        precondition(relaunchedHistory.count == 10)
        draftClient.disconnect()
        print("PASS: disconnect discards draft bookkeeping rather than hiding server history")
        let created = try await client.createSession(profile: "research")
        precondition(created.id == "saved-0")
        try await client.openSession(profile: "research", sessionID: created.id)
        let commandBaseline = try await fixtureRequests(base: base)
        let catalog = try await client.commandCatalog()
        precondition(catalog.commands.contains { $0.text == "/usage" && !$0.description.isEmpty })
        precondition(!catalog.commands.contains { $0.text == "/fixture-skill" })
        precondition(catalog.warning?.contains("Fixture catalog warning") == true)
        let rootCompletions = try await client.completeCommand("/")
        precondition(rootCompletions.contains { $0.text == "/usage" })
        precondition(!rootCompletions.contains { $0.text == "/fixture-skill" })
        let completions = try await client.completeCommand("/us")
        precondition(completions.first?.text == "/usage")
        let argumentCompletions = try await client.completeCommand("/reasoning h")
        precondition(argumentCompletions.first?.text == "/reasoning high")
        precondition(argumentCompletions.first?.description == "Use more reasoning")
        precondition(argumentCompletions.count == 1)
        print("PASS: scoped command discovery, explanations, and argument completion")
        let aliasChoices = try await client.completeCommand("/tokens")
        precondition(aliasChoices.count == 1 && aliasChoices.first?.text == "/usage")
        precondition(aliasChoices.first?.display == "/usage")
        precondition(aliasChoices.first?.description == "Show token usage for this session")
        let newChoice = try await client.completeCommand("/new")
        precondition(newChoice.first?.display == "/new")
        precondition(newChoice.first?.description == "Start a new session with this profile")
        let saveChoice = try await client.completeCommand("/save")
        precondition(saveChoice.first?.display == "/save")
        precondition(saveChoice.first?.description == "Export this conversation as JSON on your Hermes host")
        let noArgumentsBaseline = try await fixtureRequests(base: base)
        for text in ["/save ", "/save path", "/new ", "/status ", "/usage "] {
            let suggestions = try await client.completeCommand(text)
            precondition(suggestions.isEmpty)
        }
        let noArgumentsRequests = try await fixtureRequests(base: base)
        precondition(noArgumentsRequests.count == noArgumentsBaseline.count)
        print("PASS: canonical aliases share iOS explanations and controls without arguments offer no suggestions")
        let reasoningOptions = try await client.completeCommand("/reasoning ")
        precondition(reasoningOptions.map(\.text) == ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"].map { "/reasoning " + $0 })
        precondition(reasoningOptions.allSatisfy { !$0.description.isEmpty })
        let reasoningBaseline = try await fixtureRequests(base: base)
        for command in ["/reasoning show", "/reasoning --global", "/reasoning high --global"] {
            do {
                _ = try await client.executeCommand(command)
                fatalError("Unsupported reasoning control was accepted")
            } catch HermesCommandError.rejected { }
        }
        let rejectedReasoningRequests = Array((try await fixtureRequests(base: base)).dropFirst(reasoningBaseline.count))
        precondition(rejectedReasoningRequests.isEmpty)
        print("PASS: reasoning autocomplete offers effort levels and rejects terminal/global controls")
        let modelChoices = try await client.completeCommand("/model ")
        precondition(modelChoices.map(\.text) == ["/model research-current --provider fixture-auth", "/model research-alternative --provider fixture-auth"])
        precondition(modelChoices.first?.description == "Fixture Provider · Current model")
        precondition(modelChoices.allSatisfy { !$0.text.contains("unconfigured") })
        let filteredModels = try await client.completeCommand("/model alternative")
        precondition(filteredModels.count == 1 && filteredModels.first?.display == "research-alternative")
        if case .output(let text) = try await client.executeCommand("/model") {
            precondition(text.contains("Current model: research-current") && text.contains("Provider: fixture-auth"))
        } else { fatalError("Current model details were not returned") }
        print("PASS: scoped model discovery shows current/available models with explicit provider selection")
        if case .output(let text) = try await client.executeCommand("/usage") {
            precondition(text.contains("Total tokens: 120") && text.contains("Usage is estimated"))
        } else { fatalError("Command output was not returned") }
        if case .output(let text) = try await client.executeCommand("/status") {
            precondition(text == "Research session is idle")
        } else { fatalError("Session status was not returned") }
        _ = try await client.executeCommand("/title Fixture renamed")
        print("PASS: command output and native session controls use the active session")
        if case .confirmation(let message) = try await client.executeCommand("/model expensive-model") {
            precondition(message == "This model has a higher cost. Continue?")
        } else { fatalError("Model confirmation was bypassed") }
        if case .output(let text) = try await client.executeCommand("/model expensive-model", confirmed: true) {
            precondition(text.contains("expensive-model"))
        } else { fatalError("Confirmed model selection did not complete") }
        _ = try await client.executeCommand("/reasoning high")
        print("PASS: model changes honor server confirmation and reasoning remains session scoped")
        do {
            _ = try await client.executeCommand("/fixture-skill summarize this")
            fatalError("A non-default profile executed a launch-profile skill")
        } catch HermesCommandError.rejected { }
        let extensionClient = HermesClient()
        _ = try await extensionClient.connect(address: base, token: "fixture-dashboard-token")
        let extensionSession = try await extensionClient.createSession(profile: "default")
        try await extensionClient.openSession(profile: "default", sessionID: extensionSession.id)
        let extensionCatalog = try await extensionClient.commandCatalog()
        precondition(extensionCatalog.commands.contains { $0.text == "/fixture-skill" && $0.kind == "skill" })
        let extensionCompletions = try await extensionClient.completeCommand("/")
        precondition(extensionCompletions.contains { $0.text == "/fixture-skill" && $0.kind == "skill" })
        print("PASS: custom commands are restricted to their supported launch profile")
        if case .send(let message, _, let notice) = try await extensionClient.executeCommand("/fixture-direct") {
            precondition(message == "Expanded fixture prompt" && notice == "Fixture command expanded")
        } else { fatalError("Direct send directive was not decoded") }
        if case .send(let message, _, _) = try await extensionClient.executeCommand("/fixture-skill summarize this") {
            precondition(message == "Expanded research skill: summarize this")
        } else { fatalError("Skill dispatch was not decoded") }
        if case .output(let text) = try await extensionClient.executeCommand("/fixture-alias") {
            precondition(text.contains("Total tokens: 120"))
        } else { fatalError("Command alias was not resolved") }
        print("PASS: direct send, skill routing, and aliases return typed results without submitting prompts")
        for command in ["/fixture-reject", "/fixture-empty-send"] {
            do {
                _ = try await extensionClient.executeCommand(command)
                fatalError("Invalid command was reported as success: \(command)")
            } catch HermesCommandError.rejected { }
        }
        let serverErrorBaseline = try await fixtureRequests(base: base)
        do {
            _ = try await extensionClient.executeCommand("/fixture-server-error")
            fatalError("A worker failure was reported as a definitive rejection")
        } catch HermesCommandError.outcomeUnknown { }
        let serverErrorRequests = Array((try await fixtureRequests(base: base)).dropFirst(serverErrorBaseline.count))
        precondition(serverErrorRequests.count == 1 && serverErrorRequests.first?["method"] as? String == "slash.exec")
        print("PASS: worker failures with possible effects remain unknown without an alternate execution")
        let commandRequests = Array((try await fixtureRequests(base: base)).dropFirst(commandBaseline.count))
        let completionRequests = commandRequests.filter { $0["method"] as? String == "complete.slash" }
        precondition(!completionRequests.isEmpty)
        precondition(completionRequests.allSatisfy {
            guard let params = $0["params"] as? [String: Any] else { return false }
            return Set(params.keys) == ["text"]
        })
        print("PASS: slash completion uses the strict text-only contract and filters commands by profile")
        precondition(!commandRequests.contains { $0["method"] as? String == "prompt.submit" })
        let dispatches = commandRequests.filter { $0["method"] as? String == "command.dispatch" }
        precondition(dispatches.count == 2)
        precondition(dispatches.allSatisfy {
            let name = ($0["params"] as? [String: Any])?["name"] as? String
            return name == "fixture-skill" || name == "fixture-alias"
        })
        let titleRequest = commandRequests.first { $0["method"] as? String == "session.title" }
        precondition((titleRequest?["params"] as? [String: Any])?["title"] as? String == "Fixture renamed")
        let modelRequests = commandRequests.filter {
            $0["method"] as? String == "config.set" && ($0["params"] as? [String: Any])?["key"] as? String == "model"
        }
        precondition(modelRequests.count == 2)
        precondition((modelRequests[0]["params"] as? [String: Any])?["confirm_expensive_model"] as? Bool == false)
        precondition((modelRequests[1]["params"] as? [String: Any])?["confirm_expensive_model"] as? Bool == true)
        precondition(!commandRequests.contains {
            $0["method"] as? String == "complete.slash" && (($0["params"] as? [String: Any])?["text"] as? String ?? "").hasPrefix("/model ")
        })
        print("PASS: rejected commands and malformed directives never fall back to ordinary prompts")
        extensionClient.disconnect()
        var streamed = ""
        var final = ""
        var acknowledged = false
        try await client.send(text: "hello") { event in
            switch event {
            case .accepted: acknowledged = true
            case .delta(let value): streamed += value
            case .finalText(let value): final = value
            default: break
            }
        }
        precondition(streamed == "Hello Hermes" && final == "Hello Hermes" && acknowledged)
        print("PASS: create/resume identity, streaming, ignores other session events")
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
        try await client.send(text: "wait") { event in
            if case .activity(let value) = event, value.contains("fixture-wait") {
                Task { @MainActor in try await client.stop() }
            }
        }
        print("PASS: stop an active turn")
        let document = DraftPhoto(data: Data(repeating: 65, count: 600_000), filename: "notes.txt", isFile: true)
        try await client.send(text: "Read this", photos: [document]) { _ in }
        precondition(client.lastSentPhotoPaths == ["/fixture/uploads/notes.txt"])
        let fileStats = try await URLSession.shared.data(for: {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:19119/hermes/api/fixture/stats")!)
            request.setValue("Bearer fixture-dashboard-token", forHTTPHeaderField: "Authorization")
            return request
        }()).0
        precondition(String(data: fileStats, encoding: .utf8)!.contains("[User attached file: /fixture/uploads/notes.txt]"))
        print("PASS: multi-chunk file upload passes the saved path to Hermes")
        let photo = DraftPhoto(data: Data([137, 80, 78, 71]), filename: "fixture.png")
        final = ""
        try await client.send(text: "", photos: [photo, photo]) { event in
            if case .finalText(let value) = event { final = value }
        }
        precondition(final == "Received 2 photos")
        print("PASS: photos-only submission stages all photos before the prompt")
        do {
            try await client.send(text: "hello", photos: [photo, DraftPhoto(data: photo.data, filename: "reject.jpg")]) { _ in }
            fatalError("Rejected photo was accepted")
        } catch HermesSendError.notSubmitted { }
        try await client.send(text: "verify-cleanup") { _ in }
        print("PASS: upload rejection detaches previously staged photos")
        do {
            try await client.send(text: "reject-submit", photos: [photo]) { event in
                if case .accepted = event { fatalError("Rejected message marked delivered") }
            }
            fatalError("Rejected prompt was accepted")
        } catch HermesSendError.notSubmitted { }
        try await client.send(text: "verify-cleanup") { _ in }
        print("PASS: explicit prompt rejection detaches staged photos")
        do {
            try await client.send(text: "disconnect-submit", photos: [photo]) { event in
                if case .accepted = event { fatalError("Lost acknowledgement marked delivered") }
            }
            fatalError("Lost acknowledgement was reported as success")
        } catch HermesSendError.outcomeUnknown { }
        try await client.openSession(profile: "research", sessionID: created.id)
        do {
            try await client.send(text: "must-not-send") { _ in }
            fatalError("Uncertain photo state allowed another prompt")
        } catch HermesSendError.notSubmitted { }
        print("PASS: lost prompt acknowledgement never resubmits and fences uncertain photo state")
        client.disconnect()
        _ = try await client.connect(address: base, token: "fixture-dashboard-token")
        try await client.openSession(profile: "research", sessionID: created.id)
        do {
            try await client.send(text: "must-still-not-send") { _ in }
            fatalError("Reconnect silently cleared uncertain attachment state")
        } catch HermesSendError.notSubmitted(let message) {
            precondition(message.contains("restart the app"))
        }
        print("PASS: reconnect retains attachment block with accurate recovery guidance")
        _ = try await client.connect(address: "http://localhost:19119/hermes", token: "fixture-dashboard-token")
        try await client.openSession(profile: "research", sessionID: created.id)
        try await client.send(text: "separate-server-address") { _ in }
        print("PASS: attachment block is scoped to the server address")
        client.disconnect()
        let uploadClient = HermesClient()
        _ = try await uploadClient.connect(address: base, token: "fixture-dashboard-token")
        try await uploadClient.openSession(profile: "research", sessionID: created.id)
        do {
            try await uploadClient.send(text: "hello", photos: [DraftPhoto(data: photo.data, filename: "disconnect.jpg")]) { _ in }
            fatalError("Unacknowledged upload was reported as submitted")
        } catch HermesSendError.notSubmitted { }
        print("PASS: lost upload acknowledgement reports an unsent message")
        uploadClient.disconnect()
        let commandClient = HermesClient()
        _ = try await commandClient.connect(address: base, token: "fixture-dashboard-token")
        try await commandClient.openSession(profile: "default", sessionID: extensionSession.id)
        let unknownBaseline = try await fixtureRequests(base: base)
        do {
            _ = try await commandClient.executeCommand("/fixture-disconnect")
            fatalError("Lost command acknowledgement was reported as success")
        } catch HermesCommandError.outcomeUnknown { }
        let unknownRequests = Array((try await fixtureRequests(base: base)).dropFirst(unknownBaseline.count))
        precondition(unknownRequests.filter { $0["method"] as? String == "slash.exec" }.count == 1)
        precondition(!unknownRequests.contains {
            ["command.dispatch", "prompt.submit"].contains($0["method"] as? String ?? "")
        })
        print("PASS: unknown command outcome executes once with no alternate dispatch or prompt fallback")
        commandClient.disconnect()
        for (home, selectedProfile, sessionID, allowsExtensions) in [
            ("/fixture/hermes/profiles/research" as String?, "research", "saved-0", true),
            ("/fixture/unmatched", "default", "saved-default", false),
            (nil, "default", "saved-default", false),
        ] {
            try await setFixtureIdentity(base: base, home: home)
            let identityClient = HermesClient()
            _ = try await identityClient.connect(address: base, token: "fixture-dashboard-token")
            try await identityClient.openSession(profile: selectedProfile, sessionID: sessionID)
            let identityCatalog = try await identityClient.commandCatalog()
            precondition(identityCatalog.commands.contains { $0.text == "/fixture-skill" } == allowsExtensions)
            if !allowsExtensions {
                let identityBaseline = try await fixtureRequests(base: base)
                do {
                    _ = try await identityClient.executeCommand("/fixture-skill")
                    fatalError("An unverified gateway identity enabled custom commands")
                } catch HermesCommandError.rejected { }
                let identityRequests = try await fixtureRequests(base: base)
                precondition(identityRequests.count == identityBaseline.count)
            }
            identityClient.disconnect()
        }
        try await setFixtureIdentity(base: base, home: "/fixture/hermes")
        print("PASS: extension access follows verified gateway identity, including non-default and missing identities")
    }

    private static func fixtureRequests(base: String) async throws -> [[String: Any]] {
        var request = URLRequest(url: URL(string: base + "/api/fixture/stats")!)
        request.setValue("Bearer fixture-dashboard-token", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        precondition((response as? HTTPURLResponse)?.statusCode == 200)
        return (try JSONSerialization.jsonObject(with: data) as! [String: Any])["requests"] as! [[String: Any]]
    }

    private static func setFixtureIdentity(base: String, home: String?) async throws {
        var request = URLRequest(url: URL(string: base + "/api/fixture/identity")!)
        request.httpMethod = "POST"
        request.setValue("Bearer fixture-dashboard-token", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["home": home as Any? ?? NSNull()])
        let (_, response) = try await URLSession.shared.data(for: request)
        precondition((response as? HTTPURLResponse)?.statusCode == 200)
    }

    @MainActor private static func checkBotReplies(client: HermesClient, base: String) async throws {
        let enrollment = CompanionEnrollment(deviceID: "11111111-1111-4111-8111-111111111111",
            deviceToken: "fixture-device-token", installationID: "fixture-installation")
        try await client.openSession(profile: "research", sessionID: "bot-tip")
        let baseline = try await fixtureRequests(base: base)
        for mode in ["owner", "lost_ack"] {
            try await setFixtureBot(base: base, mode: "available", deliveryMode: mode)
            var accepted = false
            var reply = ""
            try await client.send(text: "Testing", enrollment: enrollment) { event in
                if case .accepted = event { accepted = true }
                if case .finalText(let text) = event { reply = text }
            }
            precondition(accepted && reply == "Bot replied to Testing")
        }
        let ownerRequests = Array((try await fixtureRequests(base: base)).dropFirst(baseline.count))
        precondition(ownerRequests.filter { $0["method"] as? String == "bot.reply.put" }.count == 2)
        precondition(!ownerRequests.contains { ["prompt.submit", "session.create", "session.interrupt"].contains($0["method"] as? String ?? "") })
        print("PASS: bot replies use the current owner; a lost acknowledgement reads the receipt without resubmitting")

        for mode in ["owner_failed", "owner_lost"] {
            try await setFixtureBot(base: base, mode: "available", deliveryMode: mode)
            do {
                try await client.send(text: "Testing", enrollment: enrollment) { _ in }
                fatalError("Expected bot owner failure")
            } catch HermesSendError.turnFailed where mode == "owner_failed" { }
            catch HermesSendError.outcomeUnknown where mode == "owner_lost" { }
        }
        print("PASS: bot owner failure and uncertain outcomes never start another session")

        try await setFixtureBot(base: base, mode: "available", deliveryMode: "queued_forever")
        var queued = false
        let waiting = Task { @MainActor in
            do {
                try await client.send(text: "Cancel this", enrollment: enrollment) { event in
                    if case .accepted = event { queued = true }
                }
                fatalError("Expected cancelled bot reply")
            } catch HermesSendError.notSubmitted { }
        }
        for _ in 0..<100 where !queued { try await Task.sleep(for: .milliseconds(20)) }
        precondition(queued)
        try await client.stop()
        try await waiting.value
        print("PASS: Stop cancels a queued bot reply without interrupting its owner")

        try await setFixtureBot(base: base, mode: "available")
        let photo = DraftPhoto(data: Data([137, 80, 78, 71]), filename: "bot-photo.png")
        try await client.send(text: "Read this", photos: [photo], enrollment: enrollment) { _ in }
        precondition(client.lastSentPhotoPaths == ["/fixture/uploads/bot-photo.png"])
        let photoRequests = try await fixtureRequests(base: base)
        let photoRequest = photoRequests.last { $0["method"] as? String == "bot.reply.put" }
        let references = (photoRequest?["params"] as? [String: Any])?["attachments"] as? [[String: String]]
        precondition(references?.first?["filename"] == "bot-photo.png")
        print("PASS: bot attachments upload to the companion and use owned file references")

        try await setFixtureBot(base: base, mode: "available", deliveryMode: "missing_capabilities")
        let oldBaseline = try await fixtureRequests(base: base)
        do {
            try await client.send(text: "Testing", enrollment: enrollment) { _ in }
            fatalError("Expected companion update requirement")
        } catch HermesSendError.notSubmitted(let text) { precondition(text.contains("Update the companion")) }
        let oldRequests = try await fixtureRequests(base: base)
        precondition(oldRequests.count == oldBaseline.count)
        print("PASS: old companions require an update before bot reply submission")

        try await setFixtureBot(base: base, mode: "available", deliveryMode: "session")
        let unownedBaseline = try await fixtureRequests(base: base)
        var reply = ""
        try await client.send(text: "Testing", enrollment: enrollment) { event in
            if case .finalText(let text) = event { reply = text }
        }
        precondition(reply == "Hello Hermes" && client.storedSessionID == "bot-tip")
        let unownedRequests = Array((try await fixtureRequests(base: base)).dropFirst(unownedBaseline.count))
        precondition(unownedRequests.filter { $0["method"] as? String == "prompt.submit" }.count == 1)
        precondition(!unownedRequests.contains { $0["method"] as? String == "session.create" })
        print("PASS: an unowned bot continues its existing canonical conversation")
        try await setFixtureBot(base: base, mode: "available")
    }

    private static func setFixtureBot(base: String, mode: String, deliveryMode: String = "owner") async throws {
        var request = URLRequest(url: URL(string: base + "/api/fixture/bot")!)
        request.httpMethod = "POST"
        request.setValue("Bearer fixture-dashboard-token", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["mode": mode, "delivery_mode": deliveryMode])
        let (_, response) = try await URLSession.shared.data(for: request)
        precondition((response as? HTTPURLResponse)?.statusCode == 200)
    }
}
