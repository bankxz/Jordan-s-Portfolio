import Foundation
import Observation
import PeakKit

/// State for insights and AI features: the daily briefing, unusual changes, portfolio health, update reports
/// and "Ask Peak". Separate from `AppModel` so the dashboard keeps working when insights fail.
@MainActor
@Observable
final class InsightsModel {
    enum Load<Value: Equatable>: Equatable {
        case idle
        case loading
        case loaded(Value)
        case failed(String)

        var value: Value? {
            if case .loaded(let value) = self { return value }
            return nil
        }
    }

    struct Exchange: Identifiable, Equatable {
        let id = UUID()
        let question: String
        var answer: BackendAPI.AskAnswer?
        var error: String?

        var isPending: Bool { answer == nil && error == nil }
    }

    /// Questions from the AI spec, offered as one-tap starters.
    static let suggestedQuestions = [
        "Why did my top game lose players yesterday?",
        "Which game grew fastest this week?",
        "Did the latest update help or hurt?",
        "What should I work on today?",
    ]

    private(set) var briefing: Load<Briefing> = .idle
    private(set) var digests: Load<[AlertDigest]> = .idle
    private(set) var portfolio: Load<[GameHealth]> = .idle
    private(set) var settings: BackendAPI.AISettings?
    private(set) var settingsError: String?
    private(set) var updateReports: [Int64: Load<UpdateImpactReport?>] = [:]
    private(set) var conversation: [Exchange] = []
    private(set) var isChangingConsent = false

    let service: any InsightService

    init(service: any InsightService) {
        self.service = service
    }

    var isAsking: Bool { conversation.contains { $0.isPending } }

    // MARK: Loading

    /// Loads everything shown on Home, Games and Alerts. Each part fails on its own.
    func refresh() async {
        async let briefingTask: Void = loadBriefing()
        async let digestsTask: Void = loadDigests()
        async let portfolioTask: Void = loadPortfolio()
        async let settingsTask: Void = loadSettings()
        _ = await (briefingTask, digestsTask, portfolioTask, settingsTask)
    }

    func loadBriefing() async {
        if briefing.value == nil { briefing = .loading }
        do {
            briefing = .loaded(try await service.briefing())
        } catch is CancellationError {
            if briefing == .loading { briefing = .idle }
        } catch {
            // Keep a previous briefing on screen if there is one.
            if briefing.value == nil { briefing = .failed(Self.message(for: error)) }
        }
    }

    func loadDigests() async {
        do {
            digests = .loaded(try await service.alertDigests())
        } catch is CancellationError {
        } catch {
            if digests.value == nil { digests = .failed(Self.message(for: error)) }
        }
    }

    func loadPortfolio() async {
        do {
            portfolio = .loaded(try await service.portfolio())
        } catch is CancellationError {
        } catch {
            if portfolio.value == nil { portfolio = .failed(Self.message(for: error)) }
        }
    }

    func loadSettings() async {
        do {
            settings = try await service.settings()
            settingsError = nil
        } catch is CancellationError {
        } catch {
            settingsError = Self.message(for: error)
        }
    }

    func loadUpdateReport(gameID: Int64) async {
        if updateReports[gameID]?.value == nil { updateReports[gameID] = .loading }
        do {
            updateReports[gameID] = .loaded(try await service.updateImpact(gameID: gameID))
        } catch is CancellationError {
        } catch {
            if updateReports[gameID]?.value == nil { updateReports[gameID] = .failed(Self.message(for: error)) }
        }
    }

    // MARK: AI consent and questions

    func setConsent(_ value: Bool) async {
        isChangingConsent = true
        defer { isChangingConsent = false }
        do {
            settings = try await service.setConsent(value)
            settingsError = nil
            // The briefing's wording depends on consent.
            await loadBriefing()
        } catch {
            settingsError = Self.message(for: error)
        }
    }

    func ask(_ rawQuestion: String) async {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard question.isEmpty == false, isAsking == false else { return }
        let exchange = Exchange(question: String(question.prefix(BackendAPI.maxQuestionLength)))
        conversation.append(exchange)
        func update(_ change: (inout Exchange) -> Void) {
            guard let index = conversation.firstIndex(where: { $0.id == exchange.id }) else { return }
            change(&conversation[index])
        }
        do {
            let answer = try await service.ask(exchange.question)
            update { $0.answer = answer }
            if var current = settings {
                current.asksRemainingToday = answer.asksRemainingToday
                settings = current
            }
        } catch is CancellationError {
            update { $0.error = "Cancelled." }
        } catch {
            update { $0.error = Self.askMessage(for: error) }
        }
    }

    func clearConversation() {
        conversation.removeAll { $0.isPending == false }
    }

    // MARK: Messages

    static func askMessage(for error: any Error) -> String {
        switch error as? APIError {
        case .forbidden: "Turn on AI features to ask questions."
        case .rateLimited: "You've used today's questions. They reset at midnight UTC."
        case .server(status: 503): "AI isn't available right now. Your briefing and alerts still work without it."
        default: message(for: error)
        }
    }

    static func message(for error: any Error) -> String {
        AppModel.message(for: error)
    }
}
