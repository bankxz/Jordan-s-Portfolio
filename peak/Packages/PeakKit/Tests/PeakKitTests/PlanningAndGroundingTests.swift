import Foundation
import Testing
@testable import PeakKit

@Suite("Goal planner")
struct GoalPlannerTests {
    let start = Fixtures.now

    @Test func compoundingPlanEndsExactlyOnTargetAndDeadline() throws {
        let deadline = start.addingTimeInterval(30 * 86_400)
        let plan = GoalPlanner.plan(metric: .ccu, current: 250, target: 1_000, start: start, deadline: deadline)
        #expect(plan.weeks.count == 5)
        #expect(plan.weeks.last?.target == 1_000)
        #expect(plan.weeks.last?.endDate == deadline)
        #expect(zip(plan.weeks, plan.weeks.dropFirst()).allSatisfy { $0.target < $1.target })
        let growth = try #require(plan.weeklyGrowth)
        #expect(abs(growth - (pow(4, 0.2) - 1)) < 1e-9)
        #expect(plan.ambition == .veryAmbitious)
        #expect(plan.tasks.isEmpty == false)
    }

    @Test func smallGoalIsRealistic() {
        let plan = GoalPlanner.plan(metric: .ccu, current: 900, target: 1_000, start: start,
                                    deadline: start.addingTimeInterval(28 * 86_400))
        #expect(plan.weeks.count == 4)
        #expect(plan.ambition == .realistic)
        #expect(plan.summary.contains("900 \u{2192} 1K in 4 weeks"))
    }

    @Test func goalsFromZeroAreLinear() {
        let plan = GoalPlanner.plan(metric: .ccu, current: 0, target: 100, start: start,
                                    deadline: start.addingTimeInterval(28 * 86_400))
        #expect(plan.weeklyGrowth == nil)
        #expect(plan.weeks.map(\.target) == [25, 50, 75, 100])
    }

    @Test func decreasingGoalsGoDown() {
        let plan = GoalPlanner.plan(metric: .crashRate, current: 0.02, target: 0.01, start: start,
                                    deadline: start.addingTimeInterval(21 * 86_400))
        #expect(zip(plan.weeks, plan.weeks.dropFirst()).allSatisfy { $0.target > $1.target })
        #expect(plan.tasks.first?.contains("errors") == true)
    }

    @Test func expectedValueInterpolates() {
        let plan = GoalPlanner.plan(metric: .ccu, current: 0, target: 100, start: start,
                                    deadline: start.addingTimeInterval(28 * 86_400))
        #expect(plan.expectedValue(at: start) == 0)
        #expect(abs(plan.expectedValue(at: start.addingTimeInterval(3.5 * 86_400)) - 12.5) < 1e-9)
        #expect(plan.expectedValue(at: start.addingTimeInterval(60 * 86_400)) == 100)
    }

    @Test func checkClassifiesProgressAndReplansWhenBehind() throws {
        let plan = GoalPlanner.plan(metric: .ccu, current: 0, target: 100, start: start,
                                    deadline: start.addingTimeInterval(28 * 86_400))
        let midpoint = start.addingTimeInterval(14 * 86_400)
        #expect(GoalPlanner.check(plan, latestValue: 50, now: midpoint).status == .onTrack)
        #expect(GoalPlanner.check(plan, latestValue: 70, now: midpoint).status == .ahead)
        let behind = GoalPlanner.check(plan, latestValue: 30, now: midpoint)
        #expect(behind.status == .behind)
        let revised = try #require(behind.revisedPlan)
        #expect(revised.startValue == 30 && revised.targetValue == 100 && revised.deadline == plan.deadline)
        #expect(GoalPlanner.check(plan, latestValue: 101, now: midpoint).status == .achieved)
        #expect(GoalPlanner.check(plan, latestValue: 90, now: plan.deadline).status == .deadlinePassed)
    }
}

@Suite("Portfolio health")
struct PortfolioHealthTests {
    @Test func ranksGrowingStableGamesFirst() {
        let ranked = PortfolioHealth.rank([
            GameHealthInput(gameID: 1, name: "Struggling", ccuChange7d: -0.4, revenueChange7d: -0.3, d1Retention: 0.08,
                            crashRate: 0.025, openIssues: 2, daysSinceUpdate: 45),
            GameHealthInput(gameID: 2, name: "Thriving", ccuChange7d: 0.3, revenueChange7d: 0.2, d1Retention: 0.32,
                            crashRate: 0.001, daysSinceUpdate: 3),
        ])
        #expect(ranked.map(\.name) == ["Thriving", "Struggling"])
        #expect(ranked[0].score > 80)
        #expect(ranked[0].needsUpdate == false)
        #expect(ranked[1].needsUpdate)
        #expect(ranked[1].headline.contains("No update for 45 days"))
    }

    @Test func missingDataIsNeutralNotZero() {
        let health = PortfolioHealth.score(GameHealthInput(gameID: 1, name: "New"))
        #expect(health.score == 65)
        #expect(health.components.growth == 12.5)
    }

    @Test func survivesNonsenseInput() {
        let health = PortfolioHealth.score(GameHealthInput(gameID: 1, name: "X", ccuChange7d: .nan, revenueChange7d: .infinity,
                                                           d1Retention: -3, crashRate: .nan, openIssues: -4))
        #expect((0...100).contains(health.score))
    }
}

@Suite("Number grounding")
struct NumberGroundingTests {
    let facts = ["CCU 4.8K, +9.7% vs yesterday.", "Revenue R$182.4K in 24 h, -24.3% vs the day before.",
                 "Update v128 went live 2 h before the change."]

    @Test func acceptsRoundedRestatementsOfTheFacts() {
        #expect(NumberGrounding.isGrounded("CCU rose about 10% to 4.8K players.", facts: facts))
        #expect(NumberGrounding.isGrounded("You earned 182,400 Robux, down 24%.", facts: facts))
        #expect(NumberGrounding.isGrounded("Around 5K players are online.", facts: facts))
        #expect(NumberGrounding.isGrounded("Check v128 first; it shipped 2 hours earlier. Here are 3 steps.", facts: facts))
    }

    @Test func rejectsInventedNumbers() {
        #expect(NumberGrounding.check("CCU rose 15%.", against: facts).map(\.text) == ["15%"])
        #expect(NumberGrounding.check("Expect 6,000 players by Friday.", against: facts).map(\.text) == ["6,000"])
        // 24.3 players isn't 24.3%.
        #expect(NumberGrounding.isGrounded("24.3 players left.", facts: facts) == false)
        #expect(NumberGrounding.isGrounded("D1 retention could reach 30%.", facts: facts) == false)
    }

    @Test func parsesNumbersCarefully() {
        let numbers = NumberGrounding.numbers(in: "D1 was 18.5%, v128 had 1,000 players, R$2.4 each, 3.6M visits, 1,2 x2 4Km.")
        #expect(numbers.map(\.text) == ["18.5%", "1,000", "2.4", "3.6M", "1", "2", "4"])
        #expect(numbers.map(\.value) == [18.5, 1_000, 2.4, 3_600_000, 1, 2, 4])
    }
}

@Suite("Error clusterer")
struct ErrorClustererTests {
    @Test func groupsTheSameBugWithDifferentValues() throws {
        let t = Fixtures.now
        let entries = [
            LogEntry(message: "ServerScriptService.Pets:42: attempt to index nil with 'Level' (Players.Alice.Backpack)", timestamp: t, placeVersion: 128),
            LogEntry(message: "ServerScriptService.Pets:57: attempt to index nil with 'Owner' (Players.bob_99.Backpack)", timestamp: t.addingTimeInterval(60), placeVersion: 128),
            LogEntry(message: "ServerScriptService.Pets:42: attempt to index nil with 'Level' (Players.C.Backpack)", timestamp: t.addingTimeInterval(120), placeVersion: 128),
            LogEntry(message: "DataStore request dropped for key 7f3c2a10-1b2c-4d5e-8f90-123456789abc", timestamp: t, placeVersion: 127),
        ]
        let clusters = ErrorClusterer.cluster(entries)
        #expect(clusters.count == 2)
        let pets = try #require(clusters.first)
        #expect(pets.count == 3)
        #expect(pets.signature == "ServerScriptService.Pets:#: attempt to index nil with '…' (Players.<player>.Backpack)")
        #expect(pets.isNewInLatestVersion)
        #expect(pets.share == 0.75)
        #expect(clusters[1].signature == "DataStore request dropped for key <id>")
        #expect(clusters[1].isNewInLatestVersion == false)
    }

    @Test func emptyAndLimit() {
        #expect(ErrorClusterer.cluster([]).isEmpty)
        let many = (0..<5).map { LogEntry(message: "error type \(Character(UnicodeScalar(65 + $0)!))", timestamp: Fixtures.now) }
        #expect(ErrorClusterer.cluster(many, limit: 2).count == 2)
    }
}

@Suite("Claude prompt generator")
struct ClaudePromptGeneratorTests {
    @Test func promptSeparatesFactsFromSuspicionsAndCarriesConstraints() {
        let anomaly = Anomaly(gameID: 1, metric: .dataStoreErrors, direction: .spike, actual: 300, expected: 20,
                              change: 14, severity: .high, detectedAt: Fixtures.now, baseline: .sameTimePreviousWeeks)
        let digest = AlertPrioritizer.digests(
            anomalies: [anomaly], gameNames: [1: "Attack Animals"],
            events: [TimelineEvent(kind: .update, gameID: 1, date: Fixtures.now.addingTimeInterval(-3_600), detail: "v128")]
        )[0]
        let text = ClaudePromptGenerator.render(ClaudePromptGenerator.prompt(for: digest))
        #expect(text.hasPrefix("# Investigate: DataStore errors rose 1400%."))
        #expect(text.contains("Game: Attack Animals (Roblox experience, Luau)."))
        #expect(text.contains("Possible causes (not confirmed; check them before acting):\n- Update v128 went live 1 h before the change."))
        #expect(text.contains("GetAsync"))
        #expect(text.contains("never trust values sent through RemoteEvents"))
        #expect(text.contains("Simulate DataStore failures"))
    }

    @Test func funnelAndUpdatePrompts() {
        let funnel = FunnelAnalyzer.analyze([FunnelStep(name: "Join", players: 1_000), FunnelStep(name: "Tutorial", players: 300)])
        let funnelPrompt = ClaudePromptGenerator.prompt(for: funnel, gameName: "Obby Rush")
        #expect(funnelPrompt.title == "Reduce the drop between \u{201C}Join\u{201D} and \u{201C}Tutorial\u{201D}")

        let update = Fixtures.now
        let report = UpdateImpactAnalyzer.analyze(gameID: 1, updateLabel: "v9", updateDate: update, series: [
            .crashRate: dailyAround(update, before: [0.01, 0.01, 0.01], after: [0.03, 0.03, 0.03]),
            .ccu: dailyAround(update, before: [100, 100, 100], after: [100, 100, 100]),
        ])
        let text = ClaudePromptGenerator.render(ClaudePromptGenerator.prompt(for: report, gameName: "Obby Rush"))
        #expect(text.contains("Crash rate: 1% \u{2192} 3% (harmed)"))
        #expect(text.contains("Run a Studio test server"))
    }
}
