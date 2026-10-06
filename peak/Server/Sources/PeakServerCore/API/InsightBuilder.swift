import Foundation
import PeakKit

/// Runs the PeakKit insight engines over stored samples and timeline events. Every entry point is scoped
/// to the caller's granted universes through `DashboardBuilder`.
///
/// Data in V1: CCU and revenue samples, plus update times from the public games API. Retention, crash
/// rate and funnels need more Analytics scopes and will feed the same engines when ingested.
public struct InsightBuilder: Sendable {
    private let store: any Store
    private let dashboard: DashboardBuilder
    private let now: @Sendable () -> Date

    /// Day lags for "same time on previous days", plus 14/21/28 days for previous weeks.
    static let lagDays = [0, 1, 2, 3, 4, 5, 6, 7, 14, 21, 28]
    static let sampleWindow: TimeInterval = 30 * 60

    public init(store: any Store, dashboard: DashboardBuilder, now: @escaping @Sendable () -> Date) {
        self.store = store
        self.dashboard = dashboard
        self.now = now
    }

    // MARK: Anomalies and alerts

    /// Anomalies right now for each universe in CCU and revenue.
    public func anomalies(universes: [Int64]) async throws -> [Anomaly] {
        let current = now()
        var result: [Anomaly] = []
        for universe in universes {
            for metric in [Metric.ccu, .robux] {
                let points = try await lagPoints(universe: universe, metric: metric, at: current)
                // No recent sample → nothing to say about "now".
                guard points.contains(where: { $0.date == current }) else { continue }
                if case .anomaly(let anomaly) = AnomalyDetector.detect(gameID: universe, metric: metric.insightMetric, points: points) {
                    result.append(anomaly)
                }
            }
        }
        return result
    }

    /// Mean of each metric over the half hour before `at - lag`, for each lag. Sparse on purpose: a handful of
    /// small queries instead of a month of minute samples.
    func lagPoints(universe: Int64, metric: Metric, at time: Date) async throws -> [MetricPoint] {
        var points: [MetricPoint] = []
        for days in Self.lagDays {
            let anchor = time.addingTimeInterval(-Double(days) * 86_400)
            // Half-open (anchor - window, anchor], so a sample exactly one window back isn't averaged in.
            let windowStart = anchor.addingTimeInterval(-Self.sampleWindow)
            let samples = try await store.samples(universeID: universe, metric: metric, from: windowStart, to: anchor)
                .filter { $0.date > windowStart }
            guard samples.isEmpty == false else { continue }
            points.append(MetricPoint(date: anchor, value: samples.map(\.value).reduce(0, +) / Double(samples.count)))
        }
        return points
    }

    public func digests(userID: UUID) async throws -> [AlertDigest] {
        let board = try await dashboard.dashboard(userID: userID)
        let universes = board.games.map(\.id)
        let current = now()
        let events = try await store.timelineEvents(universeIDs: universes, from: current.addingTimeInterval(-2 * 86_400), to: current)
        return AlertPrioritizer.digests(
            anomalies: try await anomalies(universes: universes),
            gameNames: Dictionary(board.games.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
            events: events)
    }

    // MARK: Update impact

    public func latestUpdate(universe: Int64, within: TimeInterval = 30 * 86_400) async throws -> TimelineEvent? {
        let current = now()
        return try await store.timelineEvents(universeIDs: [universe], from: current.addingTimeInterval(-within), to: current)
            .last { $0.kind == .update && $0.gameID == universe }
    }

    public func updateImpact(userID: UUID, universe: Int64) async throws -> UpdateImpactReport? {
        try await dashboard.requireOwnership(userID: userID, universeID: universe)
        guard let update = try await latestUpdate(universe: universe) else { return nil }
        let current = now()
        var series: [InsightMetric: [MetricPoint]] = [:]
        for metric in [Metric.ccu, .robux] {
            var points: [MetricPoint] = []
            for day in 1...7 {
                // Whole days only, so the update day itself and today's partial day don't skew the means.
                for (start, isBefore) in [(update.date.addingTimeInterval(-Double(day) * 86_400), true),
                                          (update.date.addingTimeInterval(Double(day - 1) * 86_400), false)] {
                    let end = start.addingTimeInterval(86_400)
                    guard end <= current else { continue }
                    let samples = try await store.samples(universeID: universe, metric: metric, from: start, to: end)
                        .filter { isBefore ? $0.date < update.date : $0.date > update.date }
                    guard samples.isEmpty == false else { continue }
                    points.append(MetricPoint(date: start.addingTimeInterval(43_200),
                                              value: samples.map(\.value).reduce(0, +) / Double(samples.count)))
                }
            }
            if points.isEmpty == false { series[metric.insightMetric] = points }
        }
        let events = try await store.timelineEvents(universeIDs: [universe], from: update.date.addingTimeInterval(-7 * 86_400),
                                                    to: update.date.addingTimeInterval(7 * 86_400))
        return UpdateImpactAnalyzer.analyze(gameID: universe, updateLabel: "Update \(update.detail)", updateDate: update.date,
                                            series: series, events: events)
    }

    // MARK: Portfolio

    public func portfolio(userID: UUID) async throws -> [GameHealth] {
        let board = try await dashboard.dashboard(userID: userID)
        let current = now()
        let universes = board.games.map(\.id)
        let weekAgo = current.addingTimeInterval(-7 * 86_400)
        let ccuThen = try await store.latestSample(universeIDs: universes, metric: .ccu, atOrBefore: weekAgo)
        let robuxThen = try await store.latestSample(universeIDs: universes, metric: .robux, atOrBefore: weekAgo)
        let anomalies = try await anomalies(universes: universes)
        var inputs: [GameHealthInput] = []
        for game in board.games {
            let ccuChange = ccuThen[game.id].flatMap { then -> Double? in
                guard abs(then.date.timeIntervalSince(weekAgo)) <= 3_600, then.value > 0 else { return nil }
                return (Double(game.stats.ccu) - then.value) / then.value
            }
            let revenueChange = robuxThen[game.id].flatMap { then -> Double? in
                guard let revenue = game.stats.robux24h, abs(then.date.timeIntervalSince(weekAgo)) <= 3 * 3_600, then.value > 0 else { return nil }
                return (Double(revenue) - then.value) / then.value
            }
            let lastUpdate = try await latestUpdate(universe: game.id, within: 365 * 86_400)
            inputs.append(GameHealthInput(
                gameID: game.id, name: game.name, ccuChange7d: ccuChange, revenueChange7d: revenueChange,
                openIssues: anomalies.filter { $0.gameID == game.id && !$0.isGoodNews }.count,
                daysSinceUpdate: lastUpdate.map { Int(current.timeIntervalSince($0.date) / 86_400) }))
        }
        return PortfolioHealth.rank(inputs)
    }

    // MARK: Briefing

    /// The deterministic daily briefing for the user's favourite games.
    public func briefing(userID: UUID) async throws -> Briefing {
        let board = try await dashboard.dashboard(userID: userID)
        let current = now()
        let favourites = board.games.filter(\.isFavourite)
        let ids = favourites.map(\.id)
        let dayAgo = current.addingTimeInterval(-86_400)
        let revenueThen = try await store.latestSample(universeIDs: ids, metric: .robux, atOrBefore: dayAgo)

        var inputs: [BriefingGameInput] = []
        for game in favourites {
            let previous = revenueThen[game.id].flatMap { abs($0.date.timeIntervalSince(dayAgo)) <= 2 * 3_600 ? Int64($0.value) : nil }
            inputs.append(BriefingGameInput(game: game, revenuePrevious24h: previous,
                                            latestUpdate: try await updateImpact(userID: userID, universe: game.id)))
        }
        let events = try await store.timelineEvents(universeIDs: ids, from: current.addingTimeInterval(-2 * 86_400), to: current)
        let digests = AlertPrioritizer.digests(
            anomalies: try await anomalies(universes: ids),
            gameNames: Dictionary(favourites.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
            events: events)
        let goals = board.goals.compactMap { goal -> GoalProgress? in
            guard let game = board.games.first(where: { $0.id == goal.gameID }) else { return nil }
            let value: Double? = switch goal.metric {
            case .ccu: Double(game.stats.ccu)
            case .visits: Double(game.stats.visits)
            case .favourites: Double(game.stats.favourites)
            case .robux: game.stats.robux24h.map(Double.init)
            }
            return value.map { GoalProgress(goal: goal, evaluation: GoalEngine.evaluate(goal, currentValue: $0, now: current)) }
        }
        return BriefingBuilder.build(games: inputs, digests: digests, goals: goals, campaigns: board.campaigns, now: current)
    }
}
