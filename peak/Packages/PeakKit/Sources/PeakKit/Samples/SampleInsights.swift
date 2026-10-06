import Foundation

/// Sample insights built by the real engines from synthetic data, so demo mode, previews and UI tests show
/// exactly what the engines produce.
public extension SampleData {
    static let attackAnimalsID: Int64 = 920_587_237
    static let obbyRushID: Int64 = 735_030_788

    static func updateDate(now: Date) -> Date { now.addingTimeInterval(-4 * 86_400 - 3 * 3_600) }

    static func timeline(now: Date) -> [TimelineEvent] {
        [
            TimelineEvent(kind: .update, gameID: attackAnimalsID, date: updateDate(now: now), detail: "v128"),
            TimelineEvent(kind: .update, gameID: attackAnimalsID, date: now.addingTimeInterval(-3 * 3_600), detail: "v129"),
            TimelineEvent(kind: .campaignStarted, gameID: obbyRushID, date: now.addingTimeInterval(-5 * 3_600), detail: "Weekend boost"),
        ]
    }

    static func anomalies(now: Date) -> [Anomaly] {
        [
            Anomaly(gameID: attackAnimalsID, metric: .ccu, direction: .drop, actual: 3_660, expected: 4_820, change: -0.24,
                    severity: .medium, detectedAt: now.addingTimeInterval(-20 * 60), baseline: .sameTimePreviousWeeks),
            Anomaly(gameID: attackAnimalsID, metric: .newPlayerCompletion, direction: .drop, actual: 0.44, expected: 0.5,
                    change: -0.12, severity: .low, detectedAt: now.addingTimeInterval(-35 * 60), baseline: .sameTimePreviousDays),
            Anomaly(gameID: obbyRushID, metric: .revenue, direction: .spike, actual: 29_050, expected: 21_050, change: 0.38,
                    severity: .medium, detectedAt: now.addingTimeInterval(-2 * 3_600), baseline: .sameTimePreviousWeeks),
        ]
    }

    static func alertDigests(now: Date) -> [AlertDigest] {
        let anomalies = anomalies(now: now)
        return AlertPrioritizer.digests(
            anomalies: anomalies,
            gameNames: Dictionary(seeds.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
            breakdowns: [anomalies[0].id: [DimensionChange(dimension: "Mobile", change: -0.31),
                                           DimensionChange(dimension: "Desktop", change: -0.06)]],
            events: timeline(now: now))
    }

    /// Daily D1 retention, session length and crash rate around update v128 on Attack Animals.
    static func updateImpact(now: Date) -> UpdateImpactReport {
        let update = updateDate(now: now)
        func daily(_ before: [Double], _ after: [Double]) -> [MetricPoint] {
            before.enumerated().map { MetricPoint(date: update.addingTimeInterval(-Double(before.count - $0.offset) * 86_400), value: $0.element) }
                + after.enumerated().map { MetricPoint(date: update.addingTimeInterval(Double($0.offset + 1) * 86_400), value: $0.element) }
        }
        return UpdateImpactAnalyzer.analyze(
            gameID: attackAnimalsID, updateLabel: "v128", updateDate: update,
            series: [
                .ccu: daily([4_510, 4_620, 4_580, 4_700, 4_650, 4_790, 4_720], [4_880, 4_950, 4_910, 5_010]),
                .d1Retention: daily([0.181, 0.179, 0.184, 0.180, 0.182, 0.178, 0.183], [0.204, 0.209, 0.206, 0.211]),
                .sessionLength: daily([11.8, 12.1, 11.9, 12.0, 12.2, 11.9, 12.0], [13.4, 13.1, 13.6, 13.2]),
                .crashRate: daily([0.008, 0.009, 0.008, 0.008, 0.009, 0.008, 0.008], [0.009, 0.008, 0.009, 0.008]),
                .revenuePerPlayer: daily([2.1, 2.2, 2.0, 2.1, 2.2, 2.1, 2.1], [2.1, 2.2, 2.1, 2.0]),
            ],
            events: timeline(now: now))
    }

    /// The example funnel from the AI spec: Join → Tutorial → First Egg → First Hatch → Upgrade → Zone 2.
    static func funnels(gameID: Int64, now: Date) -> [NamedFunnel] {
        guard gameID == attackAnimalsID else { return [] }
        return [NamedFunnel(name: "Onboarding", steps: [
            FunnelStep(name: "Join", players: 12_400, previousPlayers: 11_900),
            FunnelStep(name: "Tutorial", players: 10_100, previousPlayers: 9_800),
            FunnelStep(name: "First Egg", players: 6_200, previousPlayers: 7_100),
            FunnelStep(name: "First Hatch", players: 5_700, previousPlayers: 6_400),
            FunnelStep(name: "Upgrade", players: 3_300, previousPlayers: 3_600),
            FunnelStep(name: "Zone 2", players: 2_150, previousPlayers: 2_300),
        ], periodEnd: Calendar.utc.startOfDay(for: now))]
    }

    /// What the in-game reporter would collect for Attack Animals: one bug new in v128, one older one.
    static func errorClusters(gameID: Int64, now: Date) -> [ErrorCluster] {
        guard gameID == attackAnimalsID else { return [] }
        let update = updateDate(now: now)
        let messages = [
            "ServerScriptService.Pets:42: attempt to index nil with 'Level' (Players.Alice.Backpack)",
            "DataStore request dropped for key 7f3c2a10-1b2c-4d5e-8f90-123456789abc",
            "Players.bob_99.PlayerGui.ShopUI.Buy:18: attempt to perform arithmetic on nil",
        ]
        func count(_ message: Int, _ source: String, _ version: Int, _ count: Int, from: Date) -> ErrorCount {
            ErrorCount(signature: ErrorClusterer.signature(messages[message]), example: ErrorClusterer.redacted(messages[message]),
                       source: source, placeVersion: version, count: count, firstSeen: from, lastSeen: now.addingTimeInterval(-20 * 60))
        }
        return ErrorClusterer.cluster(counts: [
            count(0, "server", 128, 1_840, from: update.addingTimeInterval(40 * 60)),
            count(1, "server", 127, 160, from: now.addingTimeInterval(-6 * 86_400)),
            count(1, "server", 128, 210, from: update),
            count(2, "client", 127, 90, from: now.addingTimeInterval(-6 * 86_400)),
            count(2, "client", 128, 75, from: update),
        ])
    }

    static func briefing(now: Date) -> Briefing {
        let games = games(now: now)
        let favourites = games.filter(\.isFavourite)
        let goalProgress = goals(now: now).compactMap { goal -> GoalProgress? in
            guard let game = games.first(where: { $0.id == goal.gameID }) else { return nil }
            let current: Double = switch goal.metric {
            case .ccu: Double(game.stats.ccu)
            case .visits: Double(game.stats.visits)
            case .favourites: Double(game.stats.favourites)
            case .robux: Double(game.stats.robux24h ?? 0)
            }
            return GoalProgress(goal: goal, evaluation: GoalEngine.evaluate(goal, currentValue: current, now: now))
        }
        return BriefingBuilder.build(
            games: favourites.map { game in
                BriefingGameInput(game: game,
                                  revenuePrevious24h: game.stats.robux24h.map { Int64(Double($0) * 0.93) },
                                  d1Retention: game.id == attackAnimalsID ? 0.206 : nil,
                                  d1RetentionPrevious: game.id == attackAnimalsID ? 0.182 : nil,
                                  latestUpdate: game.id == attackAnimalsID ? updateImpact(now: now) : nil)
            },
            digests: alertDigests(now: now).filter { digest in favourites.contains { $0.id == digest.gameID } },
            goals: goalProgress,
            campaigns: campaigns(),
            now: now)
    }

    static func portfolio(now: Date) -> [GameHealth] {
        PortfolioHealth.rank([
            GameHealthInput(gameID: attackAnimalsID, name: "Attack Animals", ccuChange7d: 0.06, revenueChange7d: 0.04,
                            d1Retention: 0.206, crashRate: 0.008, openIssues: 1, daysSinceUpdate: 0),
            GameHealthInput(gameID: obbyRushID, name: "Obby Rush", ccuChange7d: 0.18, revenueChange7d: 0.38,
                            d1Retention: 0.24, crashRate: 0.002, daysSinceUpdate: 12),
            GameHealthInput(gameID: 606_849_621, name: "Pet Café Tycoon", ccuChange7d: -0.22, revenueChange7d: -0.15,
                            d1Retention: 0.11, crashRate: 0.014, daysSinceUpdate: 41),
            GameHealthInput(gameID: 189_707, name: "Neon Brawl (beta)", daysSinceUpdate: 2),
        ])
    }
}

/// Insights for demo mode. AI consent is kept in memory; "Ask" answers from the sample briefing.
public actor DemoInsightService: InsightService {
    private let mode: DemoDashboardService.Mode
    private let now: @Sendable () -> Date
    private var consented: Bool
    private var asksUsed = 0
    public static let dailyAskLimit = 20

    public init(mode: DemoDashboardService.Mode = .normal, consented: Bool = false,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.mode = mode
        self.consented = consented
        self.now = now
    }

    private func check() throws {
        if mode == .failing { throw DemoDashboardService.DemoFailure() }
    }

    private var currentSettings: BackendAPI.AISettings {
        BackendAPI.AISettings(available: mode != .failing, consented: consented,
                              asksRemainingToday: max(0, Self.dailyAskLimit - asksUsed), dailyAskLimit: Self.dailyAskLimit,
                              providerName: "Claude (Anthropic)")
    }

    public func settings() async throws -> BackendAPI.AISettings {
        try check()
        return currentSettings
    }

    public func setConsent(_ value: Bool) async throws -> BackendAPI.AISettings {
        try check()
        consented = value
        return currentSettings
    }

    public func briefing() async throws -> Briefing {
        try check()
        if mode == .empty { return BriefingBuilder.build(games: [], now: now()) }
        return SampleData.briefing(now: now())
    }

    public func ask(_ question: String) async throws -> BackendAPI.AskAnswer {
        try check()
        guard consented else { throw APIError.forbidden }
        guard asksUsed < Self.dailyAskLimit else { throw APIError.rateLimited(retryAfter: nil) }
        asksUsed += 1
        let digest = SampleData.alertDigests(now: now()).first
        let answer = digest.map { "\($0.gameName): \($0.message) \($0.causes.first.map { "Possible cause: \($0.evidence)" } ?? "") \($0.suggestedAction)" }
            ?? "Nothing unusual in your games right now."
        return BackendAPI.AskAnswer(answer: answer.replacingOccurrences(of: "  ", with: " "),
                                    sources: ["Sample data (demo mode)"], isAIWritten: false,
                                    asksRemainingToday: Self.dailyAskLimit - asksUsed)
    }

    public func alertDigests() async throws -> [AlertDigest] {
        try check()
        return mode == .empty ? [] : SampleData.alertDigests(now: now())
    }

    public func portfolio() async throws -> [GameHealth] {
        try check()
        return mode == .empty ? [] : SampleData.portfolio(now: now())
    }

    public func funnels(gameID: Int64) async throws -> [NamedFunnel] {
        try check()
        return mode == .normal ? SampleData.funnels(gameID: gameID, now: now()) : []
    }

    public func updateImpact(gameID: Int64) async throws -> UpdateImpactReport? {
        try check()
        guard mode == .normal, gameID == SampleData.attackAnimalsID else { return nil }
        return SampleData.updateImpact(now: now())
    }

    public func errors(gameID: Int64) async throws -> [ErrorCluster] {
        try check()
        return mode == .normal ? SampleData.errorClusters(gameID: gameID, now: now()) : []
    }

    /// A clearly fake key: demo mode never talks to a server.
    public func createErrorKey(gameID: Int64) async throws -> BackendAPI.ErrorReportSetup {
        try check()
        return BackendAPI.ErrorReportSetup(key: "pk_ik_demo_not_a_real_key", secretName: ErrorReporterScripts.secretName,
                                           endpoint: URL(string: "https://peak.example.com/v1/ingest/errors")!)
    }
}
