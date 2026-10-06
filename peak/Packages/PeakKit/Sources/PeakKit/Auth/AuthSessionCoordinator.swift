import Foundation

/// An Peak backend session. Roblox tokens never reach the device (decision 0003).
public struct AuthTokens: Codable, Hashable, Sendable {
    public var accessToken: String
    /// Rotating: each refresh returns a new refresh token and invalidates the old one.
    public var refreshToken: String
    public var accessTokenExpiresAt: Date

    public init(accessToken: String, refreshToken: String, accessTokenExpiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
    }
}

public enum AuthError: Error, Hashable, Sendable {
    /// No session stored, or the user signed out while a request was in flight.
    case signedOut
    /// The backend rejected the refresh token (revoked, reused or expired). The session is cleared
    /// and the user must reconnect Roblox.
    case sessionExpired
}

/// Thrown by a `TokenRefresher` when the server says the refresh token itself is no longer valid,
/// as opposed to a transient network or server failure that's worth retrying later.
public struct RefreshTokenRejected: Error, Hashable, Sendable {
    public init() {}
}

public protocol TokenStore: Sendable {
    func load() async throws -> AuthTokens?
    func save(_ tokens: AuthTokens) async throws
    func clear() async throws
}

public protocol TokenRefresher: Sendable {
    func refresh(using refreshToken: String) async throws -> AuthTokens
}

/// Owns the session and serialises refresh.
///
/// Refresh tokens rotate, so two concurrent refreshes would race: the second uses a refresh token
/// the first just invalidated, and the server may treat that reuse as theft and revoke everything.
/// So there is at most one refresh in flight, every caller that needs a fresh token awaits the same
/// task, and the new pair is persisted before anyone receives it.
public actor AuthSessionCoordinator {
    private let store: any TokenStore
    private let refresher: any TokenRefresher
    private let now: @Sendable () -> Date
    private let refreshLeeway: TimeInterval

    private var cached: AuthTokens?
    private var hasLoaded = false
    private var inFlightRefresh: Task<AuthTokens, any Error>?
    /// Bumped on sign-in and sign-out so a refresh that finishes afterwards can't resurrect or
    /// overwrite a session it no longer belongs to.
    private var generation = 0

    public init(
        store: any TokenStore,
        refresher: any TokenRefresher,
        refreshLeeway: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.refresher = refresher
        self.refreshLeeway = refreshLeeway
        self.now = now
    }

    public func isSignedIn() async -> Bool {
        (try? await currentTokens()) != nil
    }

    public func signIn(with tokens: AuthTokens) async throws {
        generation += 1
        inFlightRefresh?.cancel()
        inFlightRefresh = nil
        try await store.save(tokens)
        cached = tokens
        hasLoaded = true
    }

    public func signOut() async {
        generation += 1
        inFlightRefresh?.cancel()
        inFlightRefresh = nil
        cached = nil
        hasLoaded = true
        try? await store.clear()
    }

    /// A non-expired access token, refreshing first if it expires within the leeway.
    public func validAccessToken() async throws -> String {
        guard let tokens = try await currentTokens() else { throw AuthError.signedOut }
        if tokens.accessTokenExpiresAt.timeIntervalSince(now()) > refreshLeeway {
            return tokens.accessToken
        }
        return try await refreshedTokens(from: tokens).accessToken
    }

    /// Call after the server answered 401 to a request made with `failedAccessToken`.
    /// If another caller already rotated the session, returns the newer token without refreshing again.
    public func accessTokenAfterUnauthorized(failedAccessToken: String) async throws -> String {
        guard let tokens = try await currentTokens() else { throw AuthError.signedOut }
        if tokens.accessToken != failedAccessToken {
            return tokens.accessToken
        }
        return try await refreshedTokens(from: tokens).accessToken
    }

    // MARK: - Private

    private func currentTokens() async throws -> AuthTokens? {
        if hasLoaded { return cached }
        let loaded = try await store.load()
        // Re-check after the await: a concurrent sign-in/out may have set state meanwhile.
        if hasLoaded == false {
            cached = loaded
            hasLoaded = true
        }
        return cached
    }

    private func refreshedTokens(from tokens: AuthTokens) async throws -> AuthTokens {
        if let inFlightRefresh {
            return try await inFlightRefresh.value
        }

        let refreshGeneration = generation
        // The one deliberate unstructured task here: it belongs to the actor rather than to any single
        // caller, so a cancelled caller (a view that disappeared) can't abort a refresh others await.
        let task = Task<AuthTokens, any Error> {
            do {
                let fresh = try await refresher.refresh(using: tokens.refreshToken)
                try await commit(fresh, generation: refreshGeneration)
                return fresh
            } catch is RefreshTokenRejected {
                await expireSession(generation: refreshGeneration)
                throw AuthError.sessionExpired
            }
        }
        inFlightRefresh = task
        defer {
            // Only clear our own task; sign-in/out may already have replaced or cleared it.
            if generation == refreshGeneration { inFlightRefresh = nil }
        }
        return try await task.value
    }

    private func commit(_ tokens: AuthTokens, generation refreshGeneration: Int) async throws {
        guard generation == refreshGeneration else { throw AuthError.signedOut }
        // The server has already rotated: the old refresh token is dead. If persisting fails we still
        // keep the new pair in memory, because dropping it would end the session immediately; the
        // worst case is a re-login on next launch.
        try? await store.save(tokens)
        // Re-check after the await: sign-out may have happened while saving.
        guard generation == refreshGeneration else {
            try? await store.clear()
            throw AuthError.signedOut
        }
        cached = tokens
    }

    private func expireSession(generation refreshGeneration: Int) async {
        guard generation == refreshGeneration else { return }
        generation += 1
        inFlightRefresh = nil
        cached = nil
        hasLoaded = true
        try? await store.clear()
    }
}

/// Process-lifetime store for tests, previews and demo mode.
public actor InMemoryTokenStore: TokenStore {
    private var tokens: AuthTokens?

    public init(tokens: AuthTokens? = nil) {
        self.tokens = tokens
    }

    public func load() async throws -> AuthTokens? { tokens }
    public func save(_ tokens: AuthTokens) async throws { self.tokens = tokens }
    public func clear() async throws { tokens = nil }
}
