import Foundation
import PeakKit
import Testing
@testable import PeakServerCore

/// Contract for the timeline and AI bookkeeping, run against every store.
struct StoreInsightContractTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test(arguments: StoreFactory.allCases)
    func timelineDeduplicatesAndFiltersByGameAndTime(factory: StoreFactory) async throws {
        guard let store = try await factory.make() else { return }
        let game = Int64.random(in: 1_000_000...9_000_000_000)
        let other = game + 1
        let update = TimelineEvent(kind: .update, gameID: game, date: t0, detail: "published 21 Sep")
        // Platform-wide events are keyed by start time; vary it so reruns against the same database don't collide.
        let start = t0.addingTimeInterval(-7_200 + Double.random(in: 0..<600).rounded())
        let outage = TimelineEvent(kind: .robloxOutage, gameID: nil, date: start,
                                   endDate: start.addingTimeInterval(3_600), detail: "test outage \(game)")
        try await store.appendTimelineEvents([update, update, outage,
                                              TimelineEvent(kind: .update, gameID: other, date: t0, detail: "other")])
        try await store.appendTimelineEvents([update])

        let events = try await store.timelineEvents(universeIDs: [game], from: t0.addingTimeInterval(-5_400),
                                                    to: t0.addingTimeInterval(60))
        let mine = events.filter { $0.gameID == game || $0.detail == outage.detail }
        #expect(mine == [outage, update])
        #expect(events.contains { $0.gameID == other } == false)
        // The outage ended before this window starts.
        let later = try await store.timelineEvents(universeIDs: [game], from: t0.addingTimeInterval(-1_800), to: t0)
        #expect(later.contains { $0.detail == outage.detail } == false)
    }

    @Test(arguments: StoreFactory.allCases)
    func consentAndUsageAccounting(factory: StoreFactory) async throws {
        guard let store = try await factory.make() else { return }
        let user = try await store.upsertUser(robloxUserID: Int64.random(in: 1...1_000_000_000), username: "u",
                                              displayName: "U", now: t0)
        #expect(try await store.aiConsent(userID: user.id) == nil)
        try await store.setAIConsent(userID: user.id, consentedAt: t0)
        #expect(try await store.aiConsent(userID: user.id) == t0)
        try await store.setAIConsent(userID: user.id, consentedAt: nil)
        #expect(try await store.aiConsent(userID: user.id) == nil)

        // Far-future times keep this independent of other tests sharing the database.
        let base = Date(timeIntervalSince1970: 4_000_000_000 + Double.random(in: 0...1_000_000))
        let before = try await store.aiCostMicros(since: base)
        for (offset, feature) in [(0.0, "ask"), (60, "ask"), (120, "briefing")] {
            try await store.recordAIUsage(AIUsageRecord(userID: user.id, feature: feature, model: "m", inputTokens: 10,
                                                        outputTokens: 5, costMicros: 1_000, time: base.addingTimeInterval(offset)))
        }
        #expect(try await store.aiCostMicros(since: base) - before == 3_000)
        #expect(try await store.aiRequestCount(userID: user.id, feature: "ask", since: base) == 2)
        #expect(try await store.aiRequestCount(userID: user.id, feature: "ask", since: base.addingTimeInterval(30)) == 1)

        try await store.setAIConsent(userID: user.id, consentedAt: t0)
        try await store.deleteUser(id: user.id)
        #expect(try await store.aiConsent(userID: user.id) == nil)
        // Deleting the account keeps the spend (unlinked) so the monthly budget stays honest.
        #expect(try await store.aiCostMicros(since: base) - before == 3_000)
        #expect(try await store.aiRequestCount(userID: user.id, feature: "ask", since: base) == 0)
    }
}
