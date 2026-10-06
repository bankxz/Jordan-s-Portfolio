import Foundation

/// `POST /v1/messages` request. Swift has no official Anthropic SDK, so this follows the documented raw
/// HTTP shape (claude-api skill, `curl/examples.md`).
public struct ClaudeRequest: Encodable, Sendable, Hashable {
    public struct Tool: Encodable, Sendable, Hashable {
        public var name: String
        public var description: String
        public var inputSchema: JSONValue
        public var strict: Bool

        public init(name: String, description: String, inputSchema: JSONValue, strict: Bool = true) {
            self.name = name
            self.description = description
            self.inputSchema = inputSchema
            self.strict = strict
        }

        enum CodingKeys: String, CodingKey {
            case name, description, strict
            case inputSchema = "input_schema"
        }
    }

    public struct Message: Encodable, Sendable, Hashable {
        public var role: String
        /// Raw content blocks, so assistant turns (including thinking blocks) go back unchanged.
        public var content: [JSONValue]

        public static func user(_ text: String) -> Message {
            Message(role: "user", content: [["type": "text", "text": .string(text)]])
        }

        public static func toolResults(_ results: [(id: String, content: String, isError: Bool)]) -> Message {
            Message(role: "user", content: results.map { result in
                ["type": "tool_result", "tool_use_id": .string(result.id), "content": .string(result.content),
                 "is_error": .bool(result.isError)]
            })
        }
    }

    public var model: String
    public var maxTokens: Int
    public var system: String?
    public var messages: [Message]
    public var tools: [Tool]?
    /// Thinking depth (`low`…`max`). Omitted for models that reject it.
    public var effort: String?
    /// JSON schema for structured output (`output_config.format`).
    public var outputSchema: JSONValue?
    /// Opt into server-side refusal fallback (`fallbacks: "default"`). Not allowed on the Batches API.
    public var useServerFallback: Bool

    public init(model: String, maxTokens: Int, system: String? = nil, messages: [Message], tools: [Tool]? = nil,
                effort: String? = nil, outputSchema: JSONValue? = nil, useServerFallback: Bool = false) {
        self.model = model
        self.maxTokens = maxTokens
        self.system = system
        self.messages = messages
        self.tools = tools
        self.effort = effort
        self.outputSchema = outputSchema
        self.useServerFallback = useServerFallback
    }

    enum CodingKeys: String, CodingKey {
        case model, system, messages, tools, fallbacks
        case maxTokens = "max_tokens"
        case outputConfig = "output_config"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(maxTokens, forKey: .maxTokens)
        if let system {
            // The system prompt is the stable prefix: cache it.
            let block: JSONValue = ["type": "text", "text": .string(system), "cache_control": ["type": "ephemeral"]]
            try container.encode([block], forKey: .system)
        }
        try container.encode(messages, forKey: .messages)
        if let tools, tools.isEmpty == false { try container.encode(tools, forKey: .tools) }
        var outputConfig: [String: JSONValue] = [:]
        if let effort { outputConfig["effort"] = .string(effort) }
        if let outputSchema { outputConfig["format"] = ["type": "json_schema", "schema": outputSchema] }
        if outputConfig.isEmpty == false { try container.encode(outputConfig, forKey: .outputConfig) }
        if useServerFallback { try container.encode("default", forKey: .fallbacks) }
    }
}

public struct ClaudeResponse: Decodable, Sendable, Hashable {
    public struct Usage: Decodable, Sendable, Hashable {
        public var inputTokens: Int
        public var outputTokens: Int
        public var cacheCreationInputTokens: Int?
        public var cacheReadInputTokens: Int?

        public init(inputTokens: Int, outputTokens: Int, cacheCreationInputTokens: Int? = nil, cacheReadInputTokens: Int? = nil) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheCreationInputTokens = cacheCreationInputTokens
            self.cacheReadInputTokens = cacheReadInputTokens
        }

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
        }
    }

    public var model: String
    public var content: [JSONValue]
    public var stopReason: String?
    public var usage: Usage

    public init(model: String, content: [JSONValue], stopReason: String?, usage: Usage) {
        self.model = model
        self.content = content
        self.stopReason = stopReason
        self.usage = usage
    }

    enum CodingKeys: String, CodingKey {
        case model, content, usage
        case stopReason = "stop_reason"
    }

    /// All text blocks joined.
    public var text: String {
        content.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }.joined()
    }

    public var toolUses: [(id: String, name: String, input: JSONValue)] {
        content.compactMap { block in
            guard block["type"]?.stringValue == "tool_use", let id = block["id"]?.stringValue,
                  let name = block["name"]?.stringValue else { return nil }
            return (id, name, block["input"] ?? [:])
        }
    }
}

public enum ClaudeError: Error, Equatable, Sendable {
    case rateLimited
    case overloaded
    case http(status: Int)
    /// `stop_reason: "refusal"`; check before reading content.
    case refused
    /// Hit `max_tokens`; structured output would be cut off.
    case truncated
    case malformedResponse
}

public protocol ClaudeAPI: Sendable {
    func send(_ request: ClaudeRequest) async throws -> ClaudeResponse
}

public struct ClaudeClient: ClaudeAPI {
    public static let fallbackBeta = "server-side-fallback-2026-07-01"
    private let apiKey: String
    private let baseURL: URL
    private let http: any HTTPExecutor

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.anthropic.com/")!, http: any HTTPExecutor) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.http = http
    }

    public func send(_ request: ClaudeRequest) async throws -> ClaudeResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var headers = [
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        ]
        if request.useServerFallback { headers["anthropic-beta"] = Self.fallbackBeta }
        let response = try await http.execute(OutboundRequest(method: "POST", url: baseURL.appendingPathComponent("v1/messages"),
                                                              headers: headers, body: try encoder.encode(request)))
        switch response.status {
        case 200..<300: break
        case 429: throw ClaudeError.rateLimited
        case 529: throw ClaudeError.overloaded
        default: throw ClaudeError.http(status: response.status)
        }
        guard let decoded = try? JSONDecoder().decode(ClaudeResponse.self, from: response.body) else {
            throw ClaudeError.malformedResponse
        }
        // Check the stop reason before trusting content (claude-api skill: refusals arrive as HTTP 200).
        switch decoded.stopReason {
        case "refusal": throw ClaudeError.refused
        case "max_tokens": throw ClaudeError.truncated
        default: return decoded
        }
    }
}

/// What each model can be asked for, and what it costs. Prices are USD per million tokens. Claude's come from
/// the claude-api skill's model table (2026-09-25). DeepSeek's come from published price lists (2026-10); they
/// change, so `PEAK_AI_PRICE_INPUT`/`_OUTPUT` can override. Unknown models are charged high, so the budget errs
/// on the safe side.
public enum ClaudeModels {
    public struct Price: Sendable, Hashable {
        public var input: Double
        public var output: Double
        public var cacheReadMultiplier: Double

        public init(input: Double, output: Double, cacheReadMultiplier: Double = 0.1) {
            self.input = input
            self.output = output
            self.cacheReadMultiplier = cacheReadMultiplier
        }
    }

    static let prices: [String: Price] = [
        "claude-fable-5-1": Price(input: 10, output: 50, cacheReadMultiplier: 0.025),
        "claude-opus-5-5": Price(input: 4, output: 20, cacheReadMultiplier: 0.05),
        "claude-opus-5": Price(input: 5, output: 25, cacheReadMultiplier: 0.1),
        "claude-sonnet-5-5": Price(input: 2, output: 10, cacheReadMultiplier: 0.1),
        "claude-sonnet-5": Price(input: 2, output: 10, cacheReadMultiplier: 0.1),
        "claude-haiku-4-5": Price(input: 1, output: 5, cacheReadMultiplier: 0.1),
        "deepseek-chat": Price(input: 0.28, output: 0.42, cacheReadMultiplier: 0.1),
    ]
    static let fallbackPrice = Price(input: 10, output: 50, cacheReadMultiplier: 0.1)
    /// Unknown DeepSeek models: above every DeepSeek price seen so far, far below Claude's fallback.
    static let deepSeekFallbackPrice = Price(input: 2, output: 8, cacheReadMultiplier: 0.1)

    /// Haiku 4.5 rejects `effort`.
    public static func supportsEffort(_ model: String) -> Bool { model.hasPrefix("claude-haiku") == false }

    /// Models that accept `fallbacks: "default"` on the Claude API.
    public static func supportsServerFallback(_ model: String) -> Bool {
        ["claude-fable-5-1", "claude-fable-5", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"].contains(model)
    }

    /// Cost in micro-dollars. $/MTok is the same number as micro-dollars per token.
    public static func costMicros(model: String, usage: ClaudeResponse.Usage, override: Price? = nil) -> Int64 {
        let price = override ?? prices[model] ?? (model.hasPrefix("deepseek") ? deepSeekFallbackPrice : fallbackPrice)
        let input = Double(usage.inputTokens) * price.input
        let output = Double(usage.outputTokens) * price.output
        let cacheWrite = Double(usage.cacheCreationInputTokens ?? 0) * price.input * 1.25
        let cacheRead = Double(usage.cacheReadInputTokens ?? 0) * price.input * price.cacheReadMultiplier
        return Int64((input + output + cacheWrite + cacheRead).rounded(.up))
    }
}
