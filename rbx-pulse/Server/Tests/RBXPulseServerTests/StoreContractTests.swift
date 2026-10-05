import Foundation
import RBXPulseKit
import Testing
@testable import RBXPulseServerCore

/// Behaviour every `Store` must have. Run against each implementation via `StoreFactory`.
enum StoreFactory: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case memory
    case postgres

    var testDescription: String { rawValue }

    /// `nil` when the implementation isn't available in this environment (no DATABASE_URL).
    func make() async throws -> (any Store)? {
        switch self {
        case .memory:
            return InMemoryStore()
        case .postgres:
            return try await TestPostgres.makeStore()
        }
    }
}

struct StoreContractTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func sampleSession(user: UUID, family: UUID = UUID(), suffix: String = UUID().uuidString) -> SessionRecord {
        SessionRecord(id: UUID(), familyID: family, userID: user,
                      accessTokenHash: "a-\(suffix)", accessExpiresAt: t0.addingTimeInterval(900),
                      refreshTokenHash: "r-\(suffix)", refreshExpiresAt: t0.addingTimeInterval(86_400), createdAt: t0)
    }

    func sampleGrant(user: UUID, refreshHash: String) -> RobloxGrant {
        RobloxGrant(userID: user, accessTokenSealed: Data([1]), refreshTokenSealed: Data([2]),
                    refreshTokenHash: refreshHash, accessTokenExpiresAt: t0, scopes: ["openid"],
                    universeIDs: [1, 2], updatedAt: t0)
    }

    @Test(arguments: StoreFactory.allCases)
    func usersUpsertByRobloxID(factory: StoreFactory) async throws {
        guard let store = try await factory.make() else { return }
        let first = try await store.upsertUser(robloxUserID: 42, username: "old", displayName: "Old", now: t0)
        let second = try await store.upsertUser(robloxUserID: 42, username: "new", displayName: "New", now: t0)
        #expect(first.id == second.id)
        #expect(try await store.user(id: first.id)?.username == "new")
        let other = try await store.upsertUser(robloxUserID: 43, username: "x", displayName: "X", now: t0)
        #expect(other.id != first.id)
    }

    @Test(arguments: StoreFactory.allCases)
    func oauthAttemptIsSingleUseUnderConcurrency(factory: StoreFactory) async throws {
        guard let store = try await factory.make() else { return }
        let state = "state-\(UUID())"
        try await store.saveOAuthAttempt(OAuthAttempt(state: state, codeVerifier: "v", createdAt: t0))
        let winners = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<25 { group.addTask { try await store.consumeOAuthAttempt(state: state) != nil } }
            return try await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(winners == 1)
    }

    @Test(arguments: StoreFactory.allCases)
    func expiredAttemptsAreDeleted(factory: StoreFactory) async throws {
        guard let store = try await factory.make() else { return }
        let old = "old-\(UUID())", fresh = "fresh-\(UUID())"
        try await store.saveOAuthAttempt(OAuthAttempt(state: old, codeVerifier: "v", createdAt: t0))
        try await store.saveOAuthAttempt(OAuthAttempt(state: fresh, codeVerifier: "v", createdAt: t0.addingTimeInterval(600)))
        try await store.deleteOAuthAttempts(createdBefore: t0.addingTimeInterval(300))
        #expect(try await store.consumeOAuthAttempt(state: old) == nil)
        #expect(try await store.consumeOAuthAttempt(state: fresh) != nil)
    }

    @Test(arguments: StoreFactory.allCases)
    func grantCompareAndSwap(factory: StoreFactory) async throws {
        guard let store = try await factory.make() else { return }
        let user = try await store.upsertUser(robloxUserID: Int64.random(in: 1...1_000_000_000), username: "u", displayName: "U", now: t0)
        try await store.saveGrant(sampleGrant(user: user.id, refreshHash: "h1"))
        // Concurrent rotations of the same token: exactly one may win.
        let wins = try await withThrowingTaskGroup(of: Bool.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try await store.replaceGrant(self.sampleGrant(user: user.id, refreshHash: "h2-\(index)"),
                                                 expectedRefreshTokenHash: "h1")
                }
            }
            return try await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(wins == 1)
        let stored = try #require(try await store.grant(userID: user.id))
        #expect(stored.refreshTokenHash.hasPrefix("h2-"))
        #expect(stored.universeIDs == [1, 2])
    }

    @Test(arguments: StoreFactory.allCases)
    func sessionCodeIsSingleUseAndExpires(factory: StoreFactory) async throws {
        guard let store = try await factory.make() else { return }
        let user = try await store.upsertUser(robloxUserID: Int64.random(in: 1...1_000_000_000), username: "u", displayName: "U", now: t0)
        let live = "code-\(UUID())", expired = "code-\(UUID())"
        try await store.saveSessionCode(hash: live, userID: user.id, expiresAt: t0.addingTimeInterval(120))
        try await store.saveSessionCode(hash: expired, userID: user.id, expiresAt: t0.addingTimeInterval(-1))
        #expect(try await store.consumeSessionCode(hash: live, now: t0) == user.id)
        #expect(try await store.consumeSessionCode(hash: live, now: t0) == nil)
        #expect(try await store.consumeSessionCode(hash: expired, now: t0) == nil)
    }

    @Test(arguments: StoreFactory.allCases)
    func sessionRotationSucceedsOnce(factory: StoreFactory) async throws {
        guard let store = try await factory.make() else { return }
        let user = try await store.upsertUser(robloxUserID: Int64.random(in: 1...1_000_000_000), username: "u", displayName: "U", now: t0)
        let original = sampleSession(user: user.id)
        try await store.insertSession(original)
        let wins = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    let next = self.sampleSession(user: user.id, family: original.familyID)
                    return try await store.rotateSession(oldSessionID: original.id, newSession: next, now: self.t0)
                }
            }
            return try await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(wins == 1)
        #expect(try await store.session(refreshTokenHash: original.refreshTokenHash)?.rotatedAt != nil)
    }

    @Test(arguments: StoreFactory.allCases)
    func familyRevocation(factory: StoreFactory) async throws {
        guard let store = try await factory.make() else { return }
        let user = try await store.upsertUser(robloxUserID: Int64.random(in: 1...1_000_000_000), username: "u", displayName: "U", now: t0)
        let family = UUID()
        let a = sampleSession(user: user.id, family: family)
        let b = sampleSession(user: user.id, family: family)
        let other = sampleSession(user: user.id)
        for session in [a, b, other] { try await store.insertSession(session) }
        try await store.revokeSessionFamily(familyID: family, now: t0)
        #expect(try await store.session(accessTokenHash: a.accessTokenHash)?.revokedAt != nil)
        #expect(try await store.session(accessTokenHash: b.accessTokenHash)?.revokedAt != nil)
        #expect(try await store.session(accessTokenHash: other.accessTokenHash)?.revokedAt == nil)
        try await store.revokeSessions(userID: user.id, now: t0)
        #expect(try await store.session(accessTokenHash: other.accessTokenHash)?.revokedAt != nil)
        // Rotating a revoked session fails.
        #expect(try await store.rotateSession(oldSessionID: other.id, newSession: sampleSession(user: user.id), now: t0) == false)
    }

    @Test(arguments: StoreFactory.allCases)
    func samplesAreIdempotentAndQueryable(factory: StoreFactory) async throws {
        guard let store = try await factory.make() else { return }
        let universe = Int64.random(in: 1...1_000_000_000)
        try await store.appendSamples([
            MetricSample(universeID: universe, metric: .ccu, time: t0, value: 10),
            MetricSample(universeID: universe, metric: .ccu, time: t0.addingTimeInterval(60), value: 20),
            MetricSample(universeID: universe, metric: .visits, time: t0, value: 999),
        ])
        // Retried poll for the same timestamp replaces rather than duplicates.
        try await store.appendSamples([MetricSample(universeID: universe, metric: .ccu, time: t0.addingTimeInterval(60), value: 25)])
        let points = try await store.samples(universeID: universe, metric: .ccu, from: t0, to: t0.addingTimeInterval(60))
        #expect(points.map(\.value) == [10, 25])
        let latest = try await store.latestSample(universeIDs: [universe, -1], metric: .ccu, atOrBefore: t0.addingTimeInterval(30))
        #expect(latest[universe]?.value == 10)
        #expect(latest[-1] == nil)
        try await store.deleteSamples(before: t0.addingTimeInterval(1))
        #expect(try await store.samples(universeID: universe, metric: .ccu, from: .distantPast, to: .distantFuture).count == 1)
    }

    @Test(arguments: StoreFactory.allCases)
    func flagsGamesGoalsDevices(factory: StoreFactory) async throws {
        guard let store = try await factory.make() else { return }
        let user = try await store.upsertUser(robloxUserID: Int64.random(in: 1...1_000_000_000), username: "u", displayName: "U", now: t0)
        try await store.setFavourite(userID: user.id, universeID: 7, value: true)
        try await store.setWorkingOn(userID: user.id, universeID: 7, value: true)
        try await store.setFavourite(userID: user.id, universeID: 7, value: false)
        #expect(try await store.flags(userID: user.id)[7] == GameFlags(isFavourite: false, isWorkingOn: true))

        let universe = Int64.random(in: 1...1_000_000_000)
        try await store.upsertGameInfo([GameInfo(universeID: universe, rootPlaceID: 5, name: "A", updatedAt: t0)])
        try await store.upsertGameInfo([GameInfo(universeID: universe, rootPlaceID: 5, name: "B", updatedAt: t0)])
        #expect(try await store.gameInfo(universeIDs: [universe, -5])[universe]?.name == "B")

        let goal = Goal(title: "g", gameID: universe, metric: .ccu, startValue: 0, targetValue: 10, createdAt: t0)
        try await store.saveGoal(userID: user.id, goal: goal)
        var edited = goal
        edited.title = "edited"
        try await store.saveGoal(userID: user.id, goal: edited)
        #expect(try await store.goals(userID: user.id) == [edited])

        try await store.saveDevice(DeviceRecord(userID: user.id, token: "tok-\(universe)", sandbox: true, updatedAt: t0))
        #expect(try await store.devices(userID: user.id).count == 1)
        try await store.deleteDevice(token: "tok-\(universe)")
        #expect(try await store.devices(userID: user.id).isEmpty)
    }

    @Test(arguments: StoreFactory.allCases)
    func alertRulesStateAndEvents(factory: StoreFactory) async throws {
        guard let store = try await factory.make() else { return }
        let owner = try await store.upsertUser(robloxUserID: Int64.random(in: 1...1_000_000_000), username: "o", displayName: "O", now: t0)
        let stranger = try await store.upsertUser(robloxUserID: Int64.random(in: 1...1_000_000_000), username: "s", displayName: "S", now: t0)
        let rule = AlertRule(gameID: 9, metric: .ccu, condition: .dropFrom(fraction: 0.3, window: 3_600))
        try await store.saveAlertRule(userID: owner.id, rule: rule)
        #expect(try await store.alertRules(userID: owner.id) == [rule])
        #expect(try await store.enabledAlertRules().contains(OwnedAlertRule(userID: owner.id, rule: rule)))

        #expect(try await store.alertState(ruleID: rule.id) == AlertRuleState())
        let state = AlertRuleState(conditionWasMet: true, lastFiredAt: t0)
        try await store.saveAlertState(ruleID: rule.id, state: state)
        #expect(try await store.alertState(ruleID: rule.id) == state)

        for offset in 0..<5 {
            try await store.appendAlertEvent(userID: owner.id, event: AlertEvent(
                ruleID: rule.id, gameID: 9, metric: .ccu, value: Double(offset), firedAt: t0.addingTimeInterval(Double(offset))))
        }
        #expect(try await store.recentAlertEvents(userID: owner.id, limit: 2).map(\.value) == [4, 3])

        #expect(try await store.alertRuleOwner(ruleID: rule.id) == owner.id)
        #expect(try await store.alertRuleOwner(ruleID: UUID()) == nil)
        #expect(try await store.deleteAlertRule(userID: stranger.id, ruleID: rule.id) == false)
        #expect(try await store.deleteAlertRule(userID: owner.id, ruleID: rule.id))
        #expect(try await store.alertRules(userID: owner.id).isEmpty)
    }

    @Test(arguments: StoreFactory.allCases)
    func deleteUserRemovesEverything(factory: StoreFactory) async throws {
        guard let store = try await factory.make() else { return }
        let user = try await store.upsertUser(robloxUserID: Int64.random(in: 1...1_000_000_000), username: "u", displayName: "U", now: t0)
        let session = sampleSession(user: user.id)
        try await store.insertSession(session)
        try await store.saveGrant(sampleGrant(user: user.id, refreshHash: "h"))
        try await store.saveAlertRule(userID: user.id, rule: AlertRule(gameID: 1, metric: .ccu, condition: .above(1)))
        try await store.saveDevice(DeviceRecord(userID: user.id, token: "t-\(user.id)", sandbox: false, updatedAt: t0))
        try await store.deleteUser(id: user.id)
        #expect(try await store.user(id: user.id) == nil)
        #expect(try await store.grant(userID: user.id) == nil)
        #expect(try await store.session(accessTokenHash: session.accessTokenHash) == nil)
        #expect(try await store.alertRules(userID: user.id).isEmpty)
        #expect(try await store.devices(userID: user.id).isEmpty)
    }
}

/// Postgres access for tests: enabled only when `TEST_DATABASE_URL` is set.
enum TestPostgres {
    static func makeStore() async throws -> (any Store)? {
        nil  // Replaced when PostgresStore lands.
    }
}
