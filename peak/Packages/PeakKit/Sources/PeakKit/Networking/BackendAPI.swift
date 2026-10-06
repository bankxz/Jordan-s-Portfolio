import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Time ranges offered on game charts.
public enum TimeRange: String, Codable, Sendable, CaseIterable, Identifiable {
    case day = "24h"
    case week = "7d"
    case month = "30d"

    public var id: String { rawValue }

    public var duration: TimeInterval {
        switch self {
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        }
    }

    public var title: String {
        switch self {
        case .day: "24H"
        case .week: "7D"
        case .month: "30D"
        }
    }
}

/// Everything Home needs in one request.
public struct Dashboard: Codable, Hashable, Sendable {
    public var games: [Game]
    public var goals: [Goal]
    public var campaigns: [Campaign]
    public var recentAlerts: [AlertEvent]
    /// Short CCU history per game (keyed by universe ID as a string in JSON) for sparklines.
    public var ccuSparklines: [String: MetricSeries]
    public var generatedAt: Date

    public init(games: [Game], goals: [Goal], campaigns: [Campaign], recentAlerts: [AlertEvent],
                ccuSparklines: [String: MetricSeries], generatedAt: Date) {
        self.games = games
        self.goals = goals
        self.campaigns = campaigns
        self.recentAlerts = recentAlerts
        self.ccuSparklines = ccuSparklines
        self.generatedAt = generatedAt
    }

    public func sparkline(for gameID: Int64) -> MetricSeries? {
        ccuSparklines[String(gameID)]
    }

    /// Sum of CCU across all games.
    public var totalCCU: Int { games.reduce(0) { $0 + $1.stats.ccu } }

    /// Robux across games that report revenue. `nil` when none do.
    public var totalRobux24h: Int64? {
        let values = games.compactMap(\.stats.robux24h)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    public var widgetSnapshot: WidgetSnapshot {
        var history: [Int64: MetricSeries] = [:]
        for game in games {
            history[game.id] = sparkline(for: game.id)
        }
        return WidgetSnapshot.make(games: games, ccuHistory: history, goals: goals, now: generatedAt)
    }
}

/// The data source the app's screens depend on. `RemoteDashboardService` talks to the backend;
/// `DemoDashboardService` serves sample data until a backend exists, and in previews and UI tests.
public protocol DashboardService: Sendable {
    func dashboard() async throws -> Dashboard
    func series(gameID: Int64, metric: Metric, range: TimeRange) async throws -> MetricSeries
    func setFavourite(gameID: Int64, isFavourite: Bool) async throws
    func setWorkingOn(gameID: Int64, isWorkingOn: Bool) async throws
    /// Imports an Ads Manager CSV for the game and returns its imported campaigns.
    func importCampaigns(csv: String, gameID: Int64) async throws -> [Campaign]
}

/// Backend endpoints. Contract documented in docs/api/backend-contract.md.
public enum BackendAPI {
    // Request/response bodies are public so the server decodes exactly what the app encodes.

    public struct FlagBody: Codable, Sendable, Hashable {
        public var value: Bool
        public init(value: Bool) { self.value = value }
    }

    public struct SessionCodeBody: Codable, Sendable, Hashable {
        public var code: String
        public init(code: String) { self.code = code }
    }

    public struct RefreshBody: Codable, Sendable, Hashable {
        public var refreshToken: String
        public init(refreshToken: String) { self.refreshToken = refreshToken }
    }

    public struct AuthStart: Codable, Sendable, Hashable {
        public var authorizeURL: URL
        public init(authorizeURL: URL) { self.authorizeURL = authorizeURL }
    }

    public struct DeviceBody: Codable, Sendable, Hashable {
        /// Hex-encoded APNs device token.
        public var apnsToken: String
        /// `true` for development builds (APNs sandbox).
        public var sandbox: Bool
        public init(apnsToken: String, sandbox: Bool) {
            self.apnsToken = apnsToken
            self.sandbox = sandbox
        }
    }

    /// Ads Manager CSV for one game. Parsed by `CampaignImport` on both the app (preview) and the server.
    public struct CampaignImportBody: Codable, Sendable, Hashable {
        public var gameID: Int64
        public var csv: String
        public init(gameID: Int64, csv: String) {
            self.gameID = gameID
            self.csv = csv
        }
    }

    /// Error body returned by the backend for 4xx/5xx responses.
    public struct ErrorBody: Codable, Sendable, Hashable {
        public var error: String
        public init(error: String) { self.error = error }
    }

    public static func dashboard() -> Endpoint<Dashboard> {
        Endpoint(path: "v1/dashboard")
    }

    public static func series(gameID: Int64, metric: Metric, range: TimeRange) -> Endpoint<MetricSeries> {
        Endpoint(path: "v1/games/\(gameID)/series", queryItems: [
            URLQueryItem(name: "metric", value: metric.rawValue),
            URLQueryItem(name: "range", value: range.rawValue),
        ])
    }

    public static func setFavourite(gameID: Int64, value: Bool) -> Endpoint<NoContent> {
        Endpoint(method: .put, path: "v1/games/\(gameID)/favourite", body: encode(FlagBody(value: value)))
    }

    public static func setWorkingOn(gameID: Int64, value: Bool) -> Endpoint<NoContent> {
        Endpoint(method: .put, path: "v1/games/\(gameID)/working-on", body: encode(FlagBody(value: value)))
    }

    public static func startRobloxAuth() -> Endpoint<AuthStart> {
        Endpoint(method: .post, path: "v1/auth/roblox/start", requiresAuth: false)
    }

    public static func exchangeSessionCode(_ code: String) -> Endpoint<AuthTokens> {
        Endpoint(method: .post, path: "v1/auth/session", body: encode(SessionCodeBody(code: code)), requiresAuth: false)
    }

    public static func refresh(refreshToken: String) -> Endpoint<AuthTokens> {
        Endpoint(method: .post, path: "v1/auth/refresh", body: encode(RefreshBody(refreshToken: refreshToken)),
                 requiresAuth: false)
    }

    public static func logout() -> Endpoint<NoContent> {
        Endpoint(method: .post, path: "v1/auth/logout")
    }

    public static func registerDevice(_ body: DeviceBody) -> Endpoint<NoContent> {
        Endpoint(method: .post, path: "v1/devices", body: encode(body))
    }

    /// Imports (or re-imports) campaigns; returns every imported campaign for the game.
    public static func importCampaigns(_ body: CampaignImportBody) -> Endpoint<[Campaign]> {
        Endpoint(method: .post, path: "v1/campaigns/import", body: encode(body))
    }

    public static func alertRules() -> Endpoint<[AlertRule]> {
        Endpoint(path: "v1/alerts/rules")
    }

    public static func saveAlertRule(_ rule: AlertRule) -> Endpoint<AlertRule> {
        Endpoint(method: .put, path: "v1/alerts/rules/\(rule.id.uuidString)", body: encode(rule))
    }

    public static func deleteAlertRule(id: UUID) -> Endpoint<NoContent> {
        Endpoint(method: .delete, path: "v1/alerts/rules/\(id.uuidString)")
    }

    private static func encode(_ value: some Encodable) -> Data? {
        try? JSONCoding.makeEncoder().encode(value)
    }
}

public struct RemoteDashboardService: DashboardService {
    private let client: APIClient

    public init(client: APIClient) {
        self.client = client
    }

    public func dashboard() async throws -> Dashboard {
        try await client.send(BackendAPI.dashboard())
    }

    public func series(gameID: Int64, metric: Metric, range: TimeRange) async throws -> MetricSeries {
        try await client.send(BackendAPI.series(gameID: gameID, metric: metric, range: range))
    }

    public func setFavourite(gameID: Int64, isFavourite: Bool) async throws {
        _ = try await client.send(BackendAPI.setFavourite(gameID: gameID, value: isFavourite))
    }

    public func setWorkingOn(gameID: Int64, isWorkingOn: Bool) async throws {
        _ = try await client.send(BackendAPI.setWorkingOn(gameID: gameID, value: isWorkingOn))
    }

    public func importCampaigns(csv: String, gameID: Int64) async throws -> [Campaign] {
        try await client.send(BackendAPI.importCampaigns(BackendAPI.CampaignImportBody(gameID: gameID, csv: csv)))
    }
}

/// Refreshes the session through the backend. A 400/401 from the refresh endpoint means the
/// refresh token itself is dead (revoked, reused, expired).
public struct BackendTokenRefresher: TokenRefresher {
    private let client: APIClient

    /// `client` must be built without an `AuthSessionCoordinator`; refresh is unauthenticated.
    public init(client: APIClient) {
        self.client = client
    }

    public func refresh(using refreshToken: String) async throws -> AuthTokens {
        do {
            return try await client.send(BackendAPI.refresh(refreshToken: refreshToken))
        } catch APIError.unauthorized {
            throw RefreshTokenRejected()
        } catch APIError.unexpectedStatus(400) {
            throw RefreshTokenRejected()
        }
    }
}
