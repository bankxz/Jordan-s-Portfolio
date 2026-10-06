import Foundation
import PeakKit
import Testing
@testable import PeakServerCore

@Suite("DeepSeek provider")
struct DeepSeekTests {
    let clock = TestClock()

    static func reply(content: String?, toolCalls: [(id: String, name: String, arguments: String)] = [],
                      finish: String = "stop", promptTokens: Int = 1_000, cacheHits: Int = 0, completion: Int = 100) -> OutboundResponse {
        var message: [String: JSONValue] = ["role": "assistant", "content": content.map(JSONValue.string) ?? .null]
        if toolCalls.isEmpty == false {
            message["tool_calls"] = .array(toolCalls.map { call in
                ["id": .string(call.id), "type": "function",
                 "function": ["name": .string(call.name), "arguments": .string(call.arguments)]]
            })
        }
        let body: JSONValue = [
            "id": "chatcmpl-1", "object": "chat.completion", "model": "deepseek-chat",
            "choices": [["index": 0, "message": .object(message), "finish_reason": .string(finish)]],
            "usage": ["prompt_tokens": .number(Double(promptTokens)), "completion_tokens": .number(Double(completion)),
                      "prompt_cache_hit_tokens": .number(Double(cacheHits)),
                      "prompt_cache_miss_tokens": .number(Double(promptTokens - cacheHits))],
        ]
        return OutboundResponse(status: 200, body: Data(body.jsonString().utf8))
    }

    static func body(_ request: OutboundRequest) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try #require(request.body))
    }

    @Test func translatesClaudeRequestsToChatCompletions() async throws {
        let http = FakeHTTP { _ in Self.reply(content: #"{"ok":true}"#) }
        let client = DeepSeekClient(apiKey: "sk-ds-test", http: http)
        let request = ClaudeRequest(
            model: "deepseek-chat", maxTokens: 20_000, system: "Be brief.",
            messages: [
                .user("Why is my game down?"),
                ClaudeRequest.Message(role: "assistant", content: [
                    ["type": "thinking", "thinking": "", "signature": "s"],
                    ["type": "text", "text": "Let me check."],
                    ["type": "tool_use", "id": "call_1", "name": "list_games", "input": ["game_id": 5]],
                ]),
                .toolResults([(id: "call_1", content: "[]", isError: false)]),
                .user("Use only tool numbers."),
            ],
            tools: [.init(name: "list_games", description: "Games", inputSchema: ["type": "object"])],
            effort: "medium", outputSchema: ["type": "object", "properties": ["ok": ["type": "boolean"]]],
            useServerFallback: true)
        _ = try await client.send(request)

        let sent = try #require(await http.requests.first)
        #expect(sent.url.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(sent.headers["authorization"] == "Bearer sk-ds-test")
        let body = try Self.body(sent)
        #expect(body["model"] == "deepseek-chat")
        #expect(body["max_tokens"] == .number(8_192), "clamped to DeepSeek's output cap")
        #expect(body["response_format"] == ["type": "json_object"])
        #expect(body["output_config"] == nil && body["fallbacks"] == nil, "Claude-only fields are dropped")
        #expect(body["tools"]?.arrayValue?.first?["function"]?["name"] == "list_games")

        let messages = try #require(body["messages"]?.arrayValue)
        #expect(messages.map { $0["role"]?.stringValue } == ["system", "user", "assistant", "tool", "user"])
        let system = try #require(messages[0]["content"]?.stringValue)
        #expect(system.hasPrefix("Be brief.") && system.contains("JSON schema"), "JSON mode needs the word JSON and the schema")
        #expect(messages[2]["content"] == "Let me check.")
        let call = try #require(messages[2]["tool_calls"]?.arrayValue?.first)
        #expect(call["id"] == "call_1" && call["function"]?["name"] == "list_games")
        #expect(call["function"]?["arguments"] == #"{"game_id":5}"#)
        #expect(messages[3]["tool_call_id"] == "call_1" && messages[3]["content"] == "[]")
        #expect(messages[4]["content"] == "Use only tool numbers.")
    }

    @Test func translatesRepliesBack() async throws {
        let text = try DeepSeekClient.claudeResponse(
            from: try JSONDecoder().decode(JSONValue.self, from: Self.reply(content: "Hi", promptTokens: 1_000, cacheHits: 600).body),
            requestedModel: "deepseek-chat")
        #expect(text.text == "Hi" && text.stopReason == "end_turn")
        #expect(text.usage.inputTokens == 400 && text.usage.cacheReadInputTokens == 600 && text.usage.outputTokens == 100)

        let tools = try DeepSeekClient.claudeResponse(
            from: try JSONDecoder().decode(JSONValue.self, from: Self.reply(
                content: nil, toolCalls: [("call_a", "get_funnels", #"{"game_id":7}"#), ("call_b", "list_games", "not json")],
                finish: "tool_calls").body),
            requestedModel: "deepseek-chat")
        #expect(tools.stopReason == "tool_use")
        #expect(tools.toolUses.map(\.id) == ["call_a", "call_b"])
        #expect(tools.toolUses[0].input == ["game_id": 7])
        #expect(tools.toolUses[1].input == [:], "unparseable arguments become {} and the tool reports what's missing")
    }

    @Test(arguments: [
        (OutboundResponse(status: 429), ClaudeError.rateLimited),
        (OutboundResponse(status: 503), ClaudeError.overloaded),
        (OutboundResponse(status: 402), ClaudeError.http(status: 402)),
        (DeepSeekTests.reply(content: "cut", finish: "length"), ClaudeError.truncated),
        (DeepSeekTests.reply(content: "", finish: "content_filter"), ClaudeError.refused),
        (OutboundResponse(status: 200, body: Data("not json".utf8)), ClaudeError.malformedResponse),
    ])
    func failuresMapToClaudeErrors(response: OutboundResponse, expected: ClaudeError) async {
        let client = DeepSeekClient(apiKey: "k", http: FakeHTTP { _ in response })
        await #expect(throws: expected) {
            _ = try await client.send(ClaudeRequest(model: "deepseek-chat", maxTokens: 100, messages: [.user("hi")]))
        }
    }

    static let deepSeekSettings = AIService.Settings(provider: .deepseek, briefingModel: "deepseek-chat", askModel: "deepseek-chat",
                                                     dailyAskLimit: 2, monthlyBudgetMicros: 5_000_000)

    @Test func askRunsTheToolLoopThroughDeepSeek() async throws {
        let store = InMemoryStore()
        let user = try await store.upsertUser(robloxUserID: 1, username: "u", displayName: "U", now: clock.now)
        try await store.setAIConsent(userID: user.id, consent: AIConsent(consentedAt: clock.now, provider: "deepseek"))
        let replies = [Self.reply(content: nil, toolCalls: [("call_1", "list_games", "{}")], finish: "tool_calls"),
                       Self.reply(content: "Attack Animals has 4.8K players right now.")]
        let counter = Counter()
        let http = FakeHTTP { _ in replies[min(counter.next(), replies.count - 1)] }
        let service = AIService(store: store, claude: DeepSeekClient(apiKey: "k", http: http), settings: Self.deepSeekSettings,
                                now: clock.function)
        let toolbox = AIServiceTests.StubToolbox(outputs: ["list_games": #"[{"ccu":"4.8K","name":"Attack Animals"}]"#])
        let answer = try await service.ask("How many players?", userID: user.id, toolbox: toolbox)
        #expect(answer.isAIWritten)
        #expect(answer.answer == "Attack Animals has 4.8K players right now.")
        #expect(answer.sources == ["Your games"])

        let second = try Self.body(try #require(await http.requests.last))
        let roles = second["messages"]?.arrayValue?.map { $0["role"]?.stringValue }
        #expect(roles == ["system", "user", "assistant", "tool"])
        // Spend is recorded at DeepSeek prices: 2 × (1,000 in × $0.28 + 100 out × $0.42) per million = 644 µ$.
        #expect(try await store.aiCostMicros(since: .distantPast) == 644)
    }

    @Test func consentIsPerProvider() async throws {
        let store = InMemoryStore()
        let user = try await store.upsertUser(robloxUserID: 1, username: "u", displayName: "U", now: clock.now)
        try await store.setAIConsent(userID: user.id, consent: AIConsent(consentedAt: clock.now, provider: "claude"))
        let http = FakeHTTP { _ in Self.reply(content: "x") }
        let service = AIService(store: store, claude: DeepSeekClient(apiKey: "k", http: http), settings: Self.deepSeekSettings,
                                now: clock.function)

        // Agreed to Claude, server now uses DeepSeek: ask again, send nothing.
        let settings = try await service.settings(userID: user.id)
        #expect(settings.consented == false)
        #expect(settings.providerName == "DeepSeek")
        await #expect(throws: AIService.AskFailure.consentRequired) {
            _ = try await service.ask("hi", userID: user.id, toolbox: AIServiceTests.StubToolbox(outputs: [:]))
        }
        #expect(await http.requests.isEmpty)

        #expect(try await service.setConsent(userID: user.id, value: true).consented)
        #expect(try await store.aiConsent(userID: user.id)?.provider == "deepseek")
    }

    @Test func pricesAndOverrides() {
        let usage = ClaudeResponse.Usage(inputTokens: 1_000_000, outputTokens: 1_000_000, cacheReadInputTokens: 1_000_000)
        #expect(ClaudeModels.costMicros(model: "deepseek-chat", usage: usage) == 728_000)
        #expect(ClaudeModels.costMicros(model: "deepseek-v9-unknown", usage: .init(inputTokens: 1_000_000, outputTokens: 0)) == 2_000_000,
                "unknown DeepSeek models use the DeepSeek fallback, not Claude's")
        #expect(ClaudeModels.costMicros(model: "anything", usage: .init(inputTokens: 1_000_000, outputTokens: 1_000_000),
                                        override: .init(input: 0.5, output: 1)) == 1_500_000)
    }

    static let env = ServerConfigTests.base

    @Test func configChoosesTheProvider() throws {
        var env = Self.env
        env["DEEPSEEK_API_KEY"] = "sk-ds-secret"
        let deepseek = try #require(try ServerConfig.fromEnvironment(env).ai)
        #expect(deepseek.provider == ServerConfig.AIProvider.deepseek && deepseek.model == "deepseek-chat")
        #expect(deepseek.baseURL.absoluteString == "https://api.deepseek.com/")
        #expect(try ServerConfig.fromEnvironment(env).description.contains("sk-ds-secret") == false)

        env["ANTHROPIC_API_KEY"] = "sk-ant"
        #expect(try ServerConfig.fromEnvironment(env).ai?.provider == ServerConfig.AIProvider.claude, "Claude first when both keys are set")
        env["PEAK_AI_PROVIDER"] = "DeepSeek"
        #expect(try ServerConfig.fromEnvironment(env).ai?.provider == ServerConfig.AIProvider.deepseek)
        env["PEAK_AI_PROVIDER"] = "none"
        #expect(try ServerConfig.fromEnvironment(env).ai == nil)
        env["PEAK_AI_PROVIDER"] = "gpt"
        #expect(throws: ServerConfig.ConfigError.self) { try ServerConfig.fromEnvironment(env) }

        var missing = Self.env
        missing["PEAK_AI_PROVIDER"] = "deepseek"
        #expect(throws: ServerConfig.ConfigError.missing("DEEPSEEK_API_KEY")) { try ServerConfig.fromEnvironment(missing) }

        var priced = Self.env
        priced["DEEPSEEK_API_KEY"] = "k"
        priced["PEAK_AI_PRICE_INPUT"] = "0.3"
        #expect(throws: ServerConfig.ConfigError.self) { try ServerConfig.fromEnvironment(priced) }
        priced["PEAK_AI_PRICE_OUTPUT"] = "1.2"
        let settings = AIService.Settings(try #require(try ServerConfig.fromEnvironment(priced).ai))
        #expect(settings.priceOverride == ClaudeModels.Price(input: 0.3, output: 1.2))
        #expect(settings.provider == ServerConfig.AIProvider.deepseek)
    }
}

/// Thread-safe call counter for sequenced fake replies.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}
