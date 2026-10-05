import Foundation
import RBXPulseKit

/// Assembles API responses from stored data. Every query is scoped to universes the user granted
/// through Roblox OAuth (`token/resources`), so one creator can never read another's games.
public struct DashboardBuilder: Sendable {
    /// CCU older than this isn't shown as current (the poller runs every minute).
    public static let ccuMaxAge: TimeInterval = 15 * 60
    /// Revenue is polled every 15 minutes.
    public static let revenueMaxAge: TimeInterval = 2 * 3_600

    private let store: any Store
    private let now: @Sendable () -> Date

    public init(store: any Store, now: @escaping @Sendable () -> Date) {
        self.store = store
        self.now = now
    }

    /// Universes the user may access. No grant → the creator must reconnect Roblox.
    public func ownedUniverses(userID: UUID) async throws -> [Int64] {
        guard let grant = try await store.grant(userID: userID) else { throw APIFailure.reconnectRequired }
        return grant.universeIDs
    }

    public func requireOwnership(userID: UUID, universeID: Int64) async throws {
        guard try await ownedUniverses(userID: userID).contains(universeID) else { throw APIFailure.notFound }
    }

    public func dashboard(userID: UUID) async throws -> Dashboard {
        let current = now()
        let universes = try await ownedUniverses(userID: userID)
        let infos = try await store.gameInfo(universeIDs: universes)
        let flags = try await store.flags(userID: userID)
        let ccu = try await store.latestSample(universeIDs: universes, metric: .ccu, atOrBefore: current)
        let ccuYesterday = try await store.latestSample(universeIDs: universes, metric: .ccu,
                                                        atOrBefore: current.addingTimeInterval(-86_400))
        let visits = try await store.latestSample(universeIDs: universes, metric: .visits, atOrBefore: current)
        let favourites = try await store.latestSample(universeIDs: universes, metric: .favourites, atOrBefore: current)
        let robux = try await store.latestSample(universeIDs: universes, metric: .robux, atOrBefore: current)

        var games: [Game] = []
        var sparklines: [String: MetricSeries] = [:]
        for universe in universes {
            let info = infos[universe]
            let latestCCU = ccu[universe].flatMap { current.timeIntervalSince($0.date) <= Self.ccuMaxAge ? $0 : nil }
            // Yesterday's value only counts if it was sampled within an hour of "24 h ago".
            let yesterday = ccuYesterday[universe].flatMap {
                current.addingTimeInterval(-86_400).timeIntervalSince($0.date) <= 3_600 ? Int($0.value) : nil
            }
            let revenue = robux[universe].flatMap {
                current.timeIntervalSince($0.date) <= Self.revenueMaxAge ? Int64($0.value) : nil
            }
            let stats = GameStats(
                ccu: Int(latestCCU?.value ?? 0),
                ccuYesterday: yesterday,
                visits: Int64(visits[universe]?.value ?? 0),
                favourites: Int64(favourites[universe]?.value ?? 0),
                robux24h: revenue,
                updatedAt: latestCCU?.date ?? ccu[universe]?.date ?? info?.updatedAt ?? current
            )
            let flag = flags[universe] ?? GameFlags()
            games.append(Game(id: universe, rootPlaceID: info?.rootPlaceID ?? 0,
                              name: info?.name ?? "Experience \(universe)",
                              isFavourite: flag.isFavourite, isWorkingOn: flag.isWorkingOn, stats: stats))

            let history = try await store.samples(universeID: universe, metric: .ccu,
                                                  from: current.addingTimeInterval(-86_400), to: current)
            if history.isEmpty == false {
                let series = MetricSeries(metric: .ccu, points: history)
                sparklines[String(universe)] = MetricSeries(metric: .ccu, points: series.downsampled(to: 24))
            }
        }

        return Dashboard(
            games: games,
            goals: try await store.goals(userID: userID),
            // Roblox exposes no ads/campaign API to OAuth apps yet; the app shows its empty state.
            campaigns: [],
            recentAlerts: try await store.recentAlertEvents(userID: userID, limit: 20),
            ccuSparklines: sparklines,
            generatedAt: current
        )
    }

    public func series(userID: UUID, universeID: Int64, metric: Metric, range: TimeRange) async throws -> MetricSeries {
        try await requireOwnership(userID: userID, universeID: universeID)
        let current = now()
        let points = try await store.samples(universeID: universeID, metric: metric,
                                             from: current.addingTimeInterval(-range.duration), to: current)
        return MetricSeries(metric: metric, points: MetricSeries(metric: metric, points: points).downsampled(to: 300))
    }
}

/// Input validation for user-supplied alert rules (roblox-security: validate every argument server-side).
enum AlertRuleValidator {
    static let maxRulesPerUser = 50

    static func validate(_ rule: AlertRule) throws {
        let minute: TimeInterval = 60, week: TimeInterval = 7 * 86_400
        guard (minute...week).contains(rule.cooldown) else { throw APIFailure.badRequest("invalid_cooldown") }
        switch rule.condition {
        case .above(let threshold), .below(let threshold):
            guard threshold.isFinite, threshold >= 0, threshold < 1e15 else { throw APIFailure.badRequest("invalid_threshold") }
        case .dropFrom(let fraction, let window):
            guard fraction.isFinite, fraction > 0, fraction <= 1 else { throw APIFailure.badRequest("invalid_fraction") }
            guard (minute...week).contains(window) else { throw APIFailure.badRequest("invalid_window") }
        }
    }
}
