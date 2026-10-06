import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PeakKit

struct AuthSessionCoordinatorTests {
    let now = Fixtures.now
    let future = Fixtures.now.addingTimeInterval(3_600)

    func coordinator(stored: AuthTokens?, refresher: FakeRefresher,
                     store: RecordingTokenStore? = nil) -> (AuthSessionCoordinator, RecordingTokenStore) {
        let store = store ?? RecordingTokenStore(tokens: stored)
        let fixedNow = now
        return (AuthSessionCoordinator(store: store, refresher: refresher, refreshLeeway: 60, now: { fixedNow }), store)
    }

    /// Waits until the refresher has been entered `count` times, yielding so other tasks can pile up.
    func waitForRefreshCalls(_ refresher: FakeRefresher, count: Int) async {
        while await refresher.callCount < count {
            await Task.yield()
        }
    }

    @Test func validTokenIsReturnedWithoutRefreshing() async throws {
        let refresher = FakeRefresher(expiresAt: future)
        let (sut, _) = coordinator(stored: Fixtures.tokens("old", expiresIn: 600), refresher: refresher)
        #expect(try await sut.validAccessToken() == "access-old")
        #expect(await refresher.callCount == 0)
    }

    @Test func tokenInsideLeewayIsRefreshed() async throws {
        let refresher = FakeRefresher(expiresAt: future)
        let (sut, store) = coordinator(stored: Fixtures.tokens("old", expiresIn: 60), refresher: refresher)
        #expect(try await sut.validAccessToken() == "access-1")
        #expect(await refresher.receivedRefreshTokens == ["refresh-old"])
        #expect(await store.tokens?.refreshToken == "refresh-1")
    }

    @Test func noStoredSessionThrowsSignedOut() async {
        let (sut, _) = coordinator(stored: nil, refresher: FakeRefresher(expiresAt: future))
        await #expect(throws: AuthError.signedOut) { try await sut.validAccessToken() }
        #expect(await sut.isSignedIn() == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentCallersShareOneRefresh() async throws {
        let gate = Gate()
        let refresher = FakeRefresher(gate: gate, expiresAt: future)
        let (sut, store) = coordinator(stored: Fixtures.tokens("old", expiresIn: -10), refresher: refresher)

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<100 {
                group.addTask { try await sut.validAccessToken() }
            }
            // Hold the refresh open until it has started, then let everyone else pile up behind it.
            await waitForRefreshCalls(refresher, count: 1)
            for _ in 0..<200 { await Task.yield() }
            await gate.open()
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }

        #expect(tokens.count == 100)
        #expect(Set(tokens) == ["access-1"])
        #expect(await refresher.callCount == 1)
        #expect(await store.saveCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentUnauthorizedWithSameTokenRefreshesOnce() async throws {
        let gate = Gate()
        let refresher = FakeRefresher(gate: gate, expiresAt: future)
        let (sut, _) = coordinator(stored: Fixtures.tokens("old", expiresIn: 600), refresher: refresher)

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<50 {
                group.addTask { try await sut.accessTokenAfterUnauthorized(failedAccessToken: "access-old") }
            }
            await waitForRefreshCalls(refresher, count: 1)
            for _ in 0..<200 { await Task.yield() }
            await gate.open()
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }
        #expect(Set(tokens) == ["access-1"])
        #expect(await refresher.callCount == 1)
    }

    @Test func unauthorizedWithAlreadyRotatedTokenDoesNotRefreshAgain() async throws {
        let refresher = FakeRefresher(expiresAt: future)
        let (sut, _) = coordinator(stored: Fixtures.tokens("old", expiresIn: 600), refresher: refresher)
        let first = try await sut.accessTokenAfterUnauthorized(failedAccessToken: "access-old")
        // A slow request that was sent with the old token comes back 401 after the rotation.
        let late = try await sut.accessTokenAfterUnauthorized(failedAccessToken: "access-old")
        #expect(first == "access-1")
        #expect(late == "access-1")
        #expect(await refresher.callCount == 1)
    }

    @Test func rejectedRefreshExpiresSessionForEveryone() async throws {
        let gate = Gate()
        let refresher = FakeRefresher(behaviour: .reject, gate: gate, expiresAt: future)
        let (sut, store) = coordinator(stored: Fixtures.tokens("old", expiresIn: -1), refresher: refresher)

        let errors = await withTaskGroup(of: (any Error)?.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    do { _ = try await sut.validAccessToken(); return nil } catch { return error }
                }
            }
            await waitForRefreshCalls(refresher, count: 1)
            await gate.open()
            return await group.reduce(into: [(any Error)?]()) { $0.append($1) }
        }

        #expect(errors.allSatisfy { ($0 as? AuthError) == .sessionExpired })
        #expect(await refresher.callCount == 1)
        #expect(await store.tokens == nil)
        await #expect(throws: AuthError.signedOut) { try await sut.validAccessToken() }
        #expect(await refresher.callCount == 1)
    }

    @Test func transientFailureKeepsSessionAndAllowsRetry() async throws {
        let refresher = FakeRefresher(behaviour: .fail(.notConnectedToInternet), expiresAt: future)
        let (sut, store) = coordinator(stored: Fixtures.tokens("old", expiresIn: -1), refresher: refresher)

        await #expect(throws: URLError.self) { try await sut.validAccessToken() }
        #expect(await store.tokens?.refreshToken == "refresh-old")

        await refresher.setBehaviour(.succeed)
        #expect(try await sut.validAccessToken() == "access-2")
        #expect(await refresher.receivedRefreshTokens == ["refresh-old", "refresh-old"])
    }

    @Test func signOutDuringRefreshDiscardsTheResult() async throws {
        let gate = Gate()
        let refresher = FakeRefresher(gate: gate, expiresAt: future)
        let (sut, store) = coordinator(stored: Fixtures.tokens("old", expiresIn: -1), refresher: refresher)

        let pending = Task { try await sut.validAccessToken() }
        await waitForRefreshCalls(refresher, count: 1)
        await sut.signOut()
        await gate.open()

        await #expect(throws: (any Error).self) { try await pending.value }
        #expect(await store.tokens == nil)
        #expect(await sut.isSignedIn() == false)
    }

    @Test func signInDuringRefreshIsNotOverwritten() async throws {
        let gate = Gate()
        let refresher = FakeRefresher(gate: gate, expiresAt: future)
        let (sut, store) = coordinator(stored: Fixtures.tokens("old", expiresIn: -1), refresher: refresher)

        let pending = Task { try await sut.validAccessToken() }
        await waitForRefreshCalls(refresher, count: 1)
        try await sut.signIn(with: Fixtures.tokens("new-account", expiresIn: 3_600))
        await gate.open()
        _ = try? await pending.value

        #expect(await store.tokens?.accessToken == "access-new-account")
        #expect(try await sut.validAccessToken() == "access-new-account")
    }

    @Test func cancelledCallerDoesNotAbortSharedRefresh() async throws {
        let gate = Gate()
        let refresher = FakeRefresher(gate: gate, expiresAt: future)
        let (sut, _) = coordinator(stored: Fixtures.tokens("old", expiresIn: -1), refresher: refresher)

        let first = Task { try await sut.validAccessToken() }
        await waitForRefreshCalls(refresher, count: 1)
        let second = Task { try await sut.validAccessToken() }
        for _ in 0..<50 { await Task.yield() }
        first.cancel()
        await gate.open()

        #expect(try await second.value == "access-1")
        #expect(await refresher.callCount == 1)
    }

    @Test func failedPersistenceStillKeepsRotatedSessionInMemory() async throws {
        let refresher = FakeRefresher(expiresAt: future)
        let store = RecordingTokenStore(tokens: Fixtures.tokens("old", expiresIn: -1))
        await store.setFailSaves(true)
        let (sut, _) = coordinator(stored: nil, refresher: refresher, store: store)

        #expect(try await sut.validAccessToken() == "access-1")
        // Second call uses the in-memory pair rather than re-sending the dead refresh token.
        #expect(try await sut.validAccessToken() == "access-1")
        #expect(await refresher.callCount == 1)
    }

    @Test func signInPersistsAndSignOutClears() async throws {
        let (sut, store) = coordinator(stored: nil, refresher: FakeRefresher(expiresAt: future))
        try await sut.signIn(with: Fixtures.tokens("a", expiresIn: 3_600))
        #expect(await store.tokens?.accessToken == "access-a")
        #expect(await sut.isSignedIn())
        await sut.signOut()
        #expect(await store.tokens == nil)
        #expect(await sut.isSignedIn() == false)
    }
}
