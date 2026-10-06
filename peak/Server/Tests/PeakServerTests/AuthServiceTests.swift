import Foundation
import PeakKit
import Testing
@testable import PeakServerCore

struct AuthServiceTests {
    let store = InMemoryStore()
    let oauth = FakeRobloxOAuth()
    let clock = TestClock()

    var service: AuthService {
        AuthService(store: store, oauth: oauth, box: TestKeys.box,
                    appCallbackURL: URL(string: "peakstats://auth/complete")!, now: clock.function)
    }

    func state(from url: URL) throws -> String {
        try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
    }

    func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    /// Runs the whole sign-in and returns the app's tokens.
    func signIn() async throws -> AuthTokens {
        let state = try state(from: try await service.startAuthorization())
        let redirect = await service.completeAuthorization(code: "good-code", state: state, error: nil)
        let code = try #require(query(redirect, "code"))
        return try await service.exchangeSessionCode(code)
    }

    @Test func happyPathSignsInAndStoresSealedGrant() async throws {
        let authorize = try await service.startAuthorization()
        let state = try state(from: authorize)
        let redirect = await service.completeAuthorization(code: "good-code", state: state, error: nil)
        #expect(redirect.scheme == "peakstats")
        let code = try #require(query(redirect, "code"))
        #expect(code.hasPrefix("pk_sc_"))
        // The redirect parses as the app's deep link.
        #expect(Route(url: redirect) == .authComplete(code: code))

        // PKCE verifier sent at exchange matches the challenge in the authorize URL.
        let challenge = try #require(query(authorize, "code_challenge"))
        let verifier = try #require(await oauth.exchangeCalls.first?.verifier)
        #expect(Secrets.PKCE.challenge(for: verifier) == challenge)

        let tokens = try await service.exchangeSessionCode(code)
        #expect(tokens.accessToken.hasPrefix("pk_at_"))
        #expect(tokens.refreshToken.hasPrefix("pk_rt_"))
        #expect(tokens.accessTokenExpiresAt == clock.now.addingTimeInterval(AuthService.accessTokenLifetime))

        let auth = try await service.authenticate(accessToken: tokens.accessToken)
        let grant = try #require(try await store.grant(userID: auth.userID))
        #expect(grant.universeIDs == [3_828_411_582])
        #expect(try TestKeys.box.open(grant.refreshTokenSealed) == "roblox-rt-1")
        #expect(grant.refreshTokenSealed != Data("roblox-rt-1".utf8), "stored sealed, not plaintext")
        #expect(try await store.user(id: auth.userID)?.robloxUserID == 1_516_563_360)
    }

    @Test func callbackStateIsSingleUse() async throws {
        let state = try state(from: try await service.startAuthorization())
        _ = await service.completeAuthorization(code: "good-code", state: state, error: nil)
        let replay = await service.completeAuthorization(code: "good-code", state: state, error: nil)
        #expect(query(replay, "error") == "invalid_state")
        #expect(await oauth.exchangeCalls.count == 1)
    }

    @Test(arguments: [
        (nil, "s", nil, "invalid_request"),
        ("c", nil, nil, "invalid_request"),
        ("c", "unknown-state", nil, "invalid_state"),
        (nil, nil, "access_denied", "access_denied"),
        (nil, nil, "<script>", "authorization_failed"),
    ] as [(String?, String?, String?, String)])
    func callbackFailuresRedirectWithSafeCode(code: String?, state: String?, error: String?, expected: String) async {
        let redirect = await service.completeAuthorization(code: code, state: state, error: error)
        #expect(query(redirect, "error") == expected)
        #expect(query(redirect, "code") == nil)
        #expect(await oauth.exchangeCalls.isEmpty)
    }

    @Test func expiredAttemptIsRejected() async throws {
        let state = try state(from: try await service.startAuthorization())
        clock.advance(AuthService.attemptLifetime + 1)
        let redirect = await service.completeAuthorization(code: "good-code", state: state, error: nil)
        #expect(query(redirect, "error") == "expired")
    }

    @Test func badCodeFromRobloxIsReported() async throws {
        let state = try state(from: try await service.startAuthorization())
        let redirect = await service.completeAuthorization(code: "bad-code", state: state, error: nil)
        #expect(query(redirect, "error") == "invalid_grant")
    }

    @Test func sessionCodeIsSingleUseAndShortLived() async throws {
        let state = try state(from: try await service.startAuthorization())
        let code = try #require(query(await service.completeAuthorization(code: "good-code", state: state, error: nil), "code"))
        _ = try await service.exchangeSessionCode(code)
        await #expect(throws: SessionError.invalidCode) { try await service.exchangeSessionCode(code) }

        let state2 = try self.state(from: try await service.startAuthorization())
        let code2 = try #require(query(await service.completeAuthorization(code: "good-code", state: state2, error: nil), "code"))
        clock.advance(AuthService.sessionCodeLifetime + 1)
        await #expect(throws: SessionError.invalidCode) { try await service.exchangeSessionCode(code2) }
        await #expect(throws: SessionError.invalidCode) { try await service.exchangeSessionCode("not-a-code") }
    }

    @Test func refreshRotatesAndOldTokensStopWorking() async throws {
        let first = try await signIn()
        let second = try await service.refresh(refreshToken: first.refreshToken)
        #expect(second.refreshToken != first.refreshToken)
        #expect(second.accessToken != first.accessToken)
        _ = try await service.authenticate(accessToken: second.accessToken)
        await #expect(throws: SessionError.invalidAccessToken) { try await service.authenticate(accessToken: first.accessToken) }
    }

    @Test func refreshTokenReuseRevokesWholeFamily() async throws {
        let first = try await signIn()
        let second = try await service.refresh(refreshToken: first.refreshToken)
        // An attacker (or a buggy client) replays the old refresh token...
        await #expect(throws: SessionError.invalidRefreshToken) { try await service.refresh(refreshToken: first.refreshToken) }
        // ...and the legitimate newer session is revoked too.
        await #expect(throws: SessionError.invalidAccessToken) { try await service.authenticate(accessToken: second.accessToken) }
        await #expect(throws: SessionError.invalidRefreshToken) { try await service.refresh(refreshToken: second.refreshToken) }
    }

    @Test func concurrentRefreshWithSameTokenYieldsAtMostOneSuccess() async throws {
        let first = try await signIn()
        let successes = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 {
                group.addTask { (try? await self.service.refresh(refreshToken: first.refreshToken)) != nil }
            }
            return try await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(successes <= 1)
    }

    @Test func expiredTokensRejected() async throws {
        let tokens = try await signIn()
        clock.advance(AuthService.accessTokenLifetime + 1)
        await #expect(throws: SessionError.invalidAccessToken) { try await service.authenticate(accessToken: tokens.accessToken) }
        _ = try await service.refresh(refreshToken: tokens.refreshToken)  // refresh still valid

        let other = try await signIn()
        clock.advance(AuthService.refreshTokenLifetime + 1)
        await #expect(throws: SessionError.invalidRefreshToken) { try await service.refresh(refreshToken: other.refreshToken) }
    }

    @Test(arguments: ["", "pk_at_unknown", "Bearer x", String(repeating: "a", count: 10_000)])
    func garbageAccessTokens(token: String) async {
        await #expect(throws: SessionError.invalidAccessToken) { try await service.authenticate(accessToken: token) }
    }

    @Test func logoutRevokesOnlyThisDevice() async throws {
        let phone = try await signIn()
        let tablet = try await signIn()
        let auth = try await service.authenticate(accessToken: phone.accessToken)
        try await service.logout(auth)
        await #expect(throws: SessionError.invalidAccessToken) { try await service.authenticate(accessToken: phone.accessToken) }
        _ = try await service.authenticate(accessToken: tablet.accessToken)
    }

    @Test func deleteAccountRevokesRobloxAndRemovesData() async throws {
        let tokens = try await signIn()
        let auth = try await service.authenticate(accessToken: tokens.accessToken)
        try await service.deleteAccount(userID: auth.userID)
        #expect(await oauth.revoked == ["roblox-rt-1"])
        #expect(try await store.user(id: auth.userID) == nil)
        await #expect(throws: SessionError.invalidAccessToken) { try await service.authenticate(accessToken: tokens.accessToken) }
    }
}

struct RobloxTokenManagerTests {
    let store = InMemoryStore()
    let oauth = FakeRobloxOAuth()
    let clock = TestClock()

    func seedGrant(expiresIn: TimeInterval) async throws -> UUID {
        let user = try await store.upsertUser(robloxUserID: 1, username: "u", displayName: "U", now: clock.now)
        let tokens = RobloxTokenSet(accessToken: "seed-at", refreshToken: "seed-rt", expiresIn: Int(expiresIn), scope: "openid")
        try await store.saveGrant(try RobloxTokenManager.makeGrant(userID: user.id, tokens: tokens, universeIDs: [7],
                                                                    box: TestKeys.box, now: clock.now))
        return user.id
    }

    var manager: RobloxTokenManager {
        RobloxTokenManager(store: store, oauth: oauth, box: TestKeys.box, now: clock.function)
    }

    @Test func validTokenNeedsNoRefresh() async throws {
        let user = try await seedGrant(expiresIn: 600)
        #expect(try await manager.accessToken(userID: user) == "seed-at")
        #expect(await oauth.refreshCalls.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentCallersShareOneRefresh() async throws {
        let user = try await seedGrant(expiresIn: 30)  // inside the 60 s leeway
        let gate = Gate()
        await oauth.setRefreshGate(gate)
        let manager = self.manager
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<50 { group.addTask { try await manager.accessToken(userID: user) } }
            while await oauth.refreshCalls.isEmpty { await Task.yield() }
            for _ in 0..<200 { await Task.yield() }
            await gate.open()
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }
        #expect(Set(tokens) == ["roblox-at-1"])
        #expect(await oauth.refreshCalls == ["seed-rt"])
        let grant = try #require(try await store.grant(userID: user))
        #expect(try TestKeys.box.open(grant.refreshTokenSealed) == "roblox-rt-1")
        #expect(grant.universeIDs == [7], "rotation keeps the granted universes")
    }

    @Test func rejectedRefreshRequiresReconnect() async throws {
        let user = try await seedGrant(expiresIn: 0)
        await oauth.setRefreshBehaviour(.failure(.invalidGrant))
        await #expect(throws: RobloxAuthError.reconnectRequired) { try await manager.accessToken(userID: user) }
        #expect(try await store.grant(userID: user) == nil)
    }

    @Test func anotherInstanceRotatedFirst() async throws {
        let user = try await seedGrant(expiresIn: 0)
        // Simulate another server instance spending the token and storing a newer pair while our refresh
        // is in flight: Roblox then rejects ours.
        let newer = try RobloxTokenManager.makeGrant(
            userID: user, tokens: RobloxTokenSet(accessToken: "other-at", refreshToken: "other-rt", expiresIn: 899, scope: nil),
            universeIDs: [7], box: TestKeys.box, now: clock.now)
        let gate = Gate()
        await oauth.setRefreshGate(gate)
        await oauth.setRefreshBehaviour(.failure(.invalidGrant))
        let manager = self.manager
        let pending = Task { try await manager.accessToken(userID: user) }
        while await oauth.refreshCalls.isEmpty { await Task.yield() }
        try await store.saveGrant(newer)
        await gate.open()
        #expect(try await pending.value == "other-at")
        #expect(try await store.grant(userID: user) != nil, "must not delete the other instance's grant")
    }

    @Test func noGrantRequiresReconnect() async {
        await #expect(throws: RobloxAuthError.reconnectRequired) { try await manager.accessToken(userID: UUID()) }
    }
}
