import Foundation

/// A Roblox ad / sponsored-experience campaign.
public struct Campaign: Identifiable, Hashable, Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case scheduled, running, paused, completed
    }

    public let id: String
    public var name: String
    public var gameID: Int64
    public var status: Status
    public var spentRobux: Int64
    public var budgetRobux: Int64?
    public var impressions: Int64
    public var clicks: Int64
    /// Plays attributed to the campaign.
    public var plays: Int64

    public init(id: String, name: String, gameID: Int64, status: Status, spentRobux: Int64,
                budgetRobux: Int64? = nil, impressions: Int64, clicks: Int64, plays: Int64) {
        self.id = id
        self.name = name
        self.gameID = gameID
        self.status = status
        self.spentRobux = spentRobux
        self.budgetRobux = budgetRobux
        self.impressions = impressions
        self.clicks = clicks
        self.plays = plays
    }

    /// Click-through rate (0...1). `nil` with no impressions.
    public var clickThroughRate: Double? { ratio(clicks, impressions) }

    /// Robux per click. `nil` with no clicks.
    public var costPerClick: Double? { ratio(spentRobux, clicks) }

    /// Robux per 1,000 impressions. `nil` with no impressions.
    public var costPerMille: Double? { ratio(spentRobux, impressions).map { $0 * 1_000 } }

    /// Robux per attributed play. `nil` with no plays.
    public var costPerPlay: Double? { ratio(spentRobux, plays) }

    /// Fraction of budget spent, clamped to 0...1. `nil` without a positive budget.
    public var budgetUsed: Double? {
        guard let budgetRobux, budgetRobux > 0 else { return nil }
        return min(1, max(0, Double(spentRobux) / Double(budgetRobux)))
    }

    private func ratio(_ numerator: Int64, _ denominator: Int64) -> Double? {
        guard denominator > 0, numerator >= 0 else { return nil }
        return Double(numerator) / Double(denominator)
    }
}
