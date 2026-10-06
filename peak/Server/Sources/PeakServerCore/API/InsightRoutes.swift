import Foundation
import Hummingbird
import PeakKit

/// Keeps the AI wording of a briefing while its facts are unchanged, so reopening the app doesn't pay for
/// the same paragraph again.
actor NarrationCache {
    private var entries: [UUID: (facts: Briefing, narrated: Briefing, at: Date)] = [:]
    static let lifetime: TimeInterval = 6 * 3_600

    /// Facts without the timestamp, for comparison.
    static func key(_ briefing: Briefing) -> Briefing {
        var copy = briefing
        copy.generatedAt = Date(timeIntervalSince1970: 0)
        return copy
    }

    func lookup(userID: UUID, facts: Briefing, now: Date) -> Briefing? {
        guard let entry = entries[userID], entry.facts == Self.key(facts),
              now.timeIntervalSince(entry.at) < Self.lifetime else { return nil }
        var narrated = entry.narrated
        narrated.generatedAt = facts.generatedAt
        return narrated
    }

    func store(userID: UUID, facts: Briefing, narrated: Briefing, now: Date) {
        guard narrated.isAIWritten else { return }
        if entries.count > 10_000 { entries = entries.filter { now.timeIntervalSince($0.value.at) < Self.lifetime } }
        entries[userID] = (Self.key(facts), narrated, now)
    }

    func invalidate(userID: UUID) { entries[userID] = nil }
}

/// `docs/api/backend-contract.md` → Insights. All routes require a session.
struct InsightRoutes {
    let insights: InsightBuilder
    let dashboard: DashboardBuilder
    let ai: AIService
    let cache: NarrationCache
    let now: @Sendable () -> Date

    func add(to group: RouterGroup<AppRequestContext>) {
        group.get("v1/insights/settings") { _, context in
            try JSONBody.response(try await ai.settings(userID: try context.requireAuth().userID))
        }

        group.put("v1/insights/consent") { request, context in
            let userID = try context.requireAuth().userID
            let body = try await JSONBody.decode(BackendAPI.FlagBody.self, from: request, context: context)
            let settings = try await ai.setConsent(userID: userID, value: body.value)
            await cache.invalidate(userID: userID)
            return try JSONBody.response(settings)
        }

        group.get("v1/insights/briefing") { _, context in
            let userID = try context.requireAuth().userID
            let facts = try await insights.briefing(userID: userID)
            if let cached = await cache.lookup(userID: userID, facts: facts, now: now()) {
                return try JSONBody.response(cached)
            }
            let narrated = await ai.narrate(facts, userID: userID)
            await cache.store(userID: userID, facts: facts, narrated: narrated, now: now())
            return try JSONBody.response(narrated)
        }

        group.post("v1/insights/ask") { request, context in
            let userID = try context.requireAuth().userID
            let body = try await JSONBody.decode(BackendAPI.AskBody.self, from: request, context: context)
            let question = body.question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard question.isEmpty == false, question.count <= BackendAPI.maxQuestionLength else {
                throw APIFailure.badRequest("invalid_question")
            }
            // Fail early (before any AI call) if Roblox access is gone.
            _ = try await dashboard.ownedUniverses(userID: userID)
            let toolbox = InsightToolbox(userID: userID, dashboard: dashboard, insights: insights, now: now)
            do {
                return try JSONBody.response(try await ai.ask(question, userID: userID, toolbox: toolbox))
            } catch let failure as AIService.AskFailure {
                switch failure {
                case .unavailable: throw APIFailure.unavailable("ai_unavailable")
                case .consentRequired: throw APIFailure.forbidden("ai_consent_required")
                case .dailyLimitReached:
                    let midnight = AIService.startOfDay(now()).addingTimeInterval(86_400)
                    throw APIFailure.rateLimited(retryAfter: max(1, Int(midnight.timeIntervalSince(now()).rounded(.up))))
                }
            } catch is ClaudeError {
                throw APIFailure.upstreamUnavailable
            }
        }

        group.get("v1/insights/alerts") { _, context in
            try JSONBody.response(try await insights.digests(userID: try context.requireAuth().userID))
        }

        group.get("v1/insights/portfolio") { _, context in
            try JSONBody.response(try await insights.portfolio(userID: try context.requireAuth().userID))
        }

        group.get("v1/games/:universeID/funnels") { _, context in
            let userID = try context.requireAuth().userID
            return try JSONBody.response(try await insights.funnels(userID: userID, universe: try Self.universe(context)))
        }

        group.get("v1/games/:universeID/update-impact") { _, context in
            let userID = try context.requireAuth().userID
            guard let report = try await insights.updateImpact(userID: userID, universe: try Self.universe(context)) else {
                throw APIFailure.notFound
            }
            return try JSONBody.response(report)
        }
    }

    static func universe(_ context: AppRequestContext) throws -> Int64 {
        guard let raw = context.parameters.get("universeID"), raw.allSatisfy(\.isASCII), raw.allSatisfy(\.isNumber),
              let universe = Int64(raw), universe > 0 else {
            throw APIFailure.badRequest("invalid_universe")
        }
        return universe
    }
}
