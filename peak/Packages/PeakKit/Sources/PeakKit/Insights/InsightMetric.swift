import Foundation

/// The metrics the insight engines reason about. Wider than `Metric` (which is what the dashboard
/// charts), because insights also use Roblox Analytics data such as retention and crash rate.
public enum InsightMetric: String, Hashable, Codable, Sendable, CaseIterable {
    case ccu
    case revenue
    case d1Retention
    case d7Retention
    case sessionLength
    case revenuePerPlayer
    case payerConversion
    case newPlayerCompletion
    case crashRate
    case serverCrashes
    case dataStoreErrors
    case visits
    case favourites

    public enum Unit: String, Hashable, Codable, Sendable {
        /// Players, visits, favourites, errors.
        case count
        case robux
        /// A fraction 0...1, shown as a percentage.
        case fraction
        case minutes
    }

    /// Whether a higher value is good news. Drives "improved" vs "harmed" and alert wording.
    public var higherIsBetter: Bool {
        switch self {
        case .crashRate, .serverCrashes, .dataStoreErrors: false
        default: true
        }
    }

    public var unit: Unit {
        switch self {
        case .ccu, .serverCrashes, .dataStoreErrors, .visits, .favourites: .count
        case .revenue, .revenuePerPlayer: .robux
        case .d1Retention, .d7Retention, .payerConversion, .newPlayerCompletion, .crashRate: .fraction
        case .sessionLength: .minutes
        }
    }

    public var displayName: String {
        switch self {
        case .ccu: "CCU"
        case .revenue: "Revenue"
        case .d1Retention: "D1 retention"
        case .d7Retention: "D7 retention"
        case .sessionLength: "Session length"
        case .revenuePerPlayer: "Revenue per player"
        case .payerConversion: "Payer conversion"
        case .newPlayerCompletion: "First-session completion"
        case .crashRate: "Crash rate"
        case .serverCrashes: "Server crashes"
        case .dataStoreErrors: "DataStore errors"
        case .visits: "Visits"
        case .favourites: "Favourites"
        }
    }

    /// Below this expected value a change is noise, not news (a game with 3 players going to 1 is not a
    /// "67% CCU collapse"). Units match `unit`.
    public var minimumVolume: Double {
        switch self {
        case .ccu: 20
        case .revenue: 100
        case .revenuePerPlayer: 0.1
        case .visits: 200
        case .favourites: 50
        case .serverCrashes, .dataStoreErrors: 5
        case .sessionLength: 0.5
        case .d1Retention, .d7Retention, .payerConversion, .newPlayerCompletion: 0.005
        case .crashRate: 0.001
        }
    }

    /// Analysis order when several metrics move together: the first is the headline.
    public var priority: Int {
        switch self {
        case .ccu: 0
        case .revenue: 1
        case .crashRate: 2
        case .serverCrashes: 3
        case .dataStoreErrors: 4
        case .d1Retention: 5
        case .newPlayerCompletion: 6
        case .d7Retention: 7
        case .sessionLength: 8
        case .revenuePerPlayer: 9
        case .payerConversion: 10
        case .visits: 11
        case .favourites: 12
        }
    }
}

public extension Metric {
    /// The insight vocabulary equivalent of a dashboard metric.
    var insightMetric: InsightMetric {
        switch self {
        case .ccu: .ccu
        case .visits: .visits
        case .favourites: .favourites
        case .robux: .revenue
        }
    }
}
