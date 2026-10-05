import Foundation

/// Deterministic sample data for previews, UI tests and demo mode. Includes deliberate edge cases
/// (very long name, zero CCU, huge numbers, no revenue access) so they show up during visual QA.
public enum SampleData {
    public struct GameSeed: Sendable {
        public var id: Int64
        public var name: String
        public var baseCCU: Double
        public var visits: Int64
        public var favourites: Int64
        public var robux24h: Int64?
        public var isFavourite: Bool
        public var isWorkingOn: Bool
    }

    public static let seeds: [GameSeed] = [
        GameSeed(id: 920_587_237, name: "Attack Animals", baseCCU: 4_820, visits: 48_300_000,
                 favourites: 312_000, robux24h: 182_400, isFavourite: true, isWorkingOn: true),
        GameSeed(id: 735_030_788, name: "Obby Rush", baseCCU: 1_240, visits: 9_870_000,
                 favourites: 88_100, robux24h: 21_050, isFavourite: true, isWorkingOn: false),
        GameSeed(id: 606_849_621, name: "Pet Café Tycoon", baseCCU: 312, visits: 1_204_000,
                 favourites: 15_700, robux24h: 3_480, isFavourite: false, isWorkingOn: false),
        GameSeed(id: 4_924_922_222, name: "Sky Racers: Ultimate Championship Edition — Season 4 Extended Remix",
                 baseCCU: 2_150_000, visits: 12_400_000_000, favourites: 98_000_000, robux24h: 41_200_000,
                 isFavourite: false, isWorkingOn: false),
        GameSeed(id: 189_707, name: "Neon Brawl (beta)", baseCCU: 0, visits: 2_310,
                 favourites: 41, robux24h: nil, isFavourite: false, isWorkingOn: true),
    ]

    /// CCU history ending at `end`, one point every `step` seconds.
    public static func ccuSeries(for seed: GameSeed, end: Date, duration: TimeInterval,
                                 step: TimeInterval) -> MetricSeries {
        guard seed.baseCCU > 0, duration > 0, step > 0 else {
            return MetricSeries(metric: .ccu, points: [MetricPoint(date: end, value: 0)])
        }
        var generator = SeededGenerator(seed: UInt64(truncatingIfNeeded: seed.id))
        let count = Int(duration / step)
        var points: [MetricPoint] = []
        points.reserveCapacity(count + 1)
        for index in 0...count {
            let date = end.addingTimeInterval(-Double(count - index) * step)
            let hour = (date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400)) / 3_600
            // Daily cycle peaking around 20:00 UTC, slight upward trend, ±6% noise.
            let daily = 1 + 0.35 * sin((hour - 14) / 24 * 2 * .pi)
            let trend = 0.9 + 0.1 * Double(index) / Double(max(count, 1))
            let noise = 1 + (generator.nextUnit() - 0.5) * 0.12
            points.append(MetricPoint(date: date, value: (seed.baseCCU * daily * trend * noise).rounded()))
        }
        return MetricSeries(metric: .ccu, points: points)
    }

    public static func games(now: Date) -> [Game] {
        seeds.map { seed in
            let series = ccuSeries(for: seed, end: now, duration: 86_400, step: 3_600)
            let current = Int(series.latest?.value ?? 0)
            let yesterday = series.points.first.map { Int($0.value) }
            return Game(
                id: seed.id,
                rootPlaceID: seed.id + 1,
                name: seed.name,
                isFavourite: seed.isFavourite,
                isWorkingOn: seed.isWorkingOn,
                stats: GameStats(ccu: current, ccuYesterday: yesterday, visits: seed.visits,
                                 favourites: seed.favourites, robux24h: seed.robux24h,
                                 updatedAt: now.addingTimeInterval(-90))
            )
        }
    }

    public static func goals(now: Date) -> [Goal] {
        [
            Goal(id: UUID(uuidString: "11111111-2222-3333-4444-555555555501")!,
                 title: "Hit 6K CCU on Attack Animals", gameID: 920_587_237, metric: .ccu,
                 startValue: 3_000, targetValue: 6_000, createdAt: now.addingTimeInterval(-20 * 86_400),
                 deadline: now.addingTimeInterval(10 * 86_400),
                 tasks: [GoalTask(id: UUID(uuidString: "22222222-3333-4444-5555-666666666601")!, title: "Ship pet evolution update", isDone: true),
                         GoalTask(id: UUID(uuidString: "22222222-3333-4444-5555-666666666602")!, title: "Run weekend sponsored ad", isDone: true),
                         GoalTask(id: UUID(uuidString: "22222222-3333-4444-5555-666666666603")!, title: "Add daily login streak")]),
            Goal(id: UUID(uuidString: "11111111-2222-3333-4444-555555555502")!,
                 title: "100K favourites on Obby Rush", gameID: 735_030_788, metric: .favourites,
                 startValue: 60_000, targetValue: 100_000, createdAt: now.addingTimeInterval(-30 * 86_400),
                 deadline: now.addingTimeInterval(5 * 86_400)),
            Goal(id: UUID(uuidString: "11111111-2222-3333-4444-555555555503")!,
                 title: "First 100 players in Neon Brawl", gameID: 189_707, metric: .ccu,
                 startValue: 0, targetValue: 100, createdAt: now.addingTimeInterval(-3 * 86_400)),
        ]
    }

    public static func campaigns() -> [Campaign] {
        [
            Campaign(id: "spring-launch", name: "Spring launch", gameID: 920_587_237, status: .running,
                     spentRobux: 42_000, budgetRobux: 60_000, impressions: 3_200_000, clicks: 41_600, plays: 18_900),
            Campaign(id: "obby-weekend", name: "Weekend boost", gameID: 735_030_788, status: .completed,
                     spentRobux: 8_000, budgetRobux: 8_000, impressions: 610_000, clicks: 5_490, plays: 2_020),
            Campaign(id: "neon-teaser", name: "Teaser (scheduled)", gameID: 189_707, status: .scheduled,
                     spentRobux: 0, budgetRobux: 5_000, impressions: 0, clicks: 0, plays: 0),
        ]
    }

    public static func dashboard(now: Date) -> Dashboard {
        var sparklines: [String: MetricSeries] = [:]
        for seed in seeds {
            sparklines[String(seed.id)] = ccuSeries(for: seed, end: now, duration: 86_400, step: 3_600)
        }
        let alert = AlertEvent(ruleID: UUID(uuidString: "11111111-2222-3333-4444-555555555599")!,
                               gameID: 920_587_237, metric: .ccu, value: 5_012,
                               firedAt: now.addingTimeInterval(-25 * 60))
        return Dashboard(games: games(now: now), goals: goals(now: now), campaigns: campaigns(),
                         recentAlerts: [alert], ccuSparklines: sparklines, generatedAt: now)
    }
}

/// Small deterministic PRNG (SplitMix64) so sample data is identical on every run and platform.
struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}

/// Serves sample data, keeping favourite/working-on edits in memory. Used when no backend URL is
/// configured, in SwiftUI previews and in UI tests.
public actor DemoDashboardService: DashboardService {
    public enum Mode: Sendable {
        case normal
        /// No games: exercises empty states.
        case empty
        /// Every call fails: exercises error states.
        case failing
    }

    private let mode: Mode
    private let now: @Sendable () -> Date
    private var favourites: [Int64: Bool] = [:]
    private var workingOn: [Int64: Bool] = [:]

    public struct DemoFailure: Error, Hashable {}

    public init(mode: Mode = .normal, now: @escaping @Sendable () -> Date = { Date() }) {
        self.mode = mode
        self.now = now
    }

    public func dashboard() async throws -> Dashboard {
        switch mode {
        case .failing:
            throw DemoFailure()
        case .empty:
            return Dashboard(games: [], goals: [], campaigns: [], recentAlerts: [], ccuSparklines: [:],
                             generatedAt: now())
        case .normal:
            var dashboard = SampleData.dashboard(now: now())
            for index in dashboard.games.indices {
                let id = dashboard.games[index].id
                if let value = favourites[id] { dashboard.games[index].isFavourite = value }
                if let value = workingOn[id] { dashboard.games[index].isWorkingOn = value }
            }
            return dashboard
        }
    }

    public func series(gameID: Int64, metric: Metric, range: TimeRange) async throws -> MetricSeries {
        guard mode != .failing else { throw DemoFailure() }
        guard let seed = SampleData.seeds.first(where: { $0.id == gameID }) else {
            return MetricSeries(metric: metric, points: [])
        }
        let step: TimeInterval = switch range {
        case .day: 15 * 60
        case .week: 2 * 3_600
        case .month: 6 * 3_600
        }
        return SampleData.ccuSeries(for: seed, end: now(), duration: range.duration, step: step)
    }

    public func setFavourite(gameID: Int64, isFavourite: Bool) async throws {
        guard mode != .failing else { throw DemoFailure() }
        favourites[gameID] = isFavourite
    }

    public func setWorkingOn(gameID: Int64, isWorkingOn: Bool) async throws {
        guard mode != .failing else { throw DemoFailure() }
        workingOn[gameID] = isWorkingOn
    }
}
