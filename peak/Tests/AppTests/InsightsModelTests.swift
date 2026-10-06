import Foundation
import PeakKit
import Testing
@testable import Peak

@MainActor
struct InsightsModelTests {
    nonisolated static let now = Date(timeIntervalSince1970: 1_790_000_000)

    func makeModel(_ mode: DemoDashboardService.Mode = .normal, consented: Bool = false) -> InsightsModel {
        InsightsModel(service: DemoInsightService(mode: mode, consented: consented, now: { Self.now }))
    }

    @Test func refreshLoadsEveryPart() async throws {
        let model = makeModel()
        await model.refresh()
        let briefing = try #require(model.briefing.value)
        #expect(briefing.games.isEmpty == false)
        #expect(model.digests.value?.isEmpty == false)
        #expect(model.portfolio.value?.isEmpty == false)
        #expect(model.settings?.consented == false)
    }

    @Test func failuresStayLocal() async {
        let model = makeModel(.failing)
        await model.refresh()
        guard case .failed = model.briefing else { Issue.record("expected failure"); return }
        #expect(model.settingsError != nil)
    }

    @Test func askNeedsConsentThenAnswersAndCountsDown() async throws {
        let model = makeModel()
        await model.loadSettings()
        await model.ask("Why did CCU drop?")
        #expect(model.conversation.last?.error == "Turn on AI features to ask questions.")

        await model.setConsent(true)
        #expect(model.settings?.consented == true)
        await model.ask("  Why did CCU drop?  ")
        let exchange = try #require(model.conversation.last)
        #expect(exchange.question == "Why did CCU drop?")
        #expect(exchange.answer?.answer.contains("Possible cause:") == true)
        #expect(model.settings?.asksRemainingToday == DemoInsightService.dailyAskLimit - 1)
        #expect(model.isAsking == false)

        await model.ask("   ")
        #expect(model.conversation.count == 2, "blank questions are ignored")
        model.clearConversation()
        #expect(model.conversation.isEmpty)
    }

    @Test func updateReportsAreLoadedPerGame() async {
        let model = makeModel()
        await model.loadUpdateReport(gameID: SampleData.attackAnimalsID)
        await model.loadUpdateReport(gameID: SampleData.obbyRushID)
        guard case .loaded(let report?) = model.updateReports[SampleData.attackAnimalsID] else {
            Issue.record("expected a report"); return
        }
        #expect(report.verdict == .improved)
        if case .loaded(let none)? = model.updateReports[SampleData.obbyRushID] {
            #expect(none == nil)
        } else {
            Issue.record("expected a loaded empty report")
        }
    }

    @Test func askErrorMessages() {
        #expect(InsightsModel.askMessage(for: APIError.forbidden) == "Turn on AI features to ask questions.")
        #expect(InsightsModel.askMessage(for: APIError.rateLimited(retryAfter: 60))
                == "You've used today's questions. They reset at midnight UTC.")
        #expect(InsightsModel.askMessage(for: APIError.server(status: 503))
                == "AI isn't available right now. Your briefing and alerts still work without it.")
        #expect(InsightsModel.askMessage(for: URLError(.notConnectedToInternet)) == AppModel.message(for: URLError(.notConnectedToInternet)))
    }

    @Test func goalPlannerSuggestionRounding() {
        #expect(GoalPlannerView.roundSignificant(9_640) == 9_600)
        #expect(GoalPlannerView.roundSignificant(100) == 100)
        #expect(GoalPlannerView.roundSignificant(2_484) == 2_500)
    }
}
