import Foundation

/// Something unusual in one metric of one game.
public struct Anomaly: Identifiable, Hashable, Codable, Sendable {
    public enum Direction: String, Hashable, Codable, Sendable {
        case drop
        case spike
    }

    public enum Severity: Int, Hashable, Codable, Sendable, Comparable {
        case low = 0
        case medium = 1
        case high = 2

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// What "normal" was compared against. Same-time-last-weeks already accounts for weekends and
    /// time of day; the daily fallback doesn't, so weekend effects become a possible cause.
    public enum Baseline: String, Hashable, Codable, Sendable {
        case sameTimePreviousWeeks
        case sameTimePreviousDays
    }

    public var gameID: Int64
    public var metric: InsightMetric
    public var direction: Direction
    public var actual: Double
    public var expected: Double
    /// Fractional change versus expected (-0.24 == 24% below). `nil` when expected was zero.
    public var change: Double?
    public var severity: Severity
    public var detectedAt: Date
    public var baseline: Baseline

    public init(gameID: Int64, metric: InsightMetric, direction: Direction, actual: Double, expected: Double,
                change: Double?, severity: Severity, detectedAt: Date, baseline: Baseline) {
        self.gameID = gameID
        self.metric = metric
        self.direction = direction
        self.actual = actual
        self.expected = expected
        self.change = change
        self.severity = severity
        self.detectedAt = detectedAt
        self.baseline = baseline
    }

    public var id: String { "\(gameID)-\(metric.rawValue)-\(Int(detectedAt.timeIntervalSince1970))" }

    /// A revenue spike is good news; a crash spike is not.
    public var isGoodNews: Bool { (direction == .spike) == metric.higherIsBetter }
}

public enum AnomalyResult: Hashable, Sendable {
    case anomaly(Anomaly)
    case normal(expected: Double)
    /// Not enough comparable history (a new game, or gaps in the data).
    case insufficientData
}

/// Seasonality-aware anomaly detection. The latest value is compared with the same time of day in previous
/// weeks (falling back to previous days), using the median and a robust spread, so Saturday evening is
/// compared with Saturday evenings rather than with a quiet Tuesday morning.
public enum AnomalyDetector {
    public struct Configuration: Hashable, Sendable {
        /// Minimum |change| versus expected to report, e.g. 0.2 == 20%.
        public var minimumChange: Double
        /// Minimum robust z-score to report. Guards against flagging naturally noisy metrics.
        public var minimumScore: Double
        public var weeksBack: Int
        public var daysBack: Int

        public init(minimumChange: Double = 0.2, minimumScore: Double = 3, weeksBack: Int = 4, daysBack: Int = 7) {
            self.minimumChange = minimumChange
            self.minimumScore = minimumScore
            self.weeksBack = weeksBack
            self.daysBack = daysBack
        }
    }

    static let week: TimeInterval = 7 * 86_400
    static let day: TimeInterval = 86_400

    public static func detect(
        gameID: Int64,
        metric: InsightMetric,
        points unsorted: [MetricPoint],
        configuration: Configuration = Configuration()
    ) -> AnomalyResult {
        let points = unsorted.filter { $0.value.isFinite }.sorted { $0.date < $1.date }
        guard let latest = points.last else { return .insufficientData }
        let tolerance = matchTolerance(points)

        let weekly = references(for: latest.date, lag: week, count: configuration.weeksBack,
                                points: points, tolerance: tolerance)
        let daily = references(for: latest.date, lag: day, count: configuration.daysBack,
                               points: points, tolerance: tolerance)
        let baseline: Anomaly.Baseline
        let references: [Double]
        if weekly.count >= 2 {
            baseline = .sameTimePreviousWeeks
            references = weekly
        } else if daily.count >= 3 {
            baseline = .sameTimePreviousDays
            references = daily
        } else {
            return .insufficientData
        }

        guard let expected = Stats.median(references) else { return .insufficientData }
        let actual = latest.value
        let floor = metric.minimumVolume
        guard expected >= floor || actual >= floor else { return .normal(expected: expected) }

        let direction: Anomaly.Direction = actual < expected ? .drop : .spike
        guard expected > 0 else {
            // From nothing to something: only news for "bad" counters (errors appearing) and real volume.
            guard actual >= floor else { return .normal(expected: expected) }
            let severity: Anomaly.Severity = actual >= floor * 10 ? .high : .medium
            return .anomaly(Anomaly(gameID: gameID, metric: metric, direction: .spike, actual: actual,
                                    expected: expected, change: nil, severity: severity,
                                    detectedAt: latest.date, baseline: baseline))
        }

        let change = (actual - expected) / expected
        // Spread never drops below 5% of expected, so a perfectly flat history doesn't make every
        // wiggle an anomaly.
        let spread = max(Stats.scaledMAD(references) ?? 0, expected * 0.05)
        let score = abs(actual - expected) / spread
        guard abs(change) >= configuration.minimumChange, score >= configuration.minimumScore else {
            return .normal(expected: expected)
        }

        let severity: Anomaly.Severity = switch abs(change) {
        case 0.5...: .high
        case 0.3..<0.5: .medium
        default: .low
        }
        return .anomaly(Anomaly(gameID: gameID, metric: metric, direction: direction, actual: actual,
                                expected: expected, change: change, severity: severity,
                                detectedAt: latest.date, baseline: baseline))
    }

    /// Values at `date - lag * k` for k = 1...count.
    static func references(for date: Date, lag: TimeInterval, count: Int, points: [MetricPoint],
                           tolerance: TimeInterval) -> [Double] {
        guard count > 0 else { return [] }
        return (1...count).compactMap { k in
            Stats.value(near: date.addingTimeInterval(-lag * Double(k)), in: points, tolerance: tolerance)
        }
    }

    /// Half the typical sampling step (at least a minute), so lagged lookups find the matching sample
    /// without grabbing a neighbour.
    static func matchTolerance(_ points: [MetricPoint]) -> TimeInterval {
        guard points.count >= 2 else { return 60 }
        let steps = zip(points, points.dropFirst()).map { $1.date.timeIntervalSince($0.date) }
        return max(60, (Stats.median(steps) ?? 120) / 2)
    }
}
