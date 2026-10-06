import Foundation
import Logging
import PeakKit

/// Pulls daily Roblox Analytics (retention, session length, revenue per player, payer conversion, crash rate)
/// and funnel counts for users who granted `universe.analytics:read`. Feeds update reports, portfolio
/// health, the briefing and retention alerts.
///
/// The Analytics Query API allows 30 queries per minute per authorization, so queries are paced
/// (`pause` between them) and this runs a few times a day, not every minute.
public struct AnalyticsPoller: Sendable {
    public static let scope = RevenuePoller.scope

    /// Roblox metric name → Peak metric (analytics/metrics.md). All support `OneDay`.
    public static let dailyMetrics: [(roblox: String, metric: InsightMetric, days: Int)] = [
        ("ForwardD1Retention", .d1Retention, 35),
        ("ForwardD7Retention", .d7Retention, 35),
        ("AverageSessionLengthMinutes", .sessionLength, 35),
        ("AverageRevenuePerUser", .revenuePerPlayer, 35),
        ("PayingUsersCVR", .payerConversion, 35),
        // Crash data is kept for 28 days.
        ("ClientCrashRate15m", .crashRate, 27),
    ]
    public static let funnelMetric = "FunnelUserTotalCount"
    public static let funnelWindow: TimeInterval = 7 * 86_400

    let store: any Store
    let tokens: RobloxTokenManager
    let analytics: any RobloxAnalyticsQuerying
    let now: @Sendable () -> Date
    let pause: @Sendable (Duration) async throws -> Void
    /// Pause between queries: 3 s keeps one authorization at 20 queries per minute.
    let spacing: Duration

    public init(store: any Store, tokens: RobloxTokenManager, analytics: any RobloxAnalyticsQuerying,
                now: @escaping @Sendable () -> Date, spacing: Duration = .seconds(3),
                pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.store = store
        self.tokens = tokens
        self.analytics = analytics
        self.now = now
        self.spacing = spacing
        self.pause = pause
    }

    /// One pass over every granted universe. Returns the number of queries that succeeded.
    @discardableResult
    public func tick(logger: Logger) async throws -> Int {
        let today = Calendar.utc.startOfDay(for: now())
        var succeeded = 0
        for grant in try await store.allGrants() where grant.scopes.contains(Self.scope) {
            try Task.checkCancellation()
            let token: String
            do {
                token = try await tokens.accessToken(userID: grant.userID)
            } catch {
                logger.info("analytics skipped: no valid Roblox token", metadata: ["user": "\(grant.userID)"])
                continue
            }
            for universe in grant.universeIDs {
                for daily in Self.dailyMetrics {
                    let query = AnalyticsQuery(metric: daily.roblox, granularity: "OneDay",
                                               start: today.addingTimeInterval(-Double(daily.days) * 86_400),
                                               end: today.addingTimeInterval(86_400))
                    if try await run(query, universe: universe, token: token, logger: logger, handle: { series in
                        let points = series.flatMap(\.points).compactMap { point in point.time.map { ($0, point.value) } }
                        let values = Self.normalise(points.map(\.1), metric: daily.metric)
                        try await store.upsertInsightSamples(zip(points, values).map { point, value in
                            InsightSample(universeID: universe, metric: daily.metric, time: point.0, value: value)
                        })
                    }) { succeeded += 1 }
                }
                if try await pollFunnels(universe: universe, token: token, periodEnd: today, logger: logger) { succeeded += 1 }
            }
        }
        return succeeded
    }

    /// Runs one paced query. Failures are logged and skipped so one bad metric doesn't stop the rest.
    private func run(_ query: AnalyticsQuery, universe: Int64, token: String, logger: Logger,
                     handle: ([AnalyticsSeries]) async throws -> Void) async throws -> Bool {
        do {
            let series = try await analytics.query(query, universeID: universe, accessToken: token)
            try await handle(series)
            try await pause(spacing)
            return true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.warning("analytics query failed", metadata: ["universe": "\(universe)", "metric": "\(query.metric)",
                                                                "error": "\(error)"])
            try await pause(spacing)
            return false
        }
    }

    private func pollFunnels(universe: Int64, token: String, periodEnd: Date, logger: Logger) async throws -> Bool {
        func funnelQuery(end: Date) -> AnalyticsQuery {
            AnalyticsQuery(metric: Self.funnelMetric, granularity: "None", start: end.addingTimeInterval(-Self.funnelWindow),
                           end: end, breakdown: ["FunnelName", "FunnelStep"], limit: 200)
        }
        var current: [AnalyticsSeries] = []
        var previous: [AnalyticsSeries] = []
        guard try await run(funnelQuery(end: periodEnd), universe: universe, token: token, logger: logger,
                            handle: { current = $0 }) else { return false }
        guard current.isEmpty == false else { return true }  // The game logs no funnels.
        _ = try await run(funnelQuery(end: periodEnd.addingTimeInterval(-Self.funnelWindow)), universe: universe,
                          token: token, logger: logger, handle: { previous = $0 })
        let snapshots = Self.snapshots(current: current, previous: previous, universe: universe, periodEnd: periodEnd)
        try await store.saveFunnelSnapshots(snapshots)
        return true
    }

    /// Groups breakdown series into funnels. Roblox back-fills skipped steps, so counts never increase along a
    /// funnel: sorting by players (descending) recovers the step order without relying on the step label format.
    static func snapshots(current: [AnalyticsSeries], previous: [AnalyticsSeries], universe: Int64,
                          periodEnd: Date) -> [FunnelSnapshot] {
        func totals(_ series: [AnalyticsSeries]) -> [String: [String: Int]] {
            var result: [String: [String: Int]] = [:]
            for item in series {
                guard let funnel = item.breakdown["FunnelName"], let step = item.breakdown["FunnelStep"] else { continue }
                let players = item.points.reduce(0) { $0 + max(0, $1.value) }
                result[funnel, default: [:]][step, default: 0] += Int(players.rounded())
            }
            return result
        }
        let now = totals(current)
        let before = totals(previous)
        return now.keys.sorted().map { funnel in
            let steps = now[funnel]!
                .sorted { lhs, rhs in lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key }
                .map { FunnelStep(name: $0.key, players: $0.value, previousPlayers: before[funnel]?[$0.key]) }
            return FunnelSnapshot(universeID: universe, funnelName: funnel, periodEnd: periodEnd, steps: steps)
        }
    }

    /// Rates that should be 0...1 are stored as fractions. If any value in a fraction series is above 1, the
    /// API reported percentages, so the whole series is divided by 100. (Assumption to confirm against real
    /// data; see docs/ai/AI_FEATURES.md.)
    static func normalise(_ values: [Double], metric: InsightMetric) -> [Double] {
        guard metric.unit == .fraction, values.contains(where: { $0 > 1 }) else { return values }
        return values.map { $0 / 100 }
    }
}
