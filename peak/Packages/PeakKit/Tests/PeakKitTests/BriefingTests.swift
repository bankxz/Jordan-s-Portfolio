import Foundation
import Testing
@testable import PeakKit

@Suite("Briefing builder")
struct BriefingTests {
    let now = Fixtures.now
    var games: [Game] { SampleData.games(now: now) }

    func drop(game: Int64, severity: Anomaly.Severity = .high) -> AlertDigest {
        let anomaly = Anomaly(gameID: game, metric: .ccu, direction: .drop, actual: 3_600, expected: 4_800, change: -0.25,
                              severity: severity, detectedAt: now, baseline: .sameTimePreviousWeeks)
        return AlertPrioritizer.digests(anomalies: [anomaly], gameNames: [game: "Attack Animals"])[0]
    }

    @Test func ranksUrgentIssuesThenHarmfulUpdatesThenGoalsAndCapsAtThree() throws {
        let attack = try #require(games.first { $0.name == "Attack Animals" })
        let obby = try #require(games.first { $0.name == "Obby Rush" })
        let harmed = UpdateImpactReport(gameID: obby.id, updateLabel: "v12", updateDate: now, metrics: [], verdict: .harmed,
                                        caveats: [], summary: "v12 made things worse. Worse: D1 retention (-12%).")
        let goal = SampleData.goals(now: now)[0]
        let behind = GoalProgress(goal: goal, evaluation: GoalEngine.evaluate(goal, currentValue: 3_100, now: now))
        #expect(behind.evaluation.status == .behind)

        let briefing = BriefingBuilder.build(
            games: [BriefingGameInput(game: attack, revenuePrevious24h: 200_000, d1Retention: 0.21, d1RetentionPrevious: 0.19),
                    BriefingGameInput(game: obby, latestUpdate: harmed)],
            digests: [drop(game: attack.id)],
            goals: [behind],
            campaigns: SampleData.campaigns(),
            now: now)

        #expect(briefing.headline == "1 thing needs your attention today.")
        #expect(briefing.actions.count == 3)
        #expect(briefing.actions[0].title == "Watch the next hour. If it doesn't recover, check what changed recently.")
        #expect(briefing.actions[1].title == "Review v12 on Obby Rush")
        #expect(briefing.actions[2].title == "Catch up on \u{201C}Hit 6K CCU on Attack Animals\u{201D}")
        #expect(briefing.actions[2].reason.contains("Next task: Add daily login streak."))

        let attackFacts = try #require(briefing.games.first { $0.gameID == attack.id }).facts.map(\.text)
        #expect(attackFacts.contains("Revenue R$182.4K in 24 h, -8.8% vs the day before."))
        #expect(attackFacts.contains("D1 retention 21% (7-day average 19%)."))
        #expect(attackFacts.contains { $0.hasPrefix("Ad \u{201C}Spring launch\u{201D}: R$42K spent, R$2.2 per play") })
        #expect(briefing.isAIWritten == false)
    }

    @Test func quietDaysStillSuggestSomething() {
        let briefing = BriefingBuilder.build(games: games.prefix(2).map { BriefingGameInput(game: $0) }, now: now)
        #expect(briefing.headline == "All quiet: no unusual changes overnight.")
        #expect(briefing.actions.count == 1)
        #expect(briefing.actions[0].title == "Spend today on the next update for Attack Animals")
    }

    @Test func gamesWithoutRevenueAccessGetNoRevenueFact() throws {
        let neon = try #require(games.first { $0.stats.robux24h == nil })
        let brief = BriefingBuilder.build(games: [BriefingGameInput(game: neon)], now: now).games[0]
        #expect(brief.facts.allSatisfy { $0.metric != .revenue })
    }

    @Test func noFavouritesExplainsWhatToDo() {
        let briefing = BriefingBuilder.build(games: [], now: now)
        #expect(briefing.headline == "Favourite a game to get a daily briefing.")
        #expect(briefing.actions.isEmpty)
    }

    @Test func allTextFeedsGrounding() {
        let briefing = BriefingBuilder.build(games: games.prefix(1).map { BriefingGameInput(game: $0) },
                                             digests: [drop(game: games[0].id)], now: now)
        #expect(NumberGrounding.isGrounded("CCU fell 25% on Attack Animals.", facts: briefing.allText))
        #expect(NumberGrounding.isGrounded("CCU fell 40% on Attack Animals.", facts: briefing.allText) == false)
    }
}
