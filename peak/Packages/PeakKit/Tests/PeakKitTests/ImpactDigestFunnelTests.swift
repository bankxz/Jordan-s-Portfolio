import Foundation
import Testing
@testable import PeakKit

/// Daily points around `update`: `beforeValues` on the days before, `afterValues` on the days after.
func dailyAround(_ update: Date, before beforeValues: [Double], after afterValues: [Double]) -> [MetricPoint] {
    let before = beforeValues.enumerated().map { index, value in
        MetricPoint(date: update.addingTimeInterval(-Double(beforeValues.count - index) * 86_400), value: value)
    }
    let after = afterValues.enumerated().map { index, value in
        MetricPoint(date: update.addingTimeInterval(Double(index + 1) * 86_400), value: value)
    }
    return before + after
}

@Suite("Update impact")
struct UpdateImpactTests {
    let update = Fixtures.now

    @Test func betterRetentionWithStableCrashesIsAnImprovement() throws {
        let report = UpdateImpactAnalyzer.analyze(gameID: 1, updateLabel: "v42", updateDate: update, series: [
            .d1Retention: dailyAround(update, before: [0.200, 0.198, 0.202, 0.201, 0.199], after: [0.236, 0.241, 0.239, 0.240]),
            .crashRate: dailyAround(update, before: [0.010, 0.011, 0.010, 0.009, 0.010], after: [0.010, 0.010, 0.011, 0.010]),
            .sessionLength: dailyAround(update, before: [12, 12.2, 11.9, 12.1, 12], after: [12.1, 11.9, 12, 12.2]),
        ])
        #expect(report.verdict == .improved)
        let d1 = try #require(report.metrics.first { $0.metric == .d1Retention })
        #expect(d1.verdict == .improved)
        #expect(report.metrics.first { $0.metric == .crashRate }?.verdict == .neutral)
        #expect(report.summary.hasPrefix("v42 improved things."))
    }

    @Test func worseCrashesAreNeverOffsetByGainsElsewhere() {
        let report = UpdateImpactAnalyzer.analyze(gameID: 1, updateLabel: "v43", updateDate: update, series: [
            .d1Retention: dailyAround(update, before: [0.20, 0.20, 0.20], after: [0.30, 0.30, 0.30]),
            .d7Retention: dailyAround(update, before: [0.08, 0.08, 0.08], after: [0.10, 0.10, 0.10]),
            .crashRate: dailyAround(update, before: [0.010, 0.010, 0.010], after: [0.020, 0.021, 0.019]),
        ])
        #expect(report.verdict == .harmed)
        #expect(report.summary.contains("Crash rate"))
    }

    @Test func tooFewDaysAfterTheUpdateIsTooEarly() {
        let report = UpdateImpactAnalyzer.analyze(gameID: 1, updateLabel: "v44", updateDate: update, series: [
            .d1Retention: dailyAround(update, before: [0.2, 0.2, 0.2], after: [0.3, 0.3]),
            .crashRate: dailyAround(update, before: [0.01, 0.01, 0.01], after: [0.01]),
        ])
        #expect(report.verdict == .tooEarly)
        #expect(report.metrics.allSatisfy { $0.verdict == .insufficientData })
        #expect(report.summary.contains("too early"))
    }

    @Test func changesInsideTheNoiseAreNeutral() {
        let report = UpdateImpactAnalyzer.analyze(gameID: 1, updateLabel: "v45", updateDate: update, series: [
            .ccu: dailyAround(update, before: [800, 1_300, 900, 1_250, 850], after: [1_000, 1_200, 950]),
            .sessionLength: dailyAround(update, before: [10, 14, 9, 15, 11], after: [12, 13, 12]),
        ])
        #expect(report.metrics.allSatisfy { $0.verdict == .neutral })
        #expect(report.verdict == .neutral)
    }

    @Test func zeroBaselineStillJudgesBadCounters() throws {
        let report = UpdateImpactAnalyzer.analyze(gameID: 1, updateLabel: "v46", updateDate: update, series: [
            .serverCrashes: dailyAround(update, before: [0, 0, 0], after: [6, 8, 7]),
        ])
        let crashes = try #require(report.metrics.first)
        #expect(crashes.change == nil)
        #expect(crashes.verdict == .harmed)
    }

    @Test func overlappingEventsBecomeCaveats() {
        let events = [
            TimelineEvent(kind: .update, gameID: 1, date: update, detail: "v47"),
            TimelineEvent(kind: .campaignStarted, gameID: 1, date: update.addingTimeInterval(86_400), detail: "Autumn"),
            TimelineEvent(kind: .priceChanged, gameID: 2, date: update.addingTimeInterval(3_600), detail: "other game"),
            TimelineEvent(kind: .calendar, gameID: nil, date: update.addingTimeInterval(-20 * 86_400), detail: "Too early"),
        ]
        let report = UpdateImpactAnalyzer.analyze(gameID: 1, updateLabel: "v47", updateDate: update, series: [:], events: events)
        #expect(report.caveats == ["Campaign \u{201C}Autumn\u{201D} started 24 h after the update, so part of the change may come from that."])
    }
}

@Suite("Alert digest")
struct AlertDigestTests {
    func anomaly(_ metric: InsightMetric, change: Double, severity: Anomaly.Severity, minutesAgo: Double = 0,
                 game: Int64 = 1) -> Anomaly {
        Anomaly(gameID: game, metric: metric, direction: change < 0 ? .drop : .spike, actual: 1 + change, expected: 1,
                change: change, severity: severity, detectedAt: Fixtures.now.addingTimeInterval(-minutesAgo * 60),
                baseline: .sameTimePreviousWeeks)
    }

    @Test func combinesAnIncidentIntoOneMessageWithANextStep() throws {
        let ccu = anomaly(.ccu, change: -0.24, severity: .medium)
        let anomalies = [ccu,
                         anomaly(.newPlayerCompletion, change: -0.12, severity: .low, minutesAgo: 20),
                         anomaly(.d1Retention, change: -0.08, severity: .low, minutesAgo: 40)]
        let digests = AlertPrioritizer.digests(
            anomalies: anomalies, gameNames: [1: "Attack Animals"],
            breakdowns: [ccu.id: [DimensionChange(dimension: "Mobile", change: -0.31),
                                  DimensionChange(dimension: "Desktop", change: -0.05)]])
        let digest = try #require(digests.first)
        #expect(digests.count == 1)
        #expect(digest.headline.metric == .ccu)
        #expect(digest.message == "CCU fell 24%. The largest change was on Mobile (-31%). Also: D1 retention fell 8%, First-session completion fell 12%.")
        #expect(digest.suggestedAction == "Check the mobile tutorial before changing your ads.")
    }

    @Test func separateIncidentsAndGamesStaySeparate() {
        let digests = AlertPrioritizer.digests(anomalies: [
            anomaly(.ccu, change: -0.3, severity: .medium),
            anomaly(.ccu, change: -0.3, severity: .medium, minutesAgo: 5 * 60),
            anomaly(.ccu, change: -0.3, severity: .medium, game: 2),
        ], gameNames: [:])
        #expect(digests.count == 3)
        #expect(digests.contains { $0.gameName == "Game 2" })
    }

    @Test func crashesPointToTheLogsAndBadNewsSortsFirst() {
        let digests = AlertPrioritizer.digests(anomalies: [
            anomaly(.revenue, change: 0.8, severity: .high, game: 2),
            anomaly(.crashRate, change: 0.9, severity: .high, game: 1),
        ], gameNames: [1: "A", 2: "B"])
        #expect(digests.map(\.gameName) == ["A", "B"])
        #expect(digests[0].suggestedAction.contains("error logs"))
        #expect(digests[1].suggestedAction == "Find what drove this and do more of it.")
    }

    @Test func evenSplitsAreNotCalledConcentrated() {
        let ccu = anomaly(.ccu, change: -0.24, severity: .medium)
        let digest = AlertPrioritizer.digests(anomalies: [ccu], gameNames: [:],
                                              breakdowns: [ccu.id: [DimensionChange(dimension: "Mobile", change: -0.25)]])
        #expect(digest.first?.concentratedIn == nil)
    }
}

@Suite("Funnel analyzer")
struct FunnelAnalyzerTests {
    @Test func pointsAtTheWorstStep() throws {
        let report = FunnelAnalyzer.analyze([
            FunnelStep(name: "Join", players: 1_000),
            FunnelStep(name: "Tutorial", players: 800),
            FunnelStep(name: "First Egg", players: 400),
            FunnelStep(name: "First Hatch", players: 360),
            FunnelStep(name: "Upgrade", players: 200),
            FunnelStep(name: "Zone 2", players: 150),
        ])
        let focus = try #require(report.focus)
        #expect(focus.from == "Tutorial" && focus.to == "First Egg")
        #expect(report.overallConversion == 0.15)
        #expect(report.summary == "The biggest drop is \u{201C}Tutorial\u{201D} \u{2192} \u{201C}First Egg\u{201D}: only 50% continue (400 players lost). Fix this step first.")
    }

    @Test func notesWhenAStepGotWorse() {
        let report = FunnelAnalyzer.analyze([
            FunnelStep(name: "Join", players: 1_000, previousPlayers: 1_000),
            FunnelStep(name: "Tutorial", players: 500, previousPlayers: 700),
        ])
        #expect(report.summary.contains("It was 70% last period"))
    }

    @Test func flagsLoggingBugsAndClampsConversion() {
        let report = FunnelAnalyzer.analyze([
            FunnelStep(name: "Join", players: 100),
            FunnelStep(name: "Tutorial", players: 120),
        ])
        #expect(report.transitions[0].conversion == 1)
        #expect(report.warnings.count == 1)
    }

    @Test func smallSamplesAndDegenerateInputGiveNoFocus() {
        #expect(FunnelAnalyzer.analyze([FunnelStep(name: "Join", players: 20), FunnelStep(name: "Tutorial", players: 5)]).focus == nil)
        #expect(FunnelAnalyzer.analyze([FunnelStep(name: "Join", players: 20)]).transitions.isEmpty)
        let zero = FunnelAnalyzer.analyze([FunnelStep(name: "Join", players: 0), FunnelStep(name: "Tutorial", players: 0)])
        #expect(zero.focus == nil && zero.overallConversion == nil)
    }
}
