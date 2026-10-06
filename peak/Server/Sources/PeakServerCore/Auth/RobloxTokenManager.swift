import Foundation

public enum RobloxAuthError: Error, Hashable, Sendable {
    /// No grant, or Roblox rejected the refresh token: the creator must reconnect Roblox.
    case reconnectRequired
}

/// Hands out valid Roblox access tokens per user.
///
/// Roblox refresh tokens are single-use (oauth2-reference: "Can only be used once"). Two refreshes with the
/// same token means the second fails and, worse, the session may be lost. Two layers prevent that:
/// - in-process: at most one refresh `Task` per user; concurrent callers await it;
/// - across instances: the new pair is written with compare-and-swap on the old refresh-token hash; the
///   loser re-reads the winner's tokens instead of failing.
public actor RobloxTokenManager {
    private let store: any Store
    private let oauth: any RobloxOAuth
    private let box: SecretBox
    private let now: @Sendable () -> Date
    private let leeway: TimeInterval
    private var inFlight: [UUID: Task<String, any Error>] = [:]

    public init(store: any Store, oauth: any RobloxOAuth, box: SecretBox, leeway: TimeInterval = 60,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.oauth = oauth
        self.box = box
        self.leeway = leeway
        self.now = now
    }

    /// Seals and stores a freshly issued token set.
    public static func makeGrant(userID: UUID, tokens: RobloxTokenSet, universeIDs: [Int64], box: SecretBox,
                                 now: Date) throws -> RobloxGrant {
        RobloxGrant(userID: userID,
                    accessTokenSealed: try box.seal(tokens.accessToken),
                    refreshTokenSealed: try box.seal(tokens.refreshToken),
                    refreshTokenHash: Secrets.hash(tokens.refreshToken),
                    accessTokenExpiresAt: now.addingTimeInterval(TimeInterval(tokens.expiresIn)),
                    scopes: (tokens.scope ?? "").split(separator: " ").map(String.init),
                    universeIDs: universeIDs,
                    updatedAt: now)
    }

    public func accessToken(userID: UUID) async throws -> String {
        guard let grant = try await store.grant(userID: userID) else { throw RobloxAuthError.reconnectRequired }
        if grant.accessTokenExpiresAt.timeIntervalSince(now()) > leeway {
            return try box.open(grant.accessTokenSealed)
        }
        if let task = inFlight[userID] {
            return try await task.value
        }
        // Owned by the actor, not by any single caller: one caller's cancellation (a closed connection)
        // must not abort a refresh that spends the single-use token for everyone.
        let task = Task<String, any Error> { try await self.refreshIfStillNeeded(userID: userID) }
        inFlight[userID] = task
        defer { inFlight[userID] = nil }
        return try await task.value
    }

    /// Re-reads the grant first: the one this caller loaded may predate a refresh that just finished,
    /// and spending its (already used) refresh token would fail.
    private func refreshIfStillNeeded(userID: UUID) async throws -> String {
        guard let grant = try await store.grant(userID: userID) else { throw RobloxAuthError.reconnectRequired }
        if grant.accessTokenExpiresAt.timeIntervalSince(now()) > leeway {
            return try box.open(grant.accessTokenSealed)
        }
        return try await refresh(from: grant)
    }

    private func refresh(from grant: RobloxGrant) async throws -> String {
        let refreshToken = try box.open(grant.refreshTokenSealed)
        let tokens: RobloxTokenSet
        do {
            tokens = try await oauth.refresh(refreshToken: refreshToken)
        } catch RobloxAPIError.invalidGrant {
            // Maybe another instance already spent it: if the stored token moved on, use that.
            if let current = try await store.grant(userID: grant.userID), current.refreshTokenHash != grant.refreshTokenHash {
                return try box.open(current.accessTokenSealed)
            }
            try await store.deleteGrant(userID: grant.userID)
            throw RobloxAuthError.reconnectRequired
        }

        var updated = try Self.makeGrant(userID: grant.userID, tokens: tokens, universeIDs: grant.universeIDs,
                                         box: box, now: now())
        if updated.scopes.isEmpty { updated.scopes = grant.scopes }
        if try await store.replaceGrant(updated, expectedRefreshTokenHash: grant.refreshTokenHash) {
            return tokens.accessToken
        }
        // Lost the race to another instance; its tokens are the valid ones now.
        guard let current = try await store.grant(userID: grant.userID) else { throw RobloxAuthError.reconnectRequired }
        return try box.open(current.accessTokenSealed)
    }
}
