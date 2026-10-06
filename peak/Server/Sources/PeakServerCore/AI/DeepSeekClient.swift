import Foundation

/// DeepSeek as an alternative to Claude: a cheaper option the server owner can choose with `PEAK_AI_PROVIDER`.
///
/// DeepSeek's chat API is OpenAI-compatible (`POST /chat/completions`, `Authorization: Bearer`). This adapter
/// translates Peak's Claude-shaped requests to it and the replies back, so `AIService` (consent, limits, budget,
/// tool loop, number check) works unchanged:
/// - The system prompt becomes a `system` message. A JSON schema becomes JSON mode plus the schema in the
///   prompt (DeepSeek's JSON mode needs the word "JSON" in the prompt). The number check still validates the
///   result.
/// - `tool_use` / `tool_result` blocks become `tool_calls` / `tool` messages. Claude-only fields (effort,
///   fallbacks, cache control, thinking) are dropped.
/// - `finish_reason` maps to Claude's stop reasons; `length` and `content_filter` throw like Claude's
///   `max_tokens` and `refusal`.
public struct DeepSeekClient: ClaudeAPI {
    public static let defaultBaseURL = URL(string: "https://api.deepseek.com/")!
    /// deepseek-chat's documented output cap; larger requests are clamped.
    static let maxOutputTokens = 8_192

    private let apiKey: String
    private let baseURL: URL
    private let http: any HTTPExecutor

    public init(apiKey: String, baseURL: URL = DeepSeekClient.defaultBaseURL, http: any HTTPExecutor) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.http = http
    }

    public func send(_ request: ClaudeRequest) async throws -> ClaudeResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = try encoder.encode(Self.chatRequest(from: request))
        let response = try await http.execute(OutboundRequest(
            method: "POST", url: baseURL.appendingPathComponent("chat/completions"),
            headers: ["authorization": "Bearer \(apiKey)", "content-type": "application/json"], body: body))
        switch response.status {
        case 200..<300: break
        case 429: throw ClaudeError.rateLimited
        case 503: throw ClaudeError.overloaded
        default: throw ClaudeError.http(status: response.status)
        }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: response.body) else {
            throw ClaudeError.malformedResponse
        }
        return try Self.claudeResponse(from: json, requestedModel: request.model)
    }

    // MARK: Request

    static func chatRequest(from request: ClaudeRequest) -> JSONValue {
        var messages: [JSONValue] = []
        var system = request.system ?? ""
        if let schema = request.outputSchema {
            system += "\n\nReply with only a JSON object that matches this JSON schema:\n\(schema.jsonString())"
        }
        if system.isEmpty == false { messages.append(["role": "system", "content": .string(system)]) }
        for message in request.messages {
            messages += chatMessages(from: message)
        }

        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "messages": .array(messages),
            "max_tokens": .number(Double(min(request.maxTokens, maxOutputTokens))),
            "stream": .bool(false),
        ]
        if let tools = request.tools, tools.isEmpty == false {
            body["tools"] = .array(tools.map { tool in
                ["type": "function",
                 "function": ["name": .string(tool.name), "description": .string(tool.description), "parameters": tool.inputSchema]]
            })
        }
        if request.outputSchema != nil { body["response_format"] = ["type": "json_object"] }
        return .object(body)
    }

    /// One Claude message can become several chat messages: tool results are separate `tool` messages and
    /// must come straight after the assistant message that asked for them.
    static func chatMessages(from message: ClaudeRequest.Message) -> [JSONValue] {
        let blocks = message.content
        let text = blocks.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }.joined()
        if message.role == "assistant" {
            let calls: [JSONValue] = blocks.compactMap { block in
                guard block["type"]?.stringValue == "tool_use", let id = block["id"]?.stringValue,
                      let name = block["name"]?.stringValue else { return nil }
                return ["id": .string(id), "type": "function",
                        "function": ["name": .string(name), "arguments": .string((block["input"] ?? [:]).jsonString())]]
            }
            var assistant: [String: JSONValue] = ["role": "assistant", "content": text.isEmpty ? .null : .string(text)]
            if calls.isEmpty == false { assistant["tool_calls"] = .array(calls) }
            return [.object(assistant)]
        }
        var result: [JSONValue] = blocks.compactMap { block in
            guard block["type"]?.stringValue == "tool_result", let id = block["tool_use_id"]?.stringValue else { return nil }
            var content = block["content"]?.stringValue ?? ""
            if block["is_error"] == .bool(true) { content = "Error: " + content }
            return ["role": "tool", "tool_call_id": .string(id), "content": .string(content)]
        }
        if text.isEmpty == false { result.append(["role": "user", "content": .string(text)]) }
        return result
    }

    // MARK: Response

    static func claudeResponse(from json: JSONValue, requestedModel: String) throws -> ClaudeResponse {
        guard let choice = json["choices"]?.arrayValue?.first, let message = choice["message"] else {
            throw ClaudeError.malformedResponse
        }
        var content: [JSONValue] = []
        if let text = message["content"]?.stringValue, text.isEmpty == false {
            content.append(["type": "text", "text": .string(text)])
        }
        for call in message["tool_calls"]?.arrayValue ?? [] {
            guard let id = call["id"]?.stringValue, let function = call["function"],
                  let name = function["name"]?.stringValue else { continue }
            // Arguments arrive as a JSON string. Unparseable arguments become {} and the tool reports what's missing.
            let arguments = function["arguments"]?.stringValue
                .flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) } ?? [:]
            content.append(["type": "tool_use", "id": .string(id), "name": .string(name), "input": arguments])
        }

        let stopReason: String
        switch choice["finish_reason"]?.stringValue {
        case "tool_calls": stopReason = "tool_use"
        case "length": throw ClaudeError.truncated
        case "content_filter": throw ClaudeError.refused
        case "insufficient_system_resource": throw ClaudeError.overloaded
        default: stopReason = "end_turn"
        }

        let usage = json["usage"]
        let promptTokens = Int(usage?["prompt_tokens"]?.doubleValue ?? 0)
        let cacheHits = Int(usage?["prompt_cache_hit_tokens"]?.doubleValue ?? 0)
        return ClaudeResponse(
            model: json["model"]?.stringValue ?? requestedModel, content: content, stopReason: stopReason,
            usage: .init(inputTokens: max(0, promptTokens - cacheHits),
                         outputTokens: Int(usage?["completion_tokens"]?.doubleValue ?? 0),
                         cacheReadInputTokens: cacheHits))
    }
}
