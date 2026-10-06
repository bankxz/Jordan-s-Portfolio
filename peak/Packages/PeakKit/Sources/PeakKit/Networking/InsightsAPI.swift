import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension BackendAPI {
    /// Whether AI wording is available to this user, and how many questions are left today.
    public struct AISettings: Codable, Sendable, Hashable {
        /// The server has AI configured and within budget.
        public var available: Bool
        /// The user agreed to send their game data to Anthropic for AI features.
        public var consented: Bool
        public var asksRemainingToday: Int
        public var dailyAskLimit: Int

        public init(available: Bool, consented: Bool, asksRemainingToday: Int, dailyAskLimit: Int) {
            self.available = available
            self.consented = consented
            self.asksRemainingToday = asksRemainingToday
            self.dailyAskLimit = dailyAskLimit
        }
    }

    public struct AskBody: Codable, Sendable, Hashable {
        public var question: String
        public init(question: String) { self.question = question }
    }

    public struct AskAnswer: Codable, Sendable, Hashable {
        public var answer: String
        /// What the answer was based on (tool results summarised for display).
        public var sources: [String]
        /// `false` when the server fell back to a safe non-AI reply.
        public var isAIWritten: Bool
        public var asksRemainingToday: Int

        public init(answer: String, sources: [String], isAIWritten: Bool, asksRemainingToday: Int) {
            self.answer = answer
            self.sources = sources
            self.isAIWritten = isAIWritten
            self.asksRemainingToday = asksRemainingToday
        }
    }

    /// Longest question the server accepts.
    public static let maxQuestionLength = 500

    public static func aiSettings() -> Endpoint<AISettings> {
        Endpoint(path: "v1/insights/settings")
    }

    public static func setAIConsent(_ value: Bool) -> Endpoint<AISettings> {
        Endpoint(method: .put, path: "v1/insights/consent", body: encodeBody(FlagBody(value: value)))
    }

    public static func briefing() -> Endpoint<Briefing> {
        Endpoint(path: "v1/insights/briefing")
    }

    public static func ask(_ question: String) -> Endpoint<AskAnswer> {
        Endpoint(method: .post, path: "v1/insights/ask", body: encodeBody(AskBody(question: question)))
    }

    public static func alertDigests() -> Endpoint<[AlertDigest]> {
        Endpoint(path: "v1/insights/alerts")
    }

    public static func portfolio() -> Endpoint<[GameHealth]> {
        Endpoint(path: "v1/insights/portfolio")
    }

    /// Funnels the game logs with `AnalyticsService`, from the last 7 days. Empty when it logs none.
    public static func funnels(gameID: Int64) -> Endpoint<[NamedFunnel]> {
        Endpoint(path: "v1/games/\(gameID)/funnels")
    }

    /// 404 when no update has been seen for the game yet.
    public static func updateImpact(gameID: Int64) -> Endpoint<UpdateImpactReport> {
        Endpoint(path: "v1/games/\(gameID)/update-impact")
    }

    static func encodeBody(_ value: some Encodable) -> Data? {
        try? JSONCoding.makeEncoder().encode(value)
    }
}

/// Insights the app shows. `RemoteInsightService` talks to the backend; `DemoInsightService` serves sample
/// insights in demo mode, previews and UI tests.
public protocol InsightService: Sendable {
    func settings() async throws -> BackendAPI.AISettings
    func setConsent(_ value: Bool) async throws -> BackendAPI.AISettings
    func briefing() async throws -> Briefing
    func ask(_ question: String) async throws -> BackendAPI.AskAnswer
    func alertDigests() async throws -> [AlertDigest]
    func portfolio() async throws -> [GameHealth]
    /// `nil` when no update has been seen for the game.
    func updateImpact(gameID: Int64) async throws -> UpdateImpactReport?
    func funnels(gameID: Int64) async throws -> [NamedFunnel]
}

public struct RemoteInsightService: InsightService {
    private let client: APIClient

    public init(client: APIClient) {
        self.client = client
    }

    public func settings() async throws -> BackendAPI.AISettings { try await client.send(BackendAPI.aiSettings()) }
    public func setConsent(_ value: Bool) async throws -> BackendAPI.AISettings { try await client.send(BackendAPI.setAIConsent(value)) }
    public func briefing() async throws -> Briefing { try await client.send(BackendAPI.briefing()) }
    public func ask(_ question: String) async throws -> BackendAPI.AskAnswer { try await client.send(BackendAPI.ask(question)) }
    public func alertDigests() async throws -> [AlertDigest] { try await client.send(BackendAPI.alertDigests()) }
    public func portfolio() async throws -> [GameHealth] { try await client.send(BackendAPI.portfolio()) }

    public func funnels(gameID: Int64) async throws -> [NamedFunnel] {
        try await client.send(BackendAPI.funnels(gameID: gameID))
    }

    public func updateImpact(gameID: Int64) async throws -> UpdateImpactReport? {
        do {
            return try await client.send(BackendAPI.updateImpact(gameID: gameID))
        } catch APIError.notFound {
            return nil
        }
    }
}
