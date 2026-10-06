import Foundation
import Testing
@testable import PeakKit

struct GoalEngineTests {
    let created = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let day: TimeInterval = 86_400

    func goal(start: Double = 1_000, target: Double = 5_000, days: Double? = 10,
              tasks: [GoalTask] = []) -> Goal {
        Goal(title: "Reach 5K CCU", metric: .ccu, startValue: start, targetValue: target,
             createdAt: created, deadline: days.map { created.addingTimeInterval($0 * day) },
             tasks: tasks)
    }

    // MARK: Progress

    @Test(arguments: [
        (1_000.0, 0.0),
        (3_000, 0.5),
        (5_000, 1.0),
        (9_000, 1.0),   // overshoot clamps
        (200, 0.0),     // went backwards: clamps at 0
    ])
    func progressIncreasingGoal(current: Double, expected: Double) {
        let result = GoalEngine.evaluate(goal(), currentValue: current, now: created)
        #expect(result.progress == expected)
    }

    @Test func progressDecreasingGoal() {
        // Reduce something from 40 to 20: at 30 we're halfway.
        let reduce = goal(start: 40, target: 20)
        #expect(GoalEngine.evaluate(reduce, currentValue: 30, now: created).progress == 0.5)
        #expect(GoalEngine.evaluate(reduce, currentValue: 15, now: created).status == .achieved)
        #expect(GoalEngine.evaluate(reduce, currentValue: 45, now: created).progress == 0)
    }

    @Test(arguments: [
        (5.0, 5.0),
        (0, .nan),
        (.infinity, 10),
    ])
    func invalidGoals(start: Double, target: Double) {
        let result = GoalEngine.evaluate(goal(start: start, target: target), currentValue: 3, now: created)
        #expect(result.status == .invalid)
        #expect(result.progress == 0)
    }

    @Test func nonFiniteCurrentValueIsInvalid() {
        #expect(GoalEngine.evaluate(goal(), currentValue: .nan, now: created).status == .invalid)
    }

    // MARK: Status vs pace

    @Test func noDeadlineIsOnTrackUntilAchieved() {
        let open = goal(days: nil)
        let farFuture = created.addingTimeInterval(1_000 * day)
        #expect(GoalEngine.evaluate(open, currentValue: 1_001, now: farFuture).status == .onTrack)
        #expect(GoalEngine.evaluate(open, currentValue: 1_001, now: farFuture).timeElapsed == nil)
        #expect(GoalEngine.evaluate(open, currentValue: 5_000, now: farFuture).status == .achieved)
    }

    @Test(arguments: [
        // (days elapsed of 10, progress) -> status
        (5.0, 0.5, GoalStatus.onTrack),
        (5, 0.6, .onTrack),
        (5, 0.41, .atRisk),
        (5, 0.40, .atRisk),   // exactly at tolerance
        (5, 0.39, .behind),
        (0, 0, .onTrack),
    ])
    func paceStatus(daysElapsed: Double, progress: Double, expected: GoalStatus) {
        let current = 1_000 + progress * 4_000
        let now = created.addingTimeInterval(daysElapsed * day)
        #expect(GoalEngine.evaluate(goal(), currentValue: current, now: now).status == expected)
    }

    @Test func deadlinePassedWithoutTargetIsMissed() {
        let now = created.addingTimeInterval(10 * day)
        #expect(GoalEngine.evaluate(goal(), currentValue: 4_999, now: now).status == .missed)
        #expect(GoalEngine.evaluate(goal(), currentValue: 5_000, now: now).status == .achieved)
    }

    @Test func deadlineBeforeCreationCountsAsFullyElapsed() {
        let broken = goal(days: -1)
        let result = GoalEngine.evaluate(broken, currentValue: 2_000, now: created)
        #expect(result.timeElapsed == 1)
        #expect(result.status == .missed)
    }

    @Test func nowBeforeCreationClampsElapsedToZero() {
        let result = GoalEngine.evaluate(goal(), currentValue: 1_000, now: created.addingTimeInterval(-day))
        #expect(result.timeElapsed == 0)
        #expect(result.status == .onTrack)
    }

    // MARK: Tasks

    @Test func taskCompletion() {
        let tasks = [GoalTask(title: "a", isDone: true), GoalTask(title: "b"),
                     GoalTask(title: "c", isDone: true), GoalTask(title: "d")]
        #expect(GoalEngine.evaluate(goal(tasks: tasks), currentValue: 1_000, now: created).taskCompletion == 0.5)
        #expect(GoalEngine.evaluate(goal(), currentValue: 1_000, now: created).taskCompletion == nil)
    }

    // MARK: Projection

    func history(_ values: [Double]) -> [MetricPoint] {
        values.enumerated().map { MetricPoint(date: created.addingTimeInterval(Double($0.offset) * day), value: $0.element) }
    }

    @Test func projectsLinearGrowth() throws {
        // +500/day from 1000: reaches 5000 after 8 days.
        let result = GoalEngine.evaluate(goal(), currentValue: 2_000,
                                         history: history([1_000, 1_500, 2_000]),
                                         now: created.addingTimeInterval(2 * day))
        let projected = try #require(result.projectedCompletion)
        #expect(abs(projected.timeIntervalSince(created) - 8 * day) < 1)
    }

    @Test func historyOrderDoesNotMatter() {
        let ordered = history([1_000, 1_500, 2_000])
        let a = GoalEngine.evaluate(goal(), currentValue: 2_000, history: ordered, now: created)
        let b = GoalEngine.evaluate(goal(), currentValue: 2_000, history: ordered.reversed(), now: created)
        #expect(a.projectedCompletion == b.projectedCompletion)
    }

    @Test(arguments: [
        [Double](),
        [1_000],
        [2_000, 2_000, 2_000],       // flat
        [2_000, 1_500, 1_000],       // moving away
    ])
    func noProjectionWhenNotApproaching(values: [Double]) {
        let result = GoalEngine.evaluate(goal(), currentValue: 2_000, history: history(values), now: created)
        #expect(result.projectedCompletion == nil)
    }

    @Test func noProjectionWhenAllPointsShareATimestamp() {
        let same = [MetricPoint(date: created, value: 1), MetricPoint(date: created, value: 2)]
        #expect(GoalEngine.evaluate(goal(), currentValue: 2_000, history: same, now: created).projectedCompletion == nil)
    }

    @Test func noProjectionOnceAchieved() {
        let result = GoalEngine.evaluate(goal(), currentValue: 6_000,
                                         history: history([1_000, 3_000, 6_000]), now: created)
        #expect(result.projectedCompletion == nil)
    }

    @Test func projectionNeverEarlierThanLatestSample() throws {
        // Fit line already passed the target before the last sample (noisy data).
        let noisy = history([1_000, 6_000, 1_200, 4_900])
        let result = GoalEngine.evaluate(goal(), currentValue: 4_900, history: noisy, now: created)
        let projected = try #require(result.projectedCompletion)
        #expect(projected >= noisy.last!.date)
    }
}
