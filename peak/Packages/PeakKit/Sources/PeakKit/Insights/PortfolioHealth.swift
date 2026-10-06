import Foundation

public struct GameHealthInput: Hashable, Codable, Sendable {
    public var gameID: Int64
    public var name: String
    /// CCU change vs the same time last week (0.1 == +10%).
    public var ccuChange7d: Double?
    /// Revenue change, last 7 days vs the 7 before.
    public var revenueChange7d: Double?
    public var d1Retention: Double?
    public var crashRate: Double?
    /// Bad-news anomalies in the last 24 hours.
    public var openIssues: Int
    public var daysSinceUpdate: Int?

    public init(gameID: Int64, name: String, ccuChange7d: Double? = nil, revenueChange7d: Double? = nil,
                d1Retention: Double? = nil, crashRate: Double? = nil, openIssues: Int = 0, daysSinceUpdate: Int? = nil) {
        self.gameID = gameID
        self.name = name
        self.ccuChange7d = ccuChange7d
        self.revenueChange7d = revenueChange7d
        self.d1Retention = d1Retention
        self.crashRate = crashRate
        self.openIssues = openIssues
        self.daysSinceUpdate = daysSinceUpdate
    }
}

public struct GameHealth: Hashable, Codable, Sendable, Identifiable {
    public struct Components: Hashable, Codable, Sendable {
        /// 0...25
        public var growth: Double
        /// 0...20
        public var earnings: Double
        /// 0...25
        public var retention: Double
        /// 0...30
        public var stability: Double
    }

    public var gameID: Int64
    public var name: String
    /// 0...100
    public var score: Int
    public var components: Components
    public var needsUpdate: Bool
    public var headline: String

    public var id: Int64 { gameID }
}

/// Ranks games by growth, earnings, retention and stability so the creator can see where attention pays.
/// Missing data scores as neutral (half marks), never as zero, so a game isn't punished for a scope the
/// creator didn't grant.
public enum PortfolioHealth {
    public static let staleUpdateDays = 30

    public static func rank(_ games: [GameHealthInput]) -> [GameHealth] {
        games.map(score).sorted { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.name < rhs.name
        }
    }

    public static func score(_ input: GameHealthInput) -> GameHealth {
        let growth = scaled(input.ccuChange7d, from: -0.5, to: 0.5, max: 25)
        let earnings = scaled(input.revenueChange7d, from: -0.5, to: 0.5, max: 20)
        let retention = scaled(input.d1Retention, from: 0, to: 0.4, max: 25)
        var stability = 30.0
        if let crashRate = input.crashRate, crashRate.isFinite {
            // Each 0.1% crash rate costs a point, capped at 20.
            stability -= min(20, max(0, crashRate) * 1_000)
        }
        stability -= Double(min(2, max(0, input.openIssues))) * 5
        stability = max(0, stability)

        let components = GameHealth.Components(growth: growth, earnings: earnings, retention: retention, stability: stability)
        let total = Int((growth + earnings + retention + stability).rounded())
        let stale = (input.daysSinceUpdate ?? 0) > staleUpdateDays
        let needsUpdate = stale || stability < 15
        return GameHealth(gameID: input.gameID, name: input.name, score: min(100, max(0, total)),
                          components: components, needsUpdate: needsUpdate,
                          headline: headline(components, stale: stale, daysSinceUpdate: input.daysSinceUpdate))
    }

    /// Linear map of `value` from `low...high` onto `0...max`; `nil` maps to the midpoint.
    static func scaled(_ value: Double?, from low: Double, to high: Double, max maximum: Double) -> Double {
        guard let value, value.isFinite else { return maximum / 2 }
        let fraction = (value - low) / (high - low)
        return min(1, Swift.max(0, fraction)) * maximum
    }

    static func headline(_ components: GameHealth.Components, stale: Bool, daysSinceUpdate: Int?) -> String {
        let parts: [(name: String, share: Double)] = [
            ("growth", components.growth / 25),
            ("earnings", components.earnings / 20),
            ("retention", components.retention / 25),
            ("stability", components.stability / 30),
        ]
        let strongest = parts.max { $0.share < $1.share }!
        let weakest = parts.min { $0.share < $1.share }!
        var text: String
        if weakest.share >= 0.6 {
            text = "Healthy across the board."
        } else if strongest.share - weakest.share < 0.15 {
            text = "Needs work across the board."
        } else {
            text = "Strong \(strongest.name), weak \(weakest.name)."
        }
        if stale, let daysSinceUpdate {
            text += " No update for \(daysSinceUpdate) days."
        }
        return text
    }
}
