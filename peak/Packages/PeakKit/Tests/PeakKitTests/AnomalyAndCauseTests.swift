import Foundation
import Testing
@testable import PeakKit

/// Hourly series ending at `end` with a daily cycle that repeats exactly every week, so the
/// same-time-last-week baseline is clean.
func weeklyPatternSeries(base: Double, end: Date, hours: Int, lastValueFactor: Double = 1,
                         noise: Double = 0.02) -> [MetricPoint] {
    var generator = SeededGenerator(seed: 42)
    return (0..<hours).map { index in
        let date = end.addingTimeInterval(-Double(hours - 1 - index) * 3_600)
        let hour = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400) / 3_600
        let daily = 1 + 0.3 * sin((hour - 14) / 24 * 2 * .pi)
        var value = base * daily * (1 + (generator.nextUnit() - 0.5) * noise)
        if index == hours - 1 { value *= lastValueFactor }
        return MetricPoint(date: date, value: value)
    }
}

@Suite("Anomaly detector")
struct AnomalyDetectorTests {
    let end = Fixtures.now

    @Test func normalTrafficIsNotAnAnomaly() {
        let points = weeklyPatternSeries(base: 5_000, end: end, hours: 24 * 35)
        guard case .normal = AnomalyDetector.detect(gameID: 1, metric: .ccu, points: points) else {
            Issue.record("expected normal")
            return
        }
    }

    @Test func fortyPercentDropIsAMediumDropAgainstPreviousWeeks() throws {
        let points = weeklyPatternSeries(base: 5_000, end: end, hours: 24 * 35, lastValueFactor: 0.6)
        guard case .anomaly(let anomaly) = AnomalyDetector.detect(gameID: 1, metric: .ccu, points: points) else {
            Issue.record("expected anomaly")
            return
        }
        #expect(anomaly.direction == .drop)
        #expect(anomaly.severity == .medium)
        #expect(anomaly.baseline == .sameTimePreviousWeeks)
        let change = try #require(anomaly.change)
        #expect(abs(change + 0.4) < 0.03)
        #expect(anomaly.isGoodNews == false)
        #expect(anomaly.detectedAt == end)
    }

    @Test func bigSpikeIsHighSeverityAndGoodNewsForRevenue() {
        let points = weeklyPatternSeries(base: 2_000, end: end, hours: 24 * 35, lastValueFactor: 1.7)
        guard case .anomaly(let anomaly) = AnomalyDetector.detect(gameID: 1, metric: .revenue, points: points) else {
            Issue.record("expected anomaly")
            return
        }
        #expect(anomaly.direction == .spike)
        #expect(anomaly.severity == .high)
        #expect(anomaly.isGoodNews)
    }

    @Test func tinyGamesDontProduceAlarms() {
        // 5 → 1 player is an 80% "drop", but it's noise.
        let points = weeklyPatternSeries(base: 5, end: end, hours: 24 * 35, lastValueFactor: 0.2)
        guard case .normal = AnomalyDetector.detect(gameID: 1, metric: .ccu, points: points) else {
            Issue.record("expected normal")
            return
        }
    }

    @Test func newGamesNeedHistory() {
        let points = weeklyPatternSeries(base: 5_000, end: end, hours: 48, lastValueFactor: 0.5)
        #expect(AnomalyDetector.detect(gameID: 1, metric: .ccu, points: points) == .insufficientData)
        #expect(AnomalyDetector.detect(gameID: 1, metric: .ccu, points: []) == .insufficientData)
    }

    @Test func fallsBackToPreviousDaysWithLessThanTwoWeeks() {
        let points = weeklyPatternSeries(base: 5_000, end: end, hours: 24 * 5, lastValueFactor: 0.5)
        guard case .anomaly(let anomaly) = AnomalyDetector.detect(gameID: 1, metric: .ccu, points: points) else {
            Issue.record("expected anomaly")
            return
        }
        #expect(anomaly.baseline == .sameTimePreviousDays)
    }

    @Test func oneFreakWeekInHistoryDoesNotMaskOrFakeAnAnomaly() {
        var points = weeklyPatternSeries(base: 5_000, end: end, hours: 24 * 35)
        // Last week, same hour, was a 10x event spike.
        let lastWeek = end.addingTimeInterval(-7 * 86_400)
        points = points.map { $0.date == lastWeek ? MetricPoint(date: $0.date, value: $0.value * 10) : $0 }
        guard case .normal = AnomalyDetector.detect(gameID: 1, metric: .ccu, points: points) else {
            Issue.record("median should ignore one outlier")
            return
        }
    }

    @Test func flatHistoryNeedsTheMinimumChange() {
        let flat = (0..<(24 * 21)).map { MetricPoint(date: end.addingTimeInterval(-Double($0) * 3_600), value: 1_000) }
        func detect(_ last: Double) -> AnomalyResult {
            var points = flat
            points[0] = MetricPoint(date: end, value: last)
            return AnomalyDetector.detect(gameID: 1, metric: .ccu, points: points)
        }
        guard case .normal = detect(900) else { Issue.record("10% is below the minimum change"); return }
        guard case .anomaly = detect(750) else { Issue.record("25% drop should be reported"); return }
    }

    @Test func errorsAppearingFromZeroAreReported() {
        var points = (1..<(24 * 21)).map { MetricPoint(date: end.addingTimeInterval(-Double($0) * 3_600), value: 0) }
        points.append(MetricPoint(date: end, value: 60))
        guard case .anomaly(let anomaly) = AnomalyDetector.detect(gameID: 1, metric: .serverCrashes, points: points) else {
            Issue.record("expected anomaly")
            return
        }
        #expect(anomaly.change == nil)
        #expect(anomaly.severity == .high)
        #expect(anomaly.isGoodNews == false)
        #expect(InsightText.sentence(for: anomaly).contains("from almost nothing"))
    }

    @Test func ignoresNonFiniteValuesAndOrder() {
        var points = weeklyPatternSeries(base: 5_000, end: end, hours: 24 * 35, lastValueFactor: 0.5)
        points.append(MetricPoint(date: end.addingTimeInterval(-30), value: .nan))
        points.shuffle()
        guard case .anomaly = AnomalyDetector.detect(gameID: 1, metric: .ccu, points: points) else {
            Issue.record("expected anomaly")
            return
        }
    }
}

@Suite("Possible causes")
struct PossibleCauseTests {
    func anomaly(direction: Anomaly.Direction = .drop, metric: InsightMetric = .ccu, at date: Date = Fixtures.now,
                 baseline: Anomaly.Baseline = .sameTimePreviousWeeks) -> Anomaly {
        Anomaly(gameID: 7, metric: metric, direction: direction, actual: 600, expected: 1_000,
                change: direction == .drop ? -0.4 : 0.4, severity: .medium, detectedAt: date, baseline: baseline)
    }

    @Test func recentUpdateIsAPlausibleCauseWithEvidence() throws {
        let update = TimelineEvent(kind: .update, gameID: 7, date: Fixtures.now.addingTimeInterval(-2 * 3_600), detail: "v128")
        let causes = CauseCorrelator.causes(for: anomaly(), events: [update])
        let cause = try #require(causes.first)
        #expect(cause.likelihood == .plausible)
        #expect(cause.evidence == "Update v128 went live 2 h before the change.")
    }

    @Test func eventsOutsideTheWindowOrAfterTheChangeAreIgnored() {
        let old = TimelineEvent(kind: .update, gameID: 7, date: Fixtures.now.addingTimeInterval(-30 * 3_600), detail: "v127")
        let later = TimelineEvent(kind: .update, gameID: 7, date: Fixtures.now.addingTimeInterval(600), detail: "v129")
        let otherGame = TimelineEvent(kind: .update, gameID: 8, date: Fixtures.now.addingTimeInterval(-600), detail: "v3")
        #expect(CauseCorrelator.causes(for: anomaly(), events: [old, later, otherGame]).isEmpty)
    }

    @Test func ongoingOutageIsPlausibleForBadNewsOnly() throws {
        let outage = TimelineEvent(kind: .robloxOutage, gameID: nil, date: Fixtures.now.addingTimeInterval(-1_800),
                                   endDate: Fixtures.now.addingTimeInterval(1_800), detail: "join failures")
        let cause = try #require(CauseCorrelator.causes(for: anomaly(), events: [outage]).first)
        #expect(cause.likelihood == .plausible)
        #expect(cause.evidence.contains("was ongoing when the change happened"))
        // Revenue going *up* isn't explained by an outage.
        #expect(CauseCorrelator.causes(for: anomaly(direction: .spike, metric: .revenue), events: [outage]).isEmpty)
    }

    @Test func campaignsOnlyExplainChangesInTheirDirection() {
        let started = TimelineEvent(kind: .campaignStarted, gameID: 7, date: Fixtures.now.addingTimeInterval(-3_600), detail: "Spring")
        let stopped = TimelineEvent(kind: .campaignStopped, gameID: 7, date: Fixtures.now.addingTimeInterval(-3_600), detail: "Spring")
        #expect(CauseCorrelator.causes(for: anomaly(direction: .drop), events: [started]).isEmpty)
        #expect(CauseCorrelator.causes(for: anomaly(direction: .drop), events: [stopped]).count == 1)
        #expect(CauseCorrelator.causes(for: anomaly(direction: .spike), events: [started]).count == 1)
    }

    @Test func weekendIsOnlySuggestedWhenTheBaselineIgnoresWeekdays() {
        let saturday = Fixtures.now.addingTimeInterval(-2 * 86_400)
        #expect(Calendar.utc.component(.weekday, from: saturday) == 7)
        let daily = CauseCorrelator.causes(for: anomaly(at: saturday, baseline: .sameTimePreviousDays), events: [])
        #expect(daily.count == 1 && daily[0].isCalendarEffect)
        #expect(CauseCorrelator.causes(for: anomaly(at: saturday, baseline: .sameTimePreviousWeeks), events: []).isEmpty)
    }

    @Test func plausibleCausesComeFirstAndTheListIsCapped() {
        let events = (1...6).map { hours in
            TimelineEvent(kind: .priceChanged, gameID: hours.isMultiple(of: 2) ? 7 : nil,
                          date: Fixtures.now.addingTimeInterval(-Double(hours) * 3_600), detail: "item \(hours)")
        }
        let causes = CauseCorrelator.causes(for: anomaly(), events: events, limit: 3)
        #expect(causes.count == 3)
        #expect(causes.allSatisfy { $0.likelihood == .plausible })
    }

    @Test func evidenceNeverClaimsCertainty() {
        let kinds: [TimelineEvent.Kind] = [.update, .campaignStopped, .campaignBudgetChanged, .priceChanged,
                                           .thumbnailChanged, .serverProblem, .robloxOutage, .calendar]
        let events = kinds.map { TimelineEvent(kind: $0, gameID: 7, date: Fixtures.now.addingTimeInterval(-600), detail: "x") }
        for cause in CauseCorrelator.causes(for: anomaly(), events: events, limit: 20) {
            for word in ["caused", "because", "confirmed", "definitely"] {
                #expect(cause.evidence.lowercased().contains(word) == false, "\(cause.evidence)")
            }
        }
    }
}
