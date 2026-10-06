import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import PeakKit
import Testing
@testable import PeakServerCore

/// Scripted Claude: returns queued responses (or errors) in order and records every request.
actor FakeClaude: ClaudeAPI {
    enum Step: Sendable {
        case respond(ClaudeResponse)
        case fail(ClaudeError)
    }

    private var steps: [Step]
    private(set) var requests: [ClaudeRequest] = []

    init(_ steps: [Step]) { self.steps = steps }

    func send(_ request: ClaudeRequest) async throws -> ClaudeResponse {
        requests.append(request)
        guard steps.isEmpty == false else { throw ClaudeError.http(status: 500) }
        switch steps.removeFirst() {
        case .respond(let response): return response
        case .fail(let error): throw error
        }
    }

    static func text(_ text: String, model: String = "claude-opus-5-5") -> Step {
        .respond(ClaudeResponse(model: model,
                                content: [["type": "thinking", "thinking": "", "signature": "sig-1"],
                                          ["type": "text", "text": .string(text)]],
                                stopReason: "end_turn", usage: .init(inputTokens: 1_000, outputTokens: 200)))
    }

    static func toolUse(_ name: String, input: JSONValue = [:], id: String = "toolu_1") -> Step {
        .respond(ClaudeResponse(model: "claude-opus-5-5",
                                content: [["type": "thinking", "thinking": "", "signature": "sig-tool"],
                                          ["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]],
                                stopReason: "tool_use", usage: .init(inputTokens: 900, outputTokens: 50)))
    }
}

let aiSettings = AIService.Settings(briefingModel: "claude-opus-5-5", askModel: "claude-opus-5-5", dailyAskLimit: 2,
                                    monthlyBudgetMicros: 5_000_000)

@Suite("Claude client")
struct ClaudeClientTests {
    @Test func sendsTheDocumentedShape() async throws {
        let http = FakeHTTP { _ in
            OutboundResponse(status: 200, body: Data("""
                {"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5-5","stop_reason":"end_turn",
                 "content":[{"type":"thinking","thinking":"","signature":"s"},{"type":"text","text":"{\\"ok\\":true}"}],
                 "usage":{"input_tokens":12,"output_tokens":7,"cache_read_input_tokens":3}}
                """.utf8))
        }
        let client = ClaudeClient(apiKey: "sk-test", http: http)
        let response = try await client.send(ClaudeRequest(
            model: "claude-opus-5-5", maxTokens: 4_000, system: "Be brief.", messages: [.user("Hi")],
            effort: "low", outputSchema: ["type": "object"], useServerFallback: true))
        #expect(response.text == "{\"ok\":true}")
        #expect(response.usage.cacheReadInputTokens == 3)

        let request = try #require(await http.requests.first)
        #expect(request.url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.headers["x-api-key"] == "sk-test")
        #expect(request.headers["anthropic-version"] == "2023-06-01")
        #expect(request.headers["anthropic-beta"] == ClaudeClient.fallbackBeta)
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
        #expect(body["model"] == "claude-opus-5-5")
        #expect(body["max_tokens"] == 4_000)
        #expect(body["fallbacks"] == "default")
        #expect(body["output_config"] == ["effort": "low", "format": ["type": "json_schema", "schema": ["type": "object"]]])
        #expect(body["system"] == [["type": "text", "text": "Be brief.", "cache_control": ["type": "ephemeral"]]])
        #expect(body["thinking"] == nil, "Opus 5.5 rejects disabling thinking; we never send it")
    }

    @Test func omitsWhatAModelRejects() throws {
        let request = ClaudeRequest(model: "claude-haiku-4-5", maxTokens: 100, messages: [.user("Hi")])
        let body = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(request))
        #expect(body["output_config"] == nil)
        #expect(body["fallbacks"] == nil)
        #expect(body["system"] == nil)
        #expect(ClaudeModels.supportsEffort("claude-haiku-4-5") == false)
        #expect(ClaudeModels.supportsServerFallback("claude-haiku-4-5") == false)
        #expect(ClaudeModels.supportsServerFallback("claude-sonnet-5-5"))
    }

    @Test(arguments: [(429, ClaudeError.rateLimited), (529, .overloaded), (400, .http(status: 400))])
    func mapsHTTPErrors(status: Int, expected: ClaudeError) async {
        let client = ClaudeClient(apiKey: "k", http: FakeHTTP { _ in OutboundResponse(status: status) })
        await #expect(throws: expected) { try await client.send(ClaudeRequest(model: "m", maxTokens: 1, messages: [])) }
    }

    @Test(arguments: [("refusal", ClaudeError.refused), ("max_tokens", .truncated)])
    func checksStopReasonBeforeContent(stopReason: String, expected: ClaudeError) async {
        let client = ClaudeClient(apiKey: "k", http: FakeHTTP { _ in
            OutboundResponse(status: 200, body: Data("""
                {"model":"m","stop_reason":"\(stopReason)","content":[],"usage":{"input_tokens":1,"output_tokens":0}}
                """.utf8))
        })
        await #expect(throws: expected) { try await client.send(ClaudeRequest(model: "m", maxTokens: 1, messages: [])) }
    }

    @Test func costsUseThePriceTable() {
        let usage = ClaudeResponse.Usage(inputTokens: 1_000_000, outputTokens: 100_000, cacheReadInputTokens: 1_000_000)
        // Opus 5.5: $4 in + $2 out (100K × $20/M) + $0.20 cache reads.
        #expect(ClaudeModels.costMicros(model: "claude-opus-5-5", usage: usage) == 6_200_000)
        #expect(ClaudeModels.costMicros(model: "claude-haiku-4-5", usage: .init(inputTokens: 1_000, outputTokens: 1_000)) == 6_000)
        // Unknown models are charged at the top price so the budget errs on the safe side.
        #expect(ClaudeModels.costMicros(model: "mystery", usage: .init(inputTokens: 1, outputTokens: 1)) == 60)
    }
}

@Suite("AI service")
struct AIServiceTests {
    let clock = TestClock()

    func briefing() -> Briefing {
        SampleData.briefing(now: clock.now)
    }

    func wording(_ briefing: Briefing, headline: String? = nil, actionCount: Int? = nil, reason: String? = nil) -> String {
        let actions = (0..<(actionCount ?? briefing.actions.count)).map { index -> JSONValue in
            let original = briefing.actions[min(index, briefing.actions.count - 1)]
            return ["title": .string(original.title), "reason": .string(reason ?? original.reason)]
        }
        let value: JSONValue = [
            "headline": .string(headline ?? "Two things need a look today."),
            "games": [["gameID": .number(Double(briefing.games[0].gameID)), "summary": "CCU fell 24% on Attack Animals; the v129 update may be involved."]],
            "actions": .array(actions),
        ]
        return value.jsonString()
    }

    func service(_ claude: FakeClaude?, store: InMemoryStore, settings: AIService.Settings? = aiSettings) -> AIService {
        AIService(store: store, claude: claude, settings: settings, now: clock.function)
    }

    func consentedUser(_ store: InMemoryStore) async throws -> UUID {
        let user = try await store.upsertUser(robloxUserID: 1, username: "u", displayName: "U", now: clock.now)
        try await store.setAIConsent(userID: user.id, consent: AIConsent(consentedAt: clock.now, provider: "claude"))
        return user.id
    }

    @Test func groundedWordingIsUsedAndPaidFor() async throws {
        let store = InMemoryStore()
        let user = try await consentedUser(store)
        let facts = briefing()
        let claude = FakeClaude([FakeClaude.text(wording(facts))])
        let narrated = await service(claude, store: store).narrate(facts, userID: user)
        #expect(narrated.isAIWritten)
        #expect(narrated.headline == "Two things need a look today.")
        #expect(narrated.games[0].summary?.hasPrefix("CCU fell 24%") == true)
        #expect(narrated.games[0].facts == facts.games[0].facts, "facts stay exact")
        #expect(try await store.aiCostMicros(since: .distantPast) > 0)

        let request = try #require(await claude.requests.first)
        #expect(request.outputSchema == AIService.briefingSchema)
        #expect(request.effort == "low")
        #expect(request.useServerFallback)
    }

    @Test func inventedNumbersOrChangedStructureFallBackToTheTemplate() async throws {
        let store = InMemoryStore()
        let user = try await consentedUser(store)
        let facts = briefing()
        for bad in [wording(facts, headline: "CCU will hit 9,000 by Friday."),
                    wording(facts, actionCount: facts.actions.count + 1),
                    wording(facts, reason: "Revenue rose 913%."),
                    "not json"] {
            let narrated = await service(FakeClaude([FakeClaude.text(bad)]), store: store).narrate(facts, userID: user)
            #expect(narrated == facts)
        }
    }

    @Test func noConsentNoBudgetOrErrorsMeanNoAI() async throws {
        let store = InMemoryStore()
        let user = try await store.upsertUser(robloxUserID: 2, username: "u", displayName: "U", now: clock.now).id
        let facts = briefing()
        let claude = FakeClaude([FakeClaude.text(wording(facts))])
        #expect(await service(claude, store: store).narrate(facts, userID: user) == facts)
        #expect(await claude.requests.isEmpty, "no consent → no call")

        try await store.setAIConsent(userID: user, consent: AIConsent(consentedAt: clock.now, provider: "claude"))
        try await store.recordAIUsage(AIUsageRecord(userID: nil, feature: "briefing", model: "m", inputTokens: 0,
                                                    outputTokens: 0, costMicros: 5_000_000, time: clock.now))
        #expect(await service(claude, store: store).narrate(facts, userID: user) == facts)
        #expect(await claude.requests.isEmpty, "over budget → no call")

        let fresh = InMemoryStore()
        let other = try await consentedUser(fresh)
        #expect(await service(FakeClaude([.fail(.refused)]), store: fresh).narrate(facts, userID: other) == facts)
        #expect(await service(nil, store: fresh).narrate(facts, userID: other) == facts)
    }

    /// A toolbox that serves fixed outputs.
    struct StubToolbox: AskToolbox {
        var outputs: [String: String]
        var tools: [ClaudeRequest.Tool] {
            outputs.keys.sorted().map { .init(name: $0, description: $0, inputSchema: ["type": "object"]) }
        }
        func run(name: String, input: JSONValue) async -> (content: String, isError: Bool) {
            outputs[name].map { ($0, false) } ?? ("unknown tool", true)
        }
    }

    @Test func askRunsAReadOnlyToolLoopAndRoundTripsAssistantTurnsExactly() async throws {
        let store = InMemoryStore()
        let user = try await consentedUser(store)
        let firstTurn = FakeClaude.toolUse("list_games")
        let claude = FakeClaude([firstTurn, FakeClaude.text("Attack Animals has 4.8K players, down 24% vs yesterday.")])
        let toolbox = StubToolbox(outputs: ["list_games": #"[{"ccu":"4.8K","ccu_change_vs_yesterday":"-24%","name":"Attack Animals"}]"#])
        let answer = try await service(claude, store: store).ask("Why is Attack Animals down?", userID: user, toolbox: toolbox)
        #expect(answer.isAIWritten)
        #expect(answer.answer == "Attack Animals has 4.8K players, down 24% vs yesterday.")
        #expect(answer.sources == ["Your games"])
        #expect(answer.asksRemainingToday == 1)

        let requests = await claude.requests
        #expect(requests.count == 2)
        guard case .respond(let first) = firstTurn else { return }
        // Thinking blocks go back unchanged, then the tool result follows (append-only history).
        #expect(requests[1].messages[1].role == "assistant")
        #expect(requests[1].messages[1].content == first.content)
        #expect(requests[1].messages[2].content.first?["type"] == "tool_result")
        #expect(requests[1].messages[2].content.first?["tool_use_id"] == "toolu_1")
        // Counts once towards the daily limit even though it took two calls.
        #expect(try await store.aiRequestCount(userID: user, feature: "ask", since: .distantPast) == 1)
    }

    @Test func ungroundedAnswersGetOneCorrectionThenAreReplaced() async throws {
        let store = InMemoryStore()
        let user = try await consentedUser(store)
        let claude = FakeClaude([FakeClaude.text("CCU will reach 9,000 next week."), FakeClaude.text("Still 9,000 next week.")])
        let answer = try await service(claude, store: store).ask("Forecast?", userID: user, toolbox: StubToolbox(outputs: [:]))
        #expect(answer.isAIWritten == false)
        #expect(answer.answer == AIService.unreliableAnswer)
        let correction = try #require(await claude.requests.last?.messages.last)
        #expect(correction.role == "user")
        #expect(correction.content.first?["text"]?.stringValue?.contains("9,000") == true)
    }

    @Test func askRequiresAIConsentAndRespectsTheDailyLimit() async throws {
        let store = InMemoryStore()
        let toolbox = StubToolbox(outputs: [:])
        await #expect(throws: AIService.AskFailure.unavailable) {
            try await service(nil, store: store).ask("q", userID: UUID(), toolbox: toolbox)
        }
        let user = try await store.upsertUser(robloxUserID: 3, username: "u", displayName: "U", now: clock.now).id
        await #expect(throws: AIService.AskFailure.consentRequired) {
            try await service(FakeClaude([]), store: store).ask("q", userID: user, toolbox: toolbox)
        }
        try await store.setAIConsent(userID: user, consent: AIConsent(consentedAt: clock.now, provider: "claude"))
        let claude = FakeClaude([FakeClaude.text("Nothing unusual."), FakeClaude.text("Still nothing.")])
        let ai = service(claude, store: store)
        _ = try await ai.ask("q1", userID: user, toolbox: toolbox)
        _ = try await ai.ask("q2", userID: user, toolbox: toolbox)
        await #expect(throws: AIService.AskFailure.dailyLimitReached) { try await ai.ask("q3", userID: user, toolbox: toolbox) }
        clock.advance(86_400)
        #expect(try await ai.settings(userID: user).asksRemainingToday == 2, "resets at UTC midnight")
    }

    @Test func theToolLoopIsBounded() async throws {
        let store = InMemoryStore()
        let user = try await consentedUser(store)
        let claude = FakeClaude((0..<AIService.maxToolRounds).map { FakeClaude.toolUse("list_games", id: "toolu_\($0)") })
        let answer = try await service(claude, store: store).ask("q", userID: user,
                                                                 toolbox: StubToolbox(outputs: ["list_games": "[]"]))
        #expect(answer.isAIWritten == false)
        #expect(answer.answer == AIService.unreliableAnswer)
        #expect(await claude.requests.count == AIService.maxToolRounds)
    }
}

@Suite("Insight routes")
struct InsightRouteTests {
    static let universe = DataRouteTests.universe

    /// Four weeks of CCU every 30 minutes (steady), then a 40% drop now, plus an update 2 h ago.
    func seed(_ harness: RouteHarness, dropNow: Bool = true) async throws {
        let now = harness.clock.now
        try await harness.store.upsertGameInfo([GameInfo(universeID: Self.universe, rootPlaceID: 99, name: "Attack Animals", updatedAt: now)])
        var samples: [MetricSample] = []
        for step in 0...(29 * 48) {
            let time = now.addingTimeInterval(-Double(step) * 1_800)
            let value = step == 0 && dropNow ? 600.0 : 1_000.0
            samples.append(MetricSample(universeID: Self.universe, metric: .ccu, time: time, value: value))
        }
        try await harness.store.appendSamples(samples)
        try await harness.store.appendTimelineEvents([
            TimelineEvent(kind: .update, gameID: Self.universe, date: now.addingTimeInterval(-2 * 3_600), detail: "of 21 Sep, 12:13 UTC"),
        ])
    }

    func signInWithFavourite(_ harness: RouteHarness, _ client: some TestClientProtocol) async throws -> AuthTokens {
        let tokens = try await harness.signIn(client)
        _ = try await client.execute(uri: "/v1/games/\(Self.universe)/favourite", method: .put,
                                     headers: RouteHarness.bearer(tokens.accessToken),
                                     body: RouteHarness.json(BackendAPI.FlagBody(value: true)))
        return tokens
    }

    @Test func alertsAndBriefingWorkWithAIOff() async throws {
        let harness = RouteHarness()
        try await seed(harness)
        try await harness.app.test(.router) { client in
            let tokens = try await signInWithFavourite(harness, client)
            let headers = RouteHarness.bearer(tokens.accessToken)

            let alerts = try RouteHarness.decode([AlertDigest].self, try await client.execute(uri: "/v1/insights/alerts", method: .get, headers: headers).body)
            let digest = try #require(alerts.first)
            #expect(digest.message == "CCU fell 40%.")
            #expect(digest.causes.first?.evidence == "Update of 21 Sep, 12:13 UTC went live 2 h before the change.")

            let briefing = try RouteHarness.decode(Briefing.self, try await client.execute(uri: "/v1/insights/briefing", method: .get, headers: headers).body)
            #expect(briefing.isAIWritten == false)
            #expect(briefing.headline == "1 thing needs your attention today.")
            #expect(briefing.games.map(\.name) == ["Attack Animals"])

            let settings = try RouteHarness.decode(BackendAPI.AISettings.self, try await client.execute(uri: "/v1/insights/settings", method: .get, headers: headers).body)
            #expect(settings.available == false)

            let ask = try await client.execute(uri: "/v1/insights/ask", method: .post, headers: headers,
                                               body: RouteHarness.json(BackendAPI.AskBody(question: "Why?")))
            #expect(ask.status == .serviceUnavailable)
            #expect(try RouteHarness.decode(BackendAPI.ErrorBody.self, ask.body).error == "ai_unavailable")
        }
    }

    @Test func consentGatesAskAndBriefingGetsAIWording() async throws {
        var harness = RouteHarness()
        let claude = FakeClaude([
            FakeClaude.text(#"{"headline":"Attack Animals needs a look today.","games":[{"gameID":3828411582,"summary":"CCU fell 40%; the update 2 h earlier may be involved."}],"actions":[{"title":"Compare against the previous version.","reason":"CCU fell 40% after the update."}]}"#),
            FakeClaude.toolUse("list_games"),
            FakeClaude.text("CCU fell 40% on Attack Animals."),
        ])
        harness.claude = claude
        harness.aiSettings = aiSettings
        let configured = harness
        try await seed(configured)
        try await configured.app.test(.router) { client in
            let tokens = try await signInWithFavourite(configured, client)
            let headers = RouteHarness.bearer(tokens.accessToken)
            let body = RouteHarness.json(BackendAPI.AskBody(question: "Why?"))

            let denied = try await client.execute(uri: "/v1/insights/ask", method: .post, headers: headers, body: body)
            #expect(denied.status == .forbidden)
            #expect(try RouteHarness.decode(BackendAPI.ErrorBody.self, denied.body).error == "ai_consent_required")

            let consent = try await client.execute(uri: "/v1/insights/consent", method: .put, headers: headers,
                                                   body: RouteHarness.json(BackendAPI.FlagBody(value: true)))
            let settings = try RouteHarness.decode(BackendAPI.AISettings.self, consent.body)
            #expect(settings.available && settings.consented && settings.asksRemainingToday == 2)

            let briefing = try RouteHarness.decode(Briefing.self, try await client.execute(uri: "/v1/insights/briefing", method: .get, headers: headers).body)
            #expect(briefing.isAIWritten)
            #expect(briefing.headline == "Attack Animals needs a look today.")
            // Second fetch with unchanged facts reuses the wording: no extra Claude call.
            let again = try RouteHarness.decode(Briefing.self, try await client.execute(uri: "/v1/insights/briefing", method: .get, headers: headers).body)
            #expect(again.headline == briefing.headline)

            let answer = try await client.execute(uri: "/v1/insights/ask", method: .post, headers: headers, body: body)
            #expect(answer.status == .ok)
            #expect(try RouteHarness.decode(BackendAPI.AskAnswer.self, answer.body).answer == "CCU fell 40% on Attack Animals.")
            #expect(await claude.requests.count == 3, "one briefing call (then cached) and two for the question")

            let tooLong = try await client.execute(uri: "/v1/insights/ask", method: .post, headers: headers,
                                                   body: RouteHarness.json(BackendAPI.AskBody(question: String(repeating: "a", count: 501))))
            #expect(tooLong.status == .badRequest)
        }
    }

    @Test func updateImpactAndPortfolioAreScopedToTheCaller() async throws {
        let harness = RouteHarness()
        try await seed(harness, dropNow: false)
        try await harness.app.test(.router) { client in
            let tokens = try await harness.signIn(client)
            let headers = RouteHarness.bearer(tokens.accessToken)
            let report = try await client.execute(uri: "/v1/games/\(Self.universe)/update-impact", method: .get, headers: headers)
            #expect(report.status == .ok)
            let decoded = try RouteHarness.decode(UpdateImpactReport.self, report.body)
            #expect(decoded.updateLabel == "Update of 21 Sep, 12:13 UTC")
            #expect(decoded.verdict == .tooEarly, "the update was 2 h ago")

            let other = try await client.execute(uri: "/v1/games/42/update-impact", method: .get, headers: headers)
            #expect(other.status == .notFound)

            let portfolio = try RouteHarness.decode([GameHealth].self, try await client.execute(uri: "/v1/insights/portfolio", method: .get, headers: headers).body)
            #expect(portfolio.map(\.gameID) == [Self.universe])
            #expect(portfolio[0].needsUpdate == false)
        }
    }
}

@Suite("Update detection")
struct UpdateDetectionTests {
    struct Games: RobloxGamesAPI {
        let updated: Date
        func stats(universeIDs: [Int64]) async throws -> [UniverseStats] {
            universeIDs.map { UniverseStats(universeID: $0, rootPlaceID: 1, name: "G", playing: 10, visits: 1, favourites: 1, updated: updated) }
        }
    }

    @Test func publishTimesBecomeTimelineEventsOnce() async throws {
        let store = InMemoryStore()
        let clock = TestClock()
        let user = try await store.upsertUser(robloxUserID: 9, username: "u", displayName: "U", now: clock.now)
        try await store.saveGrant(RobloxGrant(userID: user.id, accessTokenSealed: Data(), refreshTokenSealed: Data(),
                                              refreshTokenHash: "h", accessTokenExpiresAt: clock.now, scopes: [],
                                              universeIDs: [5], updatedAt: clock.now))
        let published = Date(timeIntervalSince1970: 1_789_950_000)
        let poller = StatsPoller(store: store, games: Games(updated: published),
                                 alerts: AlertEvaluator(store: store, push: DisabledPushSender(), now: clock.function),
                                 now: clock.function)
        _ = try await poller.tick(logger: .init(label: "test"))
        clock.advance(60)
        _ = try await poller.tick(logger: .init(label: "test"))
        let events = try await store.timelineEvents(universeIDs: [5], from: .distantPast, to: .distantFuture)
        #expect(events.count == 1)
        #expect(events.first?.kind == .update)
        #expect(events.first?.detail == "of 21 Sep, 00:20 UTC")
    }

    @Test func parsesRobloxTimestamps() {
        #expect(RobloxGamesClient.parseDate("2026-09-20T18:22:11.123Z") != nil)
        #expect(RobloxGamesClient.parseDate("2026-09-20T18:22:11Z") != nil)
        #expect(RobloxGamesClient.parseDate("yesterday") == nil)
    }
}
