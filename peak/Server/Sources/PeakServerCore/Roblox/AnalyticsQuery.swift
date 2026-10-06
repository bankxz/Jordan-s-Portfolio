import Foundation

/// One Analytics Query API request (`QueryRequest` in Open Cloud `openapi.json`).
public struct AnalyticsQuery: Sendable, Hashable {
    public struct Filter: Sendable, Hashable {
        public var dimension: String
        public var operation: String
        public var values: [String]

        public init(dimension: String, operation: String = "In", values: [String]) {
            self.dimension = dimension
            self.operation = operation
            self.values = values
        }
    }

    public var metric: String
    /// `OneMinute`, `HalfHour`, `OneHour`, `OneDay`, `OneWeek`, `OneMonth` or `None`.
    public var granularity: String
    public var start: Date
    public var end: Date
    public var breakdown: [String]
    public var filters: [Filter]
    public var limit: Int?

    public init(metric: String, granularity: String, start: Date, end: Date, breakdown: [String] = [],
                filters: [Filter] = [], limit: Int? = nil) {
        self.metric = metric
        self.granularity = granularity
        self.start = start
        self.end = end
        self.breakdown = breakdown
        self.filters = filters
        self.limit = limit
    }

    func body() throws -> Data {
        let formatter = ISO8601DateFormatter()
        var object: [String: Any] = [
            "metric": metric,
            "granularity": granularity,
            "startTime": formatter.string(from: start),
            "endTime": formatter.string(from: end),
        ]
        if breakdown.isEmpty == false { object["breakdown"] = breakdown }
        if filters.isEmpty == false {
            object["filter"] = filters.map { ["dimension": $0.dimension, "operation": $0.operation, "values": $0.values] }
        }
        if let limit { object["limit"] = limit }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

/// One series of the result: the breakdown it belongs to and its points.
public struct AnalyticsSeries: Sendable, Hashable {
    public struct Point: Sendable, Hashable {
        public var time: Date?
        public var value: Double
        /// `Projected` values may still change; `NotStatisticallySignificant` ones are dropped by the client.
        public var isProjected: Bool
    }

    /// Dimension name → display value (falls back to the raw value).
    public var breakdown: [String: String]
    public var points: [Point]
}

public protocol RobloxAnalyticsQuerying: Sendable {
    func query(_ query: AnalyticsQuery, universeID: Int64, accessToken: String) async throws -> [AnalyticsSeries]
}

extension RobloxAnalyticsClient: RobloxAnalyticsQuerying {
    struct FullOperation: Decodable {
        struct Value: Decodable {
            struct Breakdown: Decodable { var dimension: String?; var value: String?; var displayValue: String? }
            struct Point: Decodable { var time: String?; var value: Double?; var status: String? }
            var breakdowns: [Breakdown]?
            var dataPoints: [Point]?
        }
        struct Response: Decodable { var values: [Value]? }
        struct Failure: Decodable { var message: String? }
        var path: String?
        var done: Bool?
        var response: Response?
        var error: Failure?
    }

    public func query(_ query: AnalyticsQuery, universeID: Int64, accessToken: String) async throws -> [AnalyticsSeries] {
        let url = baseURL.appendingPathComponent("analytics-query-api/v1/universes/\(universeID)/metrics")
        var operation: FullOperation = try await sendDecoding(
            OutboundRequest(method: "POST", url: url, headers: headers(accessToken), body: try query.body()))
        var delays = pollDelays[...]
        while operation.done != true {
            guard let path = operation.path, Self.isSafePollPath(path) else { throw AnalyticsError.queryFailed }
            guard let delay = delays.popFirst() else { throw AnalyticsError.timedOut }
            try await Task.sleep(for: delay)
            operation = try await sendDecoding(OutboundRequest(
                method: "GET", url: baseURL.appendingPathComponent("analytics-query-api/\(path)"),
                headers: headers(accessToken)))
        }
        guard operation.error == nil, let values = operation.response?.values else { throw AnalyticsError.queryFailed }
        return values.map { value in
            var breakdown: [String: String] = [:]
            for item in value.breakdowns ?? [] {
                if let dimension = item.dimension, let shown = item.displayValue ?? item.value { breakdown[dimension] = shown }
            }
            let points = (value.dataPoints ?? []).compactMap { point -> AnalyticsSeries.Point? in
                // Too little data to mean anything: leave it out rather than show noise.
                guard let number = point.value, number.isFinite, point.status != "NotStatisticallySignificant" else { return nil }
                return AnalyticsSeries.Point(time: point.time.flatMap(RobloxGamesClient.parseDate), value: number,
                                             isProjected: point.status == "Projected")
            }
            return AnalyticsSeries(breakdown: breakdown, points: points)
        }
    }
}
