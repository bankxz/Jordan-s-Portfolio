import Foundation

/// Public stats for one universe from `games.roblox.com/v1/games` (decision 0005).
public struct UniverseStats: Sendable, Hashable {
    public var universeID: Int64
    public var rootPlaceID: Int64
    public var name: String
    public var playing: Int
    public var visits: Int64
    public var favourites: Int64
    /// When the experience was last published or edited (`updated`). Feeds update reports and possible causes.
    public var updated: Date? = nil
}

public protocol RobloxGamesAPI: Sendable {
    /// At most `maxBatch` IDs per call.
    func stats(universeIDs: [Int64]) async throws -> [UniverseStats]
}

public struct RobloxGamesClient: RobloxGamesAPI {
    public static let maxBatch = 100
    private let baseURL: URL
    private let http: any HTTPExecutor

    public init(baseURL: URL, http: any HTTPExecutor) {
        self.baseURL = baseURL
        self.http = http
    }

    public func stats(universeIDs: [Int64]) async throws -> [UniverseStats] {
        precondition(universeIDs.count <= Self.maxBatch, "batch universes before calling")
        guard universeIDs.isEmpty == false else { return [] }
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/games"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "universeIds", value: universeIDs.map(String.init).joined(separator: ","))]
        let response = try await http.execute(OutboundRequest(method: "GET", url: components.url!, headers: ["Accept": "application/json"]))
        guard (200..<300).contains(response.status) else {
            if response.status == 429 {
                throw RobloxAPIError.rateLimited(retryAfter: response.header("Retry-After").flatMap(TimeInterval.init))
            }
            throw RobloxAPIError.upstream(status: response.status)
        }
        // Not an Open Cloud API: decode leniently and skip entries missing essentials.
        struct Body: Decodable {
            struct Entry: Decodable {
                var id: Int64?
                var rootPlaceId: Int64?
                var name: String?
                var playing: Int?
                var visits: Int64?
                var favoritedCount: Int64?
                var updated: String?
            }
            var data: [Entry]?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: response.body) else {
            throw RobloxAPIError.malformedResponse
        }
        let requested = Set(universeIDs)
        return (body.data ?? []).compactMap { entry in
            guard let id = entry.id, requested.contains(id), let name = entry.name else { return nil }
            return UniverseStats(universeID: id, rootPlaceID: entry.rootPlaceId ?? 0, name: name,
                                 playing: max(0, entry.playing ?? 0), visits: max(0, entry.visits ?? 0),
                                 favourites: max(0, entry.favoritedCount ?? 0),
                                 updated: entry.updated.flatMap(Self.parseDate))
        }
    }
}

extension RobloxGamesClient {
    /// ISO 8601 with or without fractional seconds ("2026-09-20T18:22:11.123Z").
    static func parseDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }
}

/// Open Cloud Analytics Query API (`universe.analytics:read`).
public protocol RobloxAnalyticsAPI: Sendable {
    /// Hourly data points for `metric` in `[start, end)`.
    func hourly(metric: String, universeID: Int64, start: Date, end: Date, accessToken: String) async throws -> [(Date, Double)]
}

public struct RobloxAnalyticsClient: RobloxAnalyticsAPI {
    let baseURL: URL
    private let http: any HTTPExecutor
    let pollDelays: [Duration]

    /// `pollDelays`: back-off between polls of a long-running operation; its length bounds the attempts.
    public init(baseURL: URL, http: any HTTPExecutor,
                pollDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8)]) {
        self.baseURL = baseURL
        self.http = http
        self.pollDelays = pollDelays
    }

    struct Operation: Decodable {
        struct Value: Decodable {
            struct Point: Decodable {
                var time: Date
                var value: Double?
            }
            var dataPoints: [Point]?
        }
        struct Response: Decodable { var values: [Value]? }
        struct Failure: Decodable { var message: String? }
        var path: String?
        var done: Bool?
        var response: Response?
        var error: Failure?
    }

    public enum AnalyticsError: Error, Hashable {
        case queryFailed
        case timedOut
    }

    public func hourly(metric: String, universeID: Int64, start: Date, end: Date, accessToken: String) async throws -> [(Date, Double)] {
        let formatter = ISO8601DateFormatter()
        let body = try JSONSerialization.data(withJSONObject: [
            "metric": metric,
            "granularity": "OneHour",
            "startTime": formatter.string(from: start),
            "endTime": formatter.string(from: end),
        ])
        let url = baseURL.appendingPathComponent("analytics-query-api/v1/universes/\(universeID)/metrics")
        var operation = try await send(OutboundRequest(method: "POST", url: url, headers: headers(accessToken), body: body))

        var delays = pollDelays[...]
        while operation.done != true {
            // The poll path comes from the response; only follow a plain relative `v1/...` path so a bad
            // response can't steer the bearer token to another host or endpoint.
            guard let path = operation.path, Self.isSafePollPath(path) else { throw AnalyticsError.queryFailed }
            guard let delay = delays.popFirst() else { throw AnalyticsError.timedOut }
            try await Task.sleep(for: delay)
            let pollURL = baseURL.appendingPathComponent("analytics-query-api/\(path)")
            operation = try await send(OutboundRequest(method: "GET", url: pollURL, headers: headers(accessToken)))
        }
        guard operation.error == nil, let values = operation.response?.values else { throw AnalyticsError.queryFailed }
        return values.flatMap { $0.dataPoints ?? [] }.compactMap { point in point.value.map { (point.time, $0) } }
    }

    static func isSafePollPath(_ path: String) -> Bool {
        path.hasPrefix("v1/") && path.count <= 512 && path.contains("..") == false && path.contains("://") == false
            && path.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/-_.".contains($0)) }
    }

    func headers(_ token: String) -> [String: String] {
        ["Authorization": "Bearer \(token)", "Content-Type": "application/json", "Accept": "application/json"]
    }

    private func send(_ request: OutboundRequest) async throws -> Operation {
        try await sendDecoding(request)
    }

    func sendDecoding<T: Decodable>(_ request: OutboundRequest) async throws -> T {
        let response = try await http.execute(request)
        switch response.status {
        case 200..<300: break
        case 401, 403: throw RobloxAPIError.invalidGrant
        case 429: throw RobloxAPIError.rateLimited(retryAfter: response.header("Retry-After").flatMap(TimeInterval.init))
        default: throw RobloxAPIError.upstream(status: response.status)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let operation = try? decoder.decode(T.self, from: response.body) else { throw RobloxAPIError.malformedResponse }
        return operation
    }
}
