import Foundation

/// Tokens returned by `POST /oauth/v1/token`.
public struct RobloxTokenSet: Sendable, Hashable, Decodable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresIn: Int
    public var scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
    }

    public init(accessToken: String, refreshToken: String, expiresIn: Int, scope: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.scope = scope
    }
}

public struct RobloxUserInfo: Sendable, Hashable, Decodable {
    /// Roblox user ID (string in the API).
    public var sub: String
    public var name: String?
    public var preferredUsername: String?

    enum CodingKeys: String, CodingKey {
        case sub, name
        case preferredUsername = "preferred_username"
    }

    public init(sub: String, name: String?, preferredUsername: String?) {
        self.sub = sub
        self.name = name
        self.preferredUsername = preferredUsername
    }
}

public enum RobloxAPIError: Error, Hashable, Sendable {
    /// The code or refresh token is invalid, expired, already used, or the user revoked access.
    case invalidGrant
    case rateLimited(retryAfter: TimeInterval?)
    case upstream(status: Int)
    case malformedResponse
}

/// The Roblox OAuth 2.0 endpoints (decision 0005). Confidential client: the secret is sent in the
/// form body and never leaves the server. PKCE is used as well, as Roblox recommends for all clients.
public protocol RobloxOAuth: Sendable {
    func authorizeURL(state: String, codeChallenge: String) -> URL
    func exchange(code: String, codeVerifier: String) async throws -> RobloxTokenSet
    func refresh(refreshToken: String) async throws -> RobloxTokenSet
    func revoke(refreshToken: String) async throws
    func userInfo(accessToken: String) async throws -> RobloxUserInfo
    /// Universe IDs the user granted to this app (`token/resources`).
    func grantedUniverseIDs(accessToken: String) async throws -> [Int64]
}

public struct RobloxOAuthClient: RobloxOAuth {
    private let config: ServerConfig.Roblox
    private let http: any HTTPExecutor

    public init(config: ServerConfig.Roblox, http: any HTTPExecutor) {
        self.config = config
        self.http = http
    }

    private func endpoint(_ path: String) -> URL {
        config.oauthBaseURL.appendingPathComponent(path)
    }

    public func authorizeURL(state: String, codeChallenge: String) -> URL {
        var components = URLComponents(url: endpoint("v1/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        // `+` and spaces must be percent-encoded in query values.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    public func exchange(code: String, codeVerifier: String) async throws -> RobloxTokenSet {
        // Fields exactly as documented in oauth2-reference ("POST v1/token" with an authorization code).
        try await tokenRequest([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("code_verifier", codeVerifier),
        ])
    }

    public func refresh(refreshToken: String) async throws -> RobloxTokenSet {
        try await tokenRequest([("grant_type", "refresh_token"), ("refresh_token", refreshToken)])
    }

    public func revoke(refreshToken: String) async throws {
        let response = try await http.execute(formRequest("v1/token/revoke", [("token", refreshToken)]))
        // Already-invalid tokens are fine: the goal is that they're unusable.
        guard (200..<300).contains(response.status) || response.status == 400 else {
            throw Self.error(for: response)
        }
    }

    public func userInfo(accessToken: String) async throws -> RobloxUserInfo {
        let request = OutboundRequest(method: "GET", url: endpoint("v1/userinfo"),
                                      headers: ["Authorization": "Bearer \(accessToken)", "Accept": "application/json"])
        let response = try await http.execute(request)
        guard (200..<300).contains(response.status) else { throw Self.error(for: response) }
        guard let info = try? JSONDecoder().decode(RobloxUserInfo.self, from: response.body),
              Int64(info.sub) != nil else { throw RobloxAPIError.malformedResponse }
        return info
    }

    public func grantedUniverseIDs(accessToken: String) async throws -> [Int64] {
        let response = try await http.execute(formRequest("v1/token/resources", [("token", accessToken)]))
        guard (200..<300).contains(response.status) else { throw Self.error(for: response) }
        struct Resources: Decodable {
            struct Info: Decodable {
                struct Inner: Decodable {
                    struct IDs: Decodable { var ids: [String]? }
                    var universe: IDs?
                }
                var resources: Inner?
            }
            var resourceInfos: [Info]?
            enum CodingKeys: String, CodingKey { case resourceInfos = "resource_infos" }
        }
        guard let decoded = try? JSONDecoder().decode(Resources.self, from: response.body) else {
            throw RobloxAPIError.malformedResponse
        }
        let ids = (decoded.resourceInfos ?? []).flatMap { $0.resources?.universe?.ids ?? [] }.compactMap { Int64($0) }
        return Array(Set(ids)).filter { $0 > 0 }.sorted()
    }

    // MARK: Helpers

    private func formRequest(_ path: String, _ fields: [(String, String)]) -> OutboundRequest {
        let body = FormEncoding.encode(fields + [("client_id", config.clientID), ("client_secret", config.clientSecret)])
        return OutboundRequest(method: "POST", url: endpoint(path),
                               headers: ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"],
                               body: body)
    }

    private func tokenRequest(_ fields: [(String, String)]) async throws -> RobloxTokenSet {
        let response = try await http.execute(formRequest("v1/token", fields))
        guard (200..<300).contains(response.status) else { throw Self.error(for: response) }
        guard let tokens = try? JSONDecoder().decode(RobloxTokenSet.self, from: response.body),
              tokens.accessToken.isEmpty == false, tokens.refreshToken.isEmpty == false, tokens.expiresIn > 0 else {
            throw RobloxAPIError.malformedResponse
        }
        return tokens
    }

    static func error(for response: OutboundResponse) -> RobloxAPIError {
        switch response.status {
        case 400, 401: .invalidGrant
        case 429: .rateLimited(retryAfter: response.header("Retry-After").flatMap(TimeInterval.init))
        default: .upstream(status: response.status)
        }
    }
}
