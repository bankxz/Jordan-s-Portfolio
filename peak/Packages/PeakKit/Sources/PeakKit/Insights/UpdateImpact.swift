import Foundation

/// Before/after comparison of one metric around an update.
public struct MetricImpact: Hashable, Codable, Sendable {
    public enum Verdict: String, Hashable, Codable, Sendable {
        case improved
        case neutral
        case harmed
        /// Too few data points on one side (D7 retention needs a week after the update, for example).
        case insufficientData
    }

    public var metric: InsightMetric
    public var before: Double?
    public var after: Double?
    /// Fractional change after vs before. `nil` without both sides or with a zero baseline.
    public var change: Double?
    public var verdict: Verdict
    public var beforeSamples: Int
    public var afterSamples: Int

    public init(metric: InsightMetric, before: Double?, after: Double?, change: Double?, verdict: Verdict,
                beforeSamples: Int, afterSamples: Int) {
        self.metric = metric
        self.before = before
        self.after = after
        self.change = change
        self.verdict = verdict
        self.beforeSamples = beforeSamples
        self.afterSamples = afterSamples
    }
}

public struct UpdateImpactReport: Hashable, Codable, Sendable {
    public enum Verdict: String, Hashable, Codable, Sendable {
        case improved
        case neutral
        case harmed
        case tooEarly
    }

    public var gameID: Int64
    public var updateLabel: String
    public var updateDate: Date
    public var metrics: [MetricImpact]
    public var verdict: Verdict
    /// Things that make the comparison less clean, e.g. a campaign that started in the same window.
    public var caveats: [String]
    public var summary: String

    public init(gameID: Int64, updateLabel: String, updateDate: Date, metrics: [MetricImpact],
                verdict: Verdict, caveats: [String], summary: String) {
        self.gameID = gameID
        self.updateLabel = updateLabel
        self.updateDate = updateDate
        self.metrics = metrics
        self.verdict = verdict
        self.caveats = caveats
        self.summary = summary
    }
}

/// Compares the window before an update with the window after it, per metric, and gives an overall verdict.
///
/// A change only counts when it beats both a minimum relative size and the day-to-day noise of the
/// "before" window, so a quiet Tuesday after a busy weekend isn't called a regression.
public enum UpdateImpactAnalyzer {
    public struct Configuration: Hashable, Sendable {
        public var window: TimeInterval
        public var minimumSamples: Int
        /// Changes smaller than this (relative) are neutral regardless of noise.
        public var minimumChange: Double
        /// How many standard errors a change must exceed.
        public var noiseMultiplier: Double

        public init(window: TimeInterval = 7 * 86_400, minimumSamples: Int = 3, minimumChange: Double = 0.03,
                    noiseMultiplier: Double = 2) {
            self.window = window
            self.minimumSamples = minimumSamples
            self.minimumChange = minimumChange
            self.noiseMultiplier = noiseMultiplier
        }
    }

    /// How much each metric counts towards the overall verdict. Crashes and early retention matter most.
    public static func weight(_ metric: InsightMetric) -> Int {
        switch metric {
        case .crashRate, .d1Retention, .d7Retention: 3
        case .sessionLength, .revenuePerPlayer, .newPlayerCompletion, .serverCrashes: 2
        default: 1
        }
    }

    public static func analyze(
        gameID: Int64,
        updateLabel: String,
        updateDate: Date,
        series: [InsightMetric: [MetricPoint]],
        events: [TimelineEvent] = [],
        configuration: Configuration = Configuration()
    ) -> UpdateImpactReport {
        let impacts = series
            .map { metric, points in impact(metric: metric, points: points, updateDate: updateDate,
                                             configuration: configuration) }
            .sorted { $0.metric.priority < $1.metric.priority }

        let measured = impacts.filter { $0.verdict != .insufficientData }
        let verdict: UpdateImpactReport.Verdict
        if measured.count < 2 {
            verdict = .tooEarly
        } else {
            let score = measured.reduce(0) { total, impact in
                switch impact.verdict {
                case .improved: total + weight(impact.metric)
                case .harmed: total - weight(impact.metric)
                default: total
                }
            }
            // A significantly worse crash rate is never offset by better numbers elsewhere.
            let crashesWorse = measured.contains { $0.metric == .crashRate && $0.verdict == .harmed }
            if crashesWorse || score <= -2 {
                verdict = .harmed
            } else if score >= 2 {
                verdict = .improved
            } else {
                verdict = .neutral
            }
        }

        let caveats = caveatsFor(events: events, gameID: gameID, updateDate: updateDate, window: configuration.window)
        return UpdateImpactReport(gameID: gameID, updateLabel: updateLabel, updateDate: updateDate,
                                  metrics: impacts, verdict: verdict, caveats: caveats,
                                  summary: summary(label: updateLabel, verdict: verdict, impacts: impacts))
    }

    static func impact(metric: InsightMetric, points: [MetricPoint], updateDate: Date,
                       configuration: Configuration) -> MetricImpact {
        let finite = points.filter { $0.value.isFinite }
        let before = finite.filter { $0.date < updateDate && $0.date >= updateDate.addingTimeInterval(-configuration.window) }
            .map(\.value)
        // The update day itself is mixed, so "after" starts strictly after the update.
        let after = finite.filter { $0.date > updateDate && $0.date <= updateDate.addingTimeInterval(configuration.window) }
            .map(\.value)
        let beforeMean = Stats.mean(before)
        let afterMean = Stats.mean(after)
        guard before.count >= configuration.minimumSamples, after.count >= configuration.minimumSamples,
              let beforeMean, let afterMean else {
            return MetricImpact(metric: metric, before: beforeMean, after: afterMean, change: nil,
                                verdict: .insufficientData, beforeSamples: before.count, afterSamples: after.count)
        }

        let change = Stats.change(from: beforeMean, to: afterMean)
        // Standard error of the difference of the two means, using each side's spread.
        let seBefore = (Stats.standardDeviation(before) ?? 0) / Double(before.count).squareRoot()
        let seAfter = (Stats.standardDeviation(after) ?? 0) / Double(after.count).squareRoot()
        let noise = (seBefore * seBefore + seAfter * seAfter).squareRoot() * configuration.noiseMultiplier
        let difference = afterMean - beforeMean
        let bigEnough = abs(difference) > max(noise, abs(beforeMean) * configuration.minimumChange)

        let verdict: MetricImpact.Verdict
        if bigEnough == false {
            verdict = .neutral
        } else {
            verdict = (difference > 0) == metric.higherIsBetter ? .improved : .harmed
        }
        return MetricImpact(metric: metric, before: beforeMean, after: afterMean, change: change,
                            verdict: verdict, beforeSamples: before.count, afterSamples: after.count)
    }

    static func caveatsFor(events: [TimelineEvent], gameID: Int64, updateDate: Date, window: TimeInterval) -> [String] {
        let start = updateDate.addingTimeInterval(-window)
        let end = updateDate.addingTimeInterval(window)
        return events
            .filter { event in
                guard event.gameID == nil || event.gameID == gameID else { return false }
                // The update being analysed isn't a caveat of itself; other updates are.
                return event.kind != .update || event.date != updateDate
            }
            .filter { event in
                let eventEnd = event.endDate ?? event.date
                return eventEnd >= start && event.date <= end
            }
            .sorted { $0.date < $1.date }
            .map { event in
                let side = event.date < updateDate ? "before" : "after"
                let label: String = switch event.kind {
                case .update: "Another update (\(event.detail))"
                case .campaignStarted: "Campaign \u{201C}\(event.detail)\u{201D} started"
                case .campaignStopped: "Campaign \u{201C}\(event.detail)\u{201D} stopped"
                case .campaignBudgetChanged: "A campaign budget changed (\(event.detail))"
                case .priceChanged: "A price changed (\(event.detail))"
                case .thumbnailChanged: "The thumbnail changed (\(event.detail))"
                case .serverProblem: "A server problem (\(event.detail))"
                case .robloxOutage: "A Roblox-wide incident (\(event.detail))"
                case .calendar: event.detail
                }
                let distance = InsightText.duration(abs(event.date.timeIntervalSince(updateDate)))
                return "\(label) \(distance) \(side) the update, so part of the change may come from that."
            }
    }

    static func summary(label: String, verdict: UpdateImpactReport.Verdict, impacts: [MetricImpact]) -> String {
        let improved = impacts.filter { $0.verdict == .improved }
        let harmed = impacts.filter { $0.verdict == .harmed }
        func list(_ items: [MetricImpact]) -> String {
            items.prefix(3).map { impact in
                let change = impact.change.map { " (\(MetricFormatter.percentChange($0)))" } ?? ""
                return impact.metric.displayName + change
            }.joined(separator: ", ")
        }
        switch verdict {
        case .tooEarly:
            return "It's too early to judge \(label): there isn't enough data on both sides of the update yet."
        case .improved:
            let downside = harmed.isEmpty ? "" : " Worse: \(list(harmed))."
            return "\(label) improved things. Better: \(list(improved)).\(downside)"
        case .harmed:
            let upside = improved.isEmpty ? "" : " Better: \(list(improved))."
            return "\(label) made things worse. Worse: \(list(harmed)).\(upside)"
        case .neutral:
            if improved.isEmpty && harmed.isEmpty {
                return "\(label) made no clear difference to the measured metrics."
            }
            var parts: [String] = []
            if improved.isEmpty == false { parts.append("Better: \(list(improved)).") }
            if harmed.isEmpty == false { parts.append("Worse: \(list(harmed)).") }
            return "\(label) is roughly neutral overall. " + parts.joined(separator: " ")
        }
    }
}
