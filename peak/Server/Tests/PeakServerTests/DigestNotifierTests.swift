import Foundation
import PeakKit
import Testing
@testable import PeakServerCore

@Suite("Digest notifier")
struct DigestNotifierTests {
    let store = InMemoryStore()
    let clock = TestClock()
    static let universe: Int64 = 3_828_411_582

    actor Pushes: PushSender {
        private(set) var sent: [PushMessage] = []
        func send(_ message: PushMessage, to device: DeviceRecord) async -> PushResult {
            sent.append(message)
            return .delivered
        }
    }

    /// Four weeks of steady CCU, then `latest` now.
    func seed(latest: Double, at time: Date) async throws {
        var samples: [MetricSample] = []
        for step in 1...(29 * 48) {
            samples.append(MetricSample(universeID: Self.universe, metric: .ccu, time: time.addingTimeInterval(-Double(step) * 1_800), value: 1_000))
        }
        samples.append(MetricSample(universeID: Self.universe, metric: .ccu, time: time, value: latest))
        try await store.appendSamples(samples)
    }

    func makeUser(withDevice: Bool = true) async throws -> UUID {
        let user = try await store.upsertUser(robloxUserID: 1, username: "u", displayName: "U", now: clock.now)
        try await store.saveGrant(RobloxGrant(userID: user.id, accessTokenSealed: Data(), refreshTokenSealed: Data(), refreshTokenHash: "h",
                                              accessTokenExpiresAt: clock.now, scopes: [], universeIDs: [Self.universe], updatedAt: clock.now))
        try await store.upsertGameInfo([GameInfo(universeID: Self.universe, rootPlaceID: 1, name: "Attack Animals", updatedAt: clock.now)])
        if withDevice {
            try await store.saveDevice(DeviceRecord(userID: user.id, token: String(repeating: "a", count: 64), sandbox: true, updatedAt: clock.now))
        }
        return user.id
    }

    func notifier(_ push: Pushes) -> DigestNotifier {
        DigestNotifier(store: store, insights: InsightBuilder(store: store, dashboard: DashboardBuilder(store: store, now: clock.function), now: clock.function),
                       push: push, now: clock.function)
    }

    @Test func oneNotificationPerIncidentWithACooldown() async throws {
        _ = try await makeUser()
        try await seed(latest: 600, at: clock.now)
        let push = Pushes()
        #expect(try await notifier(push).tick(logger: testLogger) == 1)
        let message = try #require(await push.sent.first)
        #expect(message.title == "Attack Animals")
        #expect(message.body.hasPrefix("CCU fell 40%."))
        #expect(message.url == Route.game(id: Self.universe).url)

        // Five minutes later the same drop is still there: no second notification.
        clock.advance(300)
        try await store.appendSamples([MetricSample(universeID: Self.universe, metric: .ccu, time: clock.now, value: 600)])
        #expect(try await notifier(push).tick(logger: testLogger) == 0)

        // After the cooldown, a still-unusual game notifies again.
        clock.advance(DigestNotifier.cooldown)
        try await seed(latest: 550, at: clock.now)
        #expect(try await notifier(push).tick(logger: testLogger) == 1)
    }

    @Test func goodNewsAndUsersWithoutDevicesAreNotPushed() async throws {
        _ = try await makeUser(withDevice: false)
        try await seed(latest: 600, at: clock.now)
        let push = Pushes()
        #expect(try await notifier(push).tick(logger: testLogger) == 0)

        let spike = AlertPrioritizer.digests(anomalies: [Anomaly(gameID: 1, metric: .ccu, direction: .spike, actual: 2_000, expected: 1_000,
                                                                 change: 1, severity: .high, detectedAt: clock.now, baseline: .sameTimePreviousWeeks)],
                                             gameNames: [:])[0]
        #expect(DigestNotifier.shouldPush(spike, now: clock.now) == false)
    }

    @Test func longMessagesAreTrimmed() {
        let anomaly = Anomaly(gameID: 1, metric: .ccu, direction: .drop, actual: 1, expected: 2, change: -0.5, severity: .high,
                              detectedAt: clock.now, baseline: .sameTimePreviousWeeks)
        var digest = AlertPrioritizer.digests(anomalies: [anomaly], gameNames: [1: "G"])[0]
        digest.message = String(repeating: "x", count: 400)
        #expect(DigestNotifier.message(for: digest).body.count == 220)
    }
}

struct StoreDigestPushContractTests {
    @Test(arguments: StoreFactory.allCases)
    func claimsRespectTheCooldownAtomically(factory: StoreFactory) async throws {
        guard let store = try await factory.make() else { return }
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let user = try await store.upsertUser(robloxUserID: Int64.random(in: 1...1_000_000_000), username: "u", displayName: "U", now: t0)
        let winners = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 {
                group.addTask { try await store.claimDigestPush(userID: user.id, key: "1-ccu-drop", at: t0, cooldown: 3_600) }
            }
            return try await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(winners == 1)
        #expect(try await store.claimDigestPush(userID: user.id, key: "1-ccu-drop", at: t0.addingTimeInterval(1_800), cooldown: 3_600) == false)
        #expect(try await store.claimDigestPush(userID: user.id, key: "1-revenue-drop", at: t0.addingTimeInterval(1_800), cooldown: 3_600))
        #expect(try await store.claimDigestPush(userID: user.id, key: "1-ccu-drop", at: t0.addingTimeInterval(3_600), cooldown: 3_600))
    }
}
