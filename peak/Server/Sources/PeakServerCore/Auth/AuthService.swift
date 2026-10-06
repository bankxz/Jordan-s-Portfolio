import Foundation
import PeakKit

public enum SessionError: Error, Hashable, Sendable {
    case invalidCode
    case invalidRefreshToken
    case invalidAccessToken
}

/// Roblox sign-in and Peak sessions (decisions 0003, 0005).
public struct AuthService: Sendable {
    public static let attemptLifetime: TimeInterval = 10 * 60
    public static let sessionCodeLifetime: TimeInterval = 2 * 60
    public static let accessTokenLifetime: TimeInterval = 15 * 60
    public static let refreshTokenLifetime: TimeInterval = 60 * 86_400

    private let store: any Store
    private let oauth: any RobloxOAuth
    private let box: SecretBox
    private let appCallbackURL: URL
    private let now: @Sendable () -> Date

    public init(store: any Store, oauth: any RobloxOAuth, box: SecretBox, appCallbackURL: URL,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.oauth = oauth
        self.box = box
        self.appCallbackURL = appCallbackURL
        self.now = now
    }

    // MARK: Roblox OAuth

    /// Creates a single-use attempt (fresh state + PKCE) and returns the Roblox authorize URL.
    public func startAuthorization() async throws -> URL {
        let current = now()
        try await store.deleteOAuthAttempts(createdBefore: current.addingTimeInterval(-Self.attemptLifetime))
        let pkce = Secrets.PKCE.generate()
        let state = Secrets.randomToken()
        try await store.saveOAuthAttempt(OAuthAttempt(state: state, codeVerifier: pkce.verifier, createdAt: current))
        return oauth.authorizeURL(state: state, codeChallenge: pkce.challenge)
    }

    /// Handles Roblox's redirect. Always returns a URL for the app; failures carry a short error code
    /// and never echo upstream messages.
    public func completeAuthorization(code: String?, state: String?, error: String?) async -> URL {
        do {
            if let error {
                // Roblox reports e.g. access_denied when the user cancels.
                return appURL(error: error == "access_denied" ? "access_denied" : "authorization_failed")
            }
            guard let state, state.count <= 256, let code, code.isEmpty == false, code.count <= 4_096 else {
                return appURL(error: "invalid_request")
            }
            // Consume before anything else: a replayed callback finds nothing.
            guard let attempt = try await store.consumeOAuthAttempt(state: state) else {
                return appURL(error: "invalid_state")
            }
            let current = now()
            guard current.timeIntervalSince(attempt.createdAt) <= Self.attemptLifetime else {
                return appURL(error: "expired")
            }

            let tokens = try await oauth.exchange(code: code, codeVerifier: attempt.codeVerifier)
            let info = try await oauth.userInfo(accessToken: tokens.accessToken)
            let universes = try await oauth.grantedUniverseIDs(accessToken: tokens.accessToken)
            guard let robloxUserID = Int64(info.sub) else { return appURL(error: "authorization_failed") }

            let user = try await store.upsertUser(robloxUserID: robloxUserID,
                                                  username: info.preferredUsername ?? info.sub,
                                                  displayName: info.name ?? info.preferredUsername ?? info.sub,
                                                  now: current)
            let grant = try RobloxTokenManager.makeGrant(userID: user.id, tokens: tokens, universeIDs: universes,
                                                        box: box, now: current)
            try await store.saveGrant(grant)

            let sessionCode = Secrets.randomToken(prefix: "pk_sc_")
            try await store.saveSessionCode(hash: Secrets.hash(sessionCode), userID: user.id,
                                            expiresAt: current.addingTimeInterval(Self.sessionCodeLifetime))
            return appURL(code: sessionCode)
        } catch RobloxAPIError.invalidGrant {
            return appURL(error: "invalid_grant")
        } catch {
            return appURL(error: "server_error")
        }
    }

    // MARK: Peak sessions

    public func exchangeSessionCode(_ code: String) async throws -> AuthTokens {
        guard code.hasPrefix("pk_sc_"), code.count <= 128,
              let userID = try await store.consumeSessionCode(hash: Secrets.hash(code), now: now()) else {
            throw SessionError.invalidCode
        }
        let (session, tokens) = makeSession(userID: userID, familyID: UUID())
        try await store.insertSession(session)
        return tokens
    }

    /// Rotates the refresh token. Presenting a refresh token that was already rotated is treated as theft:
    /// the whole session family is revoked and the user signs in again.
    public func refresh(refreshToken: String) async throws -> AuthTokens {
        guard refreshToken.hasPrefix("pk_rt_"), refreshToken.count <= 128,
              let session = try await store.session(refreshTokenHash: Secrets.hash(refreshToken)) else {
            throw SessionError.invalidRefreshToken
        }
        let current = now()
        if session.revokedAt != nil { throw SessionError.invalidRefreshToken }
        if session.rotatedAt != nil {
            try await store.revokeSessionFamily(familyID: session.familyID, now: current)
            throw SessionError.invalidRefreshToken
        }
        guard session.refreshExpiresAt > current else { throw SessionError.invalidRefreshToken }

        let (next, tokens) = makeSession(userID: session.userID, familyID: session.familyID)
        guard try await store.rotateSession(oldSessionID: session.id, newSession: next, now: current) else {
            // Lost a race with another use of the same token: same treatment as reuse.
            try await store.revokeSessionFamily(familyID: session.familyID, now: current)
            throw SessionError.invalidRefreshToken
        }
        return tokens
    }

    public struct Authenticated: Sendable, Hashable {
        public var userID: UUID
        public var sessionFamilyID: UUID
    }

    public func authenticate(accessToken: String) async throws -> Authenticated {
        guard accessToken.hasPrefix("pk_at_"), accessToken.count <= 128,
              let session = try await store.session(accessTokenHash: Secrets.hash(accessToken)),
              session.isActive, session.accessExpiresAt > now() else {
            throw SessionError.invalidAccessToken
        }
        return Authenticated(userID: session.userID, sessionFamilyID: session.familyID)
    }

    /// Signs this device out.
    public func logout(_ auth: Authenticated) async throws {
        try await store.revokeSessionFamily(familyID: auth.sessionFamilyID, now: now())
    }

    /// Disconnects Roblox and deletes the account's data everywhere.
    public func deleteAccount(userID: UUID) async throws {
        if let grant = try await store.grant(userID: userID), let refresh = try? box.open(grant.refreshTokenSealed) {
            // Best effort: data deletion must not depend on Roblox being reachable.
            try? await oauth.revoke(refreshToken: refresh)
        }
        try await store.revokeSessions(userID: userID, now: now())
        try await store.deleteUser(id: userID)
    }

    // MARK: Helpers

    private func makeSession(userID: UUID, familyID: UUID) -> (SessionRecord, AuthTokens) {
        let current = now()
        let access = Secrets.randomToken(prefix: "pk_at_")
        let refresh = Secrets.randomToken(prefix: "pk_rt_")
        let session = SessionRecord(id: UUID(), familyID: familyID, userID: userID,
                                    accessTokenHash: Secrets.hash(access),
                                    accessExpiresAt: current.addingTimeInterval(Self.accessTokenLifetime),
                                    refreshTokenHash: Secrets.hash(refresh),
                                    refreshExpiresAt: current.addingTimeInterval(Self.refreshTokenLifetime),
                                    createdAt: current)
        return (session, AuthTokens(accessToken: access, refreshToken: refresh,
                                    accessTokenExpiresAt: session.accessExpiresAt))
    }

    private func appURL(code: String? = nil, error: String? = nil) -> URL {
        var components = URLComponents(url: appCallbackURL, resolvingAgainstBaseURL: false)!
        components.queryItems = code.map { [URLQueryItem(name: "code", value: $0)] }
            ?? [URLQueryItem(name: "error", value: error ?? "server_error")]
        return components.url!
    }
}
