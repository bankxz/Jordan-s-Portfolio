import Foundation

public struct AlertRule: Identifiable, Hashable, Codable, Sendable {
    public enum Condition: Hashable, Codable, Sendable {
        /// Latest value strictly above the threshold.
        case above(Double)
        /// Latest value strictly below the threshold.
        case below(Double)
        /// Latest value has fallen by at least `fraction` (0.3 == 30%) from the highest value
        /// seen within `window` seconds before it.
        case dropFrom(fraction: Double, window: TimeInterval)
    }

    public let id: UUID
    public var gameID: Int64
    public var metric: Metric
    public var condition: Condition
    /// Minimum time between two notifications for this rule.
    public var cooldown: TimeInterval
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        gameID: Int64,
        metric: Metric,
        condition: Condition,
        cooldown: TimeInterval = 30 * 60,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.gameID = gameID
        self.metric = metric
        self.condition = condition
        self.cooldown = cooldown
        self.isEnabled = isEnabled
    }
}

/// Per-rule memory between evaluations. Persisted by whoever runs the engine (the backend).
public struct AlertRuleState: Hashable, Codable, Sendable {
    /// Whether the condition held at the previous evaluation. Alerts fire on the rising edge only,
    /// so a game that stays above a threshold for hours notifies once, not every poll.
    public var conditionWasMet: Bool
    public var lastFiredAt: Date?

    public init(conditionWasMet: Bool = false, lastFiredAt: Date? = nil) {
        self.conditionWasMet = conditionWasMet
        self.lastFiredAt = lastFiredAt
    }
}

public struct AlertEvent: Hashable, Codable, Sendable {
    public var ruleID: UUID
    public var gameID: Int64
    public var metric: Metric
    public var value: Double
    public var firedAt: Date
}

public enum AlertOutcome: Hashable, Sendable {
    case fired(AlertEvent)
    /// The condition holds, but the rule already fired for this episode or is cooling down.
    case suppressed
    case conditionNotMet
    /// The latest sample is too old to act on. State is left untouched.
    case staleData
    case noData
    case disabled
}

/// Pure, deterministic alert evaluation. Runs on the backend for push notifications and in the
/// app to preview a rule against recent history.
public enum AlertEngine {
    /// Samples older than this are not acted upon, so an outage doesn't produce a burst of alerts
    /// about something that happened an hour ago.
    public static let maxSampleAge: TimeInterval = 15 * 60

    public static func evaluate(
        _ rule: AlertRule,
        series: [MetricPoint],
        state: AlertRuleState,
        now: Date
    ) -> (outcome: AlertOutcome, state: AlertRuleState) {
        guard rule.isEnabled else { return (.disabled, AlertRuleState()) }
        let points = series.sorted { $0.date < $1.date }
        guard let latest = points.last else { return (.noData, state) }
        guard now.timeIntervalSince(latest.date) <= maxSampleAge else { return (.staleData, state) }

        let met = conditionMet(rule.condition, latest: latest, points: points)
        var next = state
        next.conditionWasMet = met

        guard met else { return (.conditionNotMet, next) }
        guard state.conditionWasMet == false else { return (.suppressed, next) }
        if let lastFiredAt = state.lastFiredAt, now.timeIntervalSince(lastFiredAt) < rule.cooldown {
            return (.suppressed, next)
        }

        next.lastFiredAt = now
        let event = AlertEvent(ruleID: rule.id, gameID: rule.gameID, metric: rule.metric,
                               value: latest.value, firedAt: now)
        return (.fired(event), next)
    }

    static func conditionMet(_ condition: AlertRule.Condition, latest: MetricPoint,
                             points: [MetricPoint]) -> Bool {
        switch condition {
        case .above(let threshold):
            return latest.value > threshold
        case .below(let threshold):
            return latest.value < threshold
        case .dropFrom(let fraction, let window):
            guard fraction > 0, window > 0 else { return false }
            let windowStart = latest.date.addingTimeInterval(-window)
            let reference = points
                .filter { $0.date >= windowStart && $0.date < latest.date }
                .map(\.value)
                .max()
            guard let reference, reference > 0 else { return false }
            return (reference - latest.value) / reference >= fraction
        }
    }
}
