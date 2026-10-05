import Foundation

/// The cached data widgets and Live Activities render. Written by the app after each refresh,
/// read by the widget extension. Widgets never fetch from the network themselves.
public struct WidgetSnapshot: Hashable, Codable, Sendable {
    /// Bump when the shape changes. Older snapshots fail to decode and widgets show a placeholder
    /// until the app writes a fresh one.
    public static let currentVersion = 1
    public static let sparklinePoints = 24

    public struct GameEntry: Identifiable, Hashable, Codable, Sendable {
        public var id: Int64
        public var name: String
        public var ccu: Int
        public var ccuChange: Double?
        public var robux24h: Int64?
        public var isFavourite: Bool
        public var sparkline: [Double]
        public var updatedAt: Date
    }

    public struct GoalEntry: Identifiable, Hashable, Codable, Sendable {
        public var id: UUID
        public var title: String
        public var progress: Double
        public var status: GoalStatus
    }

    public var version: Int
    public var generatedAt: Date
    public var games: [GameEntry]
    public var goals: [GoalEntry]

    public init(version: Int = WidgetSnapshot.currentVersion, generatedAt: Date,
                games: [GameEntry], goals: [GoalEntry]) {
        self.version = version
        self.generatedAt = generatedAt
        self.games = games
        self.goals = goals
    }

    /// Builds a snapshot from dashboard data. Favourites come first, then by CCU.
    public static func make(
        games: [Game],
        ccuHistory: [Int64: MetricSeries],
        goals: [Goal],
        now: Date
    ) -> WidgetSnapshot {
        let gameEntries = games
            .sorted { lhs, rhs in
                if lhs.isFavourite != rhs.isFavourite { return lhs.isFavourite }
                if lhs.stats.ccu != rhs.stats.ccu { return lhs.stats.ccu > rhs.stats.ccu }
                return lhs.id < rhs.id
            }
            .map { game in
                GameEntry(
                    id: game.id,
                    name: game.name,
                    ccu: game.stats.ccu,
                    ccuChange: game.stats.ccuChange,
                    robux24h: game.stats.robux24h,
                    isFavourite: game.isFavourite,
                    sparkline: ccuHistory[game.id]?.downsampled(to: sparklinePoints).map(\.value) ?? [],
                    updatedAt: game.stats.updatedAt
                )
            }

        let currentValues = Dictionary(games.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let goalEntries = goals.map { goal in
            let current = goal.gameID.flatMap { currentValues[$0] }.map { value(of: goal.metric, in: $0.stats) }
            let evaluation = GoalEngine.evaluate(goal, currentValue: current ?? goal.startValue, now: now)
            return GoalEntry(id: goal.id, title: goal.title, progress: evaluation.progress, status: evaluation.status)
        }

        return WidgetSnapshot(generatedAt: now, games: gameEntries, goals: goalEntries)
    }

    public func game(id: Int64) -> GameEntry? { games.first { $0.id == id } }

    /// The game a widget shows when the user hasn't picked one.
    public var defaultGame: GameEntry? { games.first }

    /// Current value of `metric` for a game, used to evaluate goals.
    public static func value(of metric: Metric, in stats: GameStats) -> Double {
        switch metric {
        case .ccu: Double(stats.ccu)
        case .visits: Double(stats.visits)
        case .favourites: Double(stats.favourites)
        case .robux: Double(stats.robux24h ?? 0)
        }
    }
}

/// Reads and writes the snapshot file in the shared App Group container.
public struct SnapshotStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Store in the App Group container, or `nil` when the group isn't available (unsigned
    /// simulator builds, misconfigured entitlements). Callers must cope with `nil`.
    public init?(appGroup: String, fileManager: FileManager = .default) {
        #if os(Linux)
        return nil
        #else
        guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            return nil
        }
        self.init(fileURL: container.appendingPathComponent("widget-snapshot.json"))
        #endif
    }

    public func save(_ snapshot: WidgetSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(snapshot)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Atomic so the widget never reads a half-written file.
        try data.write(to: fileURL, options: .atomic)
    }

    /// The stored snapshot, or `nil` when missing, unreadable or from another schema version.
    public func load() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data),
              snapshot.version == WidgetSnapshot.currentVersion else { return nil }
        return snapshot
    }
}

/// Identifiers shared by the app and its extensions.
public enum SharedConfiguration {
    public static let appGroup = "group.com.rbxpulse.shared"
    /// WidgetKit `kind` strings. Changing one orphans users' installed widgets.
    public static let favouriteGameWidgetKind = "FavouriteGameWidget"
    public static let goalsWidgetKind = "GoalsWidget"
}
