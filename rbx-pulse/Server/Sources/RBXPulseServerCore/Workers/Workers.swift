import Foundation
import Logging
import RBXPulseKit
import ServiceLifecycle

/// Polls public stats for every granted universe, stores samples, then evaluates alerts.
public struct StatsPoller: Sendable {
    /// Samples are kept long enough for the 30-day chart plus margin.
    public static let retention: TimeInterval = 35 * 86_400

    let store: any Store
    let games: any RobloxGamesAPI
    let alerts: AlertEvaluator
    let now: @Sendable () -> Date

    public init(store: any Store, games: any RobloxGamesAPI, alerts: AlertEvaluator, now: @escaping @Sendable () -> Date) {
        self.store = store
        self.games = games
        self.alerts = alerts
        self.now = now
    }

    /// One poll. Returns the number of universes updated.
    @discardableResult
    public func tick(logger: Logger) async throws -> Int {
        // Truncate to the minute so a retried tick overwrites rather than duplicates samples.
        let time = Date(timeIntervalSince1970: (now().timeIntervalSince1970 / 60).rounded(.down) * 60)
        let universes = Array(Set(try await store.allGrants().flatMap(\.universeIDs))).sorted()
        var updated = 0
        for start in stride(from: 0, to: universes.count, by: RobloxGamesClient.maxBatch) {
            try Task.checkCancellation()
            let batch = Array(universes[start..<min(start + RobloxGamesClient.maxBatch, universes.count)])
            do {
                let stats = try await games.stats(universeIDs: batch)
                try await store.upsertGameInfo(stats.map {
                    GameInfo(universeID: $0.universeID, rootPlaceID: $0.rootPlaceID, name: $0.name, updatedAt: time)
                })
                try await store.appendSamples(stats.flatMap { s in [
                    MetricSample(universeID: s.universeID, metric: .ccu, time: time, value: Double(s.playing)),
                    MetricSample(universeID: s.universeID, metric: .visits, time: time, value: Double(s.visits)),
                    MetricSample(universeID: s.universeID, metric: .favourites, time: time, value: Double(s.favourites)),
                ] })
                updated += stats.count
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One failing batch (rate limit, outage) mustn't stop the others; stale data is labelled in the app.
                logger.warning("stats batch failed", metadata: ["error": "\(error)", "size": "\(batch.count)"])
            }
        }
        try await store.deleteSamples(before: time.addingTimeInterval(-Self.retention))
        try await alerts.evaluate(logger: logger)
        return updated
    }
}

/// Polls Robux revenue via the Analytics Query API for users who granted `universe.analytics:read`.
public struct RevenuePoller: Sendable {
    public static let scope = "universe.analytics:read"
    /// "Robux Spent (Realtime)", hourly granularity (analytics/metrics.md).
    public static let metric = "ItemMonetizationRevenue"

    let store: any Store
    let tokens: RobloxTokenManager
    let analytics: any RobloxAnalyticsAPI
    let now: @Sendable () -> Date

    public init(store: any Store, tokens: RobloxTokenManager, analytics: any RobloxAnalyticsAPI,
                now: @escaping @Sendable () -> Date) {
        self.store = store
        self.tokens = tokens
        self.analytics = analytics
        self.now = now
    }

    @discardableResult
    public func tick(logger: Logger) async throws -> Int {
        let current = now()
        let time = Date(timeIntervalSince1970: (current.timeIntervalSince1970 / 60).rounded(.down) * 60)
        let start = current.addingTimeInterval(-86_400)
        var updated = 0
        for grant in try await store.allGrants() where grant.scopes.contains(Self.scope) {
            try Task.checkCancellation()
            let token: String
            do {
                token = try await tokens.accessToken(userID: grant.userID)
            } catch {
                logger.info("revenue skipped: no valid Roblox token", metadata: ["user": "\(grant.userID)"])
                continue
            }
            for universe in grant.universeIDs {
                do {
                    let points = try await analytics.hourly(metric: Self.metric, universeID: universe,
                                                            start: start, end: current, accessToken: token)
                    let total = points.filter { $0.0 >= start }.reduce(0) { $0 + max(0, $1.1) }
                    try await store.appendSamples([MetricSample(universeID: universe, metric: .robux, time: time, value: total.rounded())])
                    updated += 1
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    logger.warning("revenue query failed", metadata: ["universe": "\(universe)", "error": "\(error)"])
                }
            }
        }
        return updated
    }
}

/// Runs the shared `AlertEngine` for every enabled rule and pushes on the rising edge.
public struct AlertEvaluator: Sendable {
    let store: any Store
    let push: any PushSender
    let now: @Sendable () -> Date

    public init(store: any Store, push: any PushSender, now: @escaping @Sendable () -> Date) {
        self.store = store
        self.push = push
        self.now = now
    }

    @discardableResult
    public func evaluate(logger: Logger) async throws -> [AlertEvent] {
        let current = now()
        var fired: [AlertEvent] = []
        var ownedUniverses: [UUID: Set<Int64>] = [:]
        for owned in try await store.enabledAlertRules() {
            try Task.checkCancellation()
            let rule = owned.rule
            if ownedUniverses[owned.userID] == nil {
                ownedUniverses[owned.userID] = Set(try await store.grant(userID: owned.userID)?.universeIDs ?? [])
            }
            // Access may have been revoked since the rule was created.
            guard ownedUniverses[owned.userID]?.contains(rule.gameID) == true else { continue }

            var lookback: TimeInterval = 2 * 3_600
            if case .dropFrom(_, let window) = rule.condition { lookback = max(lookback, window + 3_600) }
            let series = try await store.samples(universeID: rule.gameID, metric: rule.metric,
                                                 from: current.addingTimeInterval(-lookback), to: current)
            let previous = try await store.alertState(ruleID: rule.id)
            let (outcome, next) = AlertEngine.evaluate(rule, series: series, state: previous, now: current)
            if next != previous { try await store.saveAlertState(ruleID: rule.id, state: next) }
            guard case .fired(let event) = outcome else { continue }

            try await store.appendAlertEvent(userID: owned.userID, event: event)
            fired.append(event)
            let name = try await store.gameInfo(universeIDs: [rule.gameID])[rule.gameID]?.name ?? "Your game"
            let message = PushMessage(title: name, body: Self.body(for: rule, event: event),
                                      url: Route.game(id: rule.gameID).url, threadID: "game-\(rule.gameID)")
            for device in try await store.devices(userID: owned.userID) {
                if await push.send(message, to: device) == .unregistered {
                    try await store.deleteDevice(token: device.token)
                }
            }
        }
        if fired.isEmpty == false { logger.info("alerts fired", metadata: ["count": "\(fired.count)"]) }
        return fired
    }

    static func body(for rule: AlertRule, event: AlertEvent) -> String {
        let value = MetricFormatter.compact(event.value)
        let metric = switch rule.metric {
        case .ccu: "players"
        case .visits: "visits"
        case .favourites: "favourites"
        case .robux: "Robux"
        }
        switch rule.condition {
        case .above(let threshold): return "\(value) \(metric): above \(MetricFormatter.compact(threshold))"
        case .below(let threshold): return "\(value) \(metric): below \(MetricFormatter.compact(threshold))"
        case .dropFrom(let fraction, _):
            return "\(metric.capitalized) dropped \(Int((fraction * 100).rounded()))%+ to \(value)"
        }
    }
}

/// Runs `job` every `interval` until graceful shutdown. Errors are logged, never fatal.
public struct PeriodicService: Service {
    let name: String
    let interval: Duration
    let logger: Logger
    let job: @Sendable (Logger) async throws -> Void

    public init(name: String, interval: Duration, logger: Logger, job: @escaping @Sendable (Logger) async throws -> Void) {
        self.name = name
        self.interval = interval
        self.logger = logger
        self.job = job
    }

    public func run() async throws {
        let logger = self.logger
        let name = self.name, interval = self.interval, job = self.job
        try? await cancelWhenGracefulShutdown {
            while Task.isCancelled == false {
                do {
                    try await job(logger)
                } catch is CancellationError {
                    return
                } catch {
                    logger.error("\(name) failed", metadata: ["error": "\(error)"])
                }
                try await Task.sleep(for: interval)
            }
        }
    }
}
