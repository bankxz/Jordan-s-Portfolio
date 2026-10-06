import Foundation
import Testing
@testable import PeakKit

struct AlertEngineTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func rule(_ condition: AlertRule.Condition, cooldown: TimeInterval = 1_800, enabled: Bool = true) -> AlertRule {
        AlertRule(gameID: 42, metric: .ccu, condition: condition, cooldown: cooldown, isEnabled: enabled)
    }

    /// One sample per minute ending at `end`.
    func series(_ values: [Double], endingAt end: Date) -> [MetricPoint] {
        values.enumerated().map { index, value in
            MetricPoint(date: end.addingTimeInterval(Double(index - values.count + 1) * 60), value: value)
        }
    }

    @Test func firesOnRisingEdgeAndRecordsState() throws {
        let result = AlertEngine.evaluate(rule(.above(1_000)), series: series([900, 1_200], endingAt: t0),
                                          state: AlertRuleState(), now: t0)
        guard case .fired(let event) = result.outcome else {
            Issue.record("Expected fired, got \(result.outcome)")
            return
        }
        #expect(event.value == 1_200)
        #expect(event.gameID == 42)
        #expect(result.state.conditionWasMet)
        #expect(result.state.lastFiredAt == t0)
    }

    @Test func thresholdIsStrict() {
        let atThreshold = AlertEngine.evaluate(rule(.above(1_000)), series: series([1_000], endingAt: t0),
                                               state: AlertRuleState(), now: t0)
        #expect(atThreshold.outcome == .conditionNotMet)
        let below = AlertEngine.evaluate(rule(.below(1_000)), series: series([1_000], endingAt: t0),
                                         state: AlertRuleState(), now: t0)
        #expect(below.outcome == .conditionNotMet)
    }

    @Test func staysQuietWhileConditionPersists() {
        var state = AlertRuleState()
        var outcomes: [AlertOutcome] = []
        // Poll every minute for 3 hours with CCU always above threshold: exactly one alert.
        for minute in 0..<180 {
            let now = t0.addingTimeInterval(Double(minute) * 60)
            let result = AlertEngine.evaluate(rule(.above(1_000)), series: series([1_500], endingAt: now),
                                              state: state, now: now)
            outcomes.append(result.outcome)
            state = result.state
        }
        let fired = outcomes.filter { if case .fired = $0 { true } else { false } }
        #expect(fired.count == 1)
    }

    @Test func rearmsAfterConditionClearsButRespectsCooldown() {
        let r = rule(.above(1_000), cooldown: 1_800)
        var state = AlertRuleState()

        state = AlertEngine.evaluate(r, series: series([1_500], endingAt: t0), state: state, now: t0).state
        // Clears after 5 minutes...
        let t5 = t0.addingTimeInterval(300)
        state = AlertEngine.evaluate(r, series: series([800], endingAt: t5), state: state, now: t5).state
        #expect(state.conditionWasMet == false)
        // ...crosses again at 10 minutes: inside cooldown, suppressed.
        let t10 = t0.addingTimeInterval(600)
        let early = AlertEngine.evaluate(r, series: series([1_500], endingAt: t10), state: state, now: t10)
        #expect(early.outcome == .suppressed)
        // Clears and crosses again after cooldown: fires.
        let t40 = t0.addingTimeInterval(2_400)
        state = AlertEngine.evaluate(r, series: series([800], endingAt: t40), state: early.state, now: t40).state
        let t41 = t40.addingTimeInterval(60)
        let late = AlertEngine.evaluate(r, series: series([1_500], endingAt: t41), state: state, now: t41)
        #expect(late.outcome != .suppressed)
        if case .fired = late.outcome {} else { Issue.record("Expected fired after cooldown, got \(late.outcome)") }
    }

    @Test func staleSampleIsIgnoredAndStateUntouched() {
        let previous = AlertRuleState(conditionWasMet: false, lastFiredAt: nil)
        let old = t0.addingTimeInterval(-AlertEngine.maxSampleAge - 1)
        let result = AlertEngine.evaluate(rule(.above(1)), series: series([9_999], endingAt: old),
                                          state: previous, now: t0)
        #expect(result.outcome == .staleData)
        #expect(result.state == previous)
    }

    @Test func sampleExactlyAtMaxAgeIsUsed() {
        let edge = t0.addingTimeInterval(-AlertEngine.maxSampleAge)
        let result = AlertEngine.evaluate(rule(.above(1)), series: series([5], endingAt: edge),
                                          state: AlertRuleState(), now: t0)
        #expect(result.outcome != .staleData)
    }

    @Test func emptySeriesAndDisabledRule() {
        #expect(AlertEngine.evaluate(rule(.above(1)), series: [], state: AlertRuleState(), now: t0).outcome == .noData)
        let disabled = AlertEngine.evaluate(rule(.above(1), enabled: false), series: series([5], endingAt: t0),
                                            state: AlertRuleState(conditionWasMet: true, lastFiredAt: t0), now: t0)
        #expect(disabled.outcome == .disabled)
        #expect(disabled.state == AlertRuleState())
    }

    @Test func unsortedSeriesUsesLatestByDate() {
        let points = [MetricPoint(date: t0, value: 2_000), MetricPoint(date: t0.addingTimeInterval(-60), value: 10)]
        let result = AlertEngine.evaluate(rule(.above(1_000)), series: points, state: AlertRuleState(), now: t0)
        if case .fired(let event) = result.outcome {
            #expect(event.value == 2_000)
        } else {
            Issue.record("Expected fired, got \(result.outcome)")
        }
    }

    // MARK: Drop detection

    @Test(arguments: [
        ([1_000.0, 800, 690], true),    // 31% below peak in window
        ([1_000, 800, 700], true),      // exactly 30%
        ([1_000, 800, 710], false),     // 29%
        ([700, 700, 700], false),       // flat
        ([0, 0, 0], false),             // zero reference
        ([500, 1_000, 2_000], false),   // rising
    ])
    func dropFrom(values: [Double], shouldFire: Bool) {
        let r = rule(.dropFrom(fraction: 0.3, window: 3_600))
        let result = AlertEngine.evaluate(r, series: series(values, endingAt: t0), state: AlertRuleState(), now: t0)
        let fired = if case .fired = result.outcome { true } else { false }
        #expect(fired == shouldFire)
    }

    @Test func dropIgnoresPeaksOutsideWindow() {
        // Peak of 10,000 was 2 hours ago; within the 1h window the max is 1,000.
        let points = [MetricPoint(date: t0.addingTimeInterval(-7_200), value: 10_000)]
            + series([1_000, 950], endingAt: t0)
        let r = rule(.dropFrom(fraction: 0.3, window: 3_600))
        #expect(AlertEngine.evaluate(r, series: points, state: AlertRuleState(), now: t0).outcome == .conditionNotMet)
    }

    @Test(arguments: [(0.0, 3_600.0), (-0.5, 3_600), (0.3, 0), (0.3, -60)])
    func invalidDropParametersNeverFire(fraction: Double, window: TimeInterval) {
        let r = rule(.dropFrom(fraction: fraction, window: window))
        let result = AlertEngine.evaluate(r, series: series([1_000, 10], endingAt: t0), state: AlertRuleState(), now: t0)
        #expect(result.outcome == .conditionNotMet)
    }

    @Test func dropWithSingleSampleHasNoReference() {
        let r = rule(.dropFrom(fraction: 0.1, window: 3_600))
        #expect(AlertEngine.evaluate(r, series: series([5], endingAt: t0), state: AlertRuleState(), now: t0).outcome == .conditionNotMet)
    }
}

struct CampaignTests {
    func campaign(spent: Int64 = 1_000, budget: Int64? = 4_000, impressions: Int64 = 50_000,
                  clicks: Int64 = 500, plays: Int64 = 250) -> Campaign {
        Campaign(id: "c1", name: "Launch", gameID: 1, status: .running, spentRobux: spent,
                 budgetRobux: budget, impressions: impressions, clicks: clicks, plays: plays)
    }

    @Test func ratios() {
        let c = campaign()
        #expect(c.clickThroughRate == 0.01)
        #expect(c.costPerClick == 2)
        #expect(c.costPerMille == 20)
        #expect(c.costPerPlay == 4)
        #expect(c.budgetUsed == 0.25)
    }

    @Test func zeroDenominatorsAreNil() {
        let c = campaign(budget: 0, impressions: 0, clicks: 0, plays: 0)
        #expect(c.clickThroughRate == nil)
        #expect(c.costPerClick == nil)
        #expect(c.costPerMille == nil)
        #expect(c.costPerPlay == nil)
        #expect(c.budgetUsed == nil)
        #expect(campaign(budget: nil).budgetUsed == nil)
    }

    @Test func overspendClampsBudgetUsed() {
        #expect(campaign(spent: 9_000, budget: 4_000).budgetUsed == 1)
    }

    @Test func negativeSpendFromBadDataIsNil() {
        #expect(campaign(spent: -5).costPerClick == nil)
        #expect(campaign(spent: -5).budgetUsed == 0)
    }
}
