import Foundation
import Testing
@testable import PeakKit

@Suite("Sample insights")
struct SampleInsightsTests {
    let now = Fixtures.now

    @Test func sampleInsightsAreWhatTheEnginesProduce() throws {
        let report = SampleData.updateImpact(now: now)
        #expect(report.verdict == .improved)
        #expect(report.caveats.isEmpty == false)

        let digests = SampleData.alertDigests(now: now)
        #expect(digests.count == 2)
        let attack = try #require(digests.first { $0.gameID == SampleData.attackAnimalsID })
        #expect(attack.concentratedIn?.dimension == "Mobile")
        #expect(attack.causes.first?.kind == .update)

        let briefing = SampleData.briefing(now: now)
        #expect(briefing.games.map(\.name) == ["Attack Animals", "Obby Rush"])
        #expect((1...3).contains(briefing.actions.count))

        let portfolio = SampleData.portfolio(now: now)
        #expect(portfolio.first?.name == "Obby Rush")
        #expect(portfolio.contains { $0.name == "Pet Café Tycoon" && $0.needsUpdate })
    }

    @Test func demoServiceRequiresConsentToAskAndCountsAsks() async throws {
        let service = DemoInsightService(now: { Fixtures.now })
        await #expect(throws: APIError.forbidden) { try await service.ask("Why did CCU drop?") }
        let settings = try await service.setConsent(true)
        #expect(settings.consented && settings.asksRemainingToday == DemoInsightService.dailyAskLimit)
        let answer = try await service.ask("Why did CCU drop?")
        #expect(answer.answer.hasPrefix("Attack Animals: CCU fell 24%."))
        #expect(answer.answer.contains("Possible cause:"))
        #expect(answer.asksRemainingToday == DemoInsightService.dailyAskLimit - 1)
        #expect(try await service.updateImpact(gameID: SampleData.obbyRushID) == nil)
    }

    @Test func demoModesBehave() async throws {
        let empty = DemoInsightService(mode: .empty, now: { Fixtures.now })
        #expect(try await empty.briefing().games.isEmpty)
        #expect(try await empty.alertDigests().isEmpty)
        let failing = DemoInsightService(mode: .failing, now: { Fixtures.now })
        await #expect(throws: DemoDashboardService.DemoFailure.self) { try await failing.briefing() }
    }

    @Test func insightPayloadsRoundTripThroughJSON() throws {
        let encoder = JSONCoding.makeEncoder()
        let decoder = JSONCoding.makeDecoder()
        let briefing = SampleData.briefing(now: now)
        #expect(try decoder.decode(Briefing.self, from: encoder.encode(briefing)) == briefing)
        let digests = SampleData.alertDigests(now: now)
        #expect(try decoder.decode([AlertDigest].self, from: encoder.encode(digests)) == digests)
        let report = SampleData.updateImpact(now: now)
        #expect(try decoder.decode(UpdateImpactReport.self, from: encoder.encode(report)) == report)
        let portfolio = SampleData.portfolio(now: now)
        #expect(try decoder.decode([GameHealth].self, from: encoder.encode(portfolio)) == portfolio)
    }
}
