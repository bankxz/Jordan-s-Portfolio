import Foundation
import Testing
@testable import PeakServerCore

/// Request shapes and response parsing against the payloads in Roblox's oauth2-reference.
struct RobloxOAuthClientTests {
    let config = ServerConfig.Roblox(clientID: "840974200211308101", clientSecret: "RBX-secret",
                                     redirectURI: URL(string: "https://api.peakstats.app/oauth/roblox/callback")!)

    static let tokenJSON = Data(#"{"access_token":"at","refresh_token":"rt","token_type":"Bearer","expires_in":899,"scope":"openid profile"}"#.utf8)

    @Test func authorizeURLHasDocumentedParameters() throws {
        let client = RobloxOAuthClient(config: config, http: FakeHTTP { _ in OutboundResponse(status: 500) })
        let url = client.authorizeURL(state: "st+ate", codeChallenge: "chal")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(url.absoluteString.hasPrefix("https://apis.roblox.com/oauth/v1/authorize?"))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["client_id"] == "840974200211308101")
        #expect(items["redirect_uri"] == "https://api.peakstats.app/oauth/roblox/callback")
        #expect(items["scope"] == "openid profile universe.analytics:read")
        #expect(items["response_type"] == "code")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == "st+ate")
        #expect(items["client_secret"] == nil, "secret must never appear in a browser URL")
        #expect(url.absoluteString.contains("st%2Bate"))
    }

    @Test func exchangePostsFormWithSecretAndVerifier() async throws {
        let http = FakeHTTP { _ in OutboundResponse(status: 200, body: Self.tokenJSON) }
        let tokens = try await RobloxOAuthClient(config: config, http: http).exchange(code: "c o/de", codeVerifier: "verif")
        #expect(tokens == RobloxTokenSet(accessToken: "at", refreshToken: "rt", expiresIn: 899, scope: "openid profile"))
        let request = try #require(await http.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://apis.roblox.com/oauth/v1/token")
        #expect(request.headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(request.formFields == ["grant_type": "authorization_code", "code": "c o/de", "code_verifier": "verif",
                                       "client_id": "840974200211308101", "client_secret": "RBX-secret"])
    }

    @Test func refreshPostsRefreshGrant() async throws {
        let http = FakeHTTP { _ in OutboundResponse(status: 200, body: Self.tokenJSON) }
        _ = try await RobloxOAuthClient(config: config, http: http).refresh(refreshToken: "old-rt")
        let fields = try #require(await http.requests.first).formFields
        #expect(fields["grant_type"] == "refresh_token")
        #expect(fields["refresh_token"] == "old-rt")
    }

    @Test(arguments: [
        (400, RobloxAPIError.invalidGrant),
        (401, .invalidGrant),
        (429, .rateLimited(retryAfter: 7)),
        (503, .upstream(status: 503)),
    ])
    func tokenErrorsMapped(status: Int, expected: RobloxAPIError) async {
        let http = FakeHTTP { _ in OutboundResponse(status: status, headers: ["retry-after": "7"]) }
        await #expect(throws: expected) {
            try await RobloxOAuthClient(config: self.config, http: http).refresh(refreshToken: "x")
        }
    }

    @Test(arguments: [
        #"{"access_token":"","refresh_token":"rt","expires_in":899}"#,
        #"{"access_token":"at","refresh_token":"rt","expires_in":0}"#,
        #"{"access_token":"at"}"#,
        #"<html>gateway</html>"#,
    ])
    func malformedTokenResponse(body: String) async {
        let http = FakeHTTP { _ in OutboundResponse(status: 200, body: Data(body.utf8)) }
        await #expect(throws: RobloxAPIError.malformedResponse) {
            try await RobloxOAuthClient(config: self.config, http: http).exchange(code: "c", codeVerifier: "v")
        }
    }

    @Test func parsesDocumentedResourcesResponse() async throws {
        let json = #"""
        {"resource_infos":[{"owner":{"id":"1516563360","type":"User"},
          "resources":{"universe":{"ids":["3828411582","42","3828411582"]},"creator":{"ids":["U"]}}},
          {"owner":{"id":"9","type":"Group"},"resources":{"creator":{"ids":["U"]}}}]}
        """#
        let http = FakeHTTP { _ in OutboundResponse(status: 200, body: Data(json.utf8)) }
        let ids = try await RobloxOAuthClient(config: config, http: http).grantedUniverseIDs(accessToken: "at")
        #expect(ids == [42, 3_828_411_582])
        let fields = try #require(await http.requests.first).formFields
        #expect(fields["token"] == "at")
        #expect(fields["client_secret"] == "RBX-secret")
    }

    @Test func parsesDocumentedUserInfo() async throws {
        let json = #"{"sub":"1516563360","name":"exampleuser","nickname":"exampleuser","preferred_username":"exampleuser","created_at":1584682495,"profile":"https://www.roblox.com/users/1516563360/profile","picture":null}"#
        let http = FakeHTTP { _ in OutboundResponse(status: 200, body: Data(json.utf8)) }
        let info = try await RobloxOAuthClient(config: config, http: http).userInfo(accessToken: "at")
        #expect(info.sub == "1516563360")
        #expect(info.preferredUsername == "exampleuser")
        #expect(try #require(await http.requests.first).headers["Authorization"] == "Bearer at")
    }

    @Test func rejectsNonNumericSub() async {
        let http = FakeHTTP { _ in OutboundResponse(status: 200, body: Data(#"{"sub":"abc"}"#.utf8)) }
        await #expect(throws: RobloxAPIError.malformedResponse) {
            try await RobloxOAuthClient(config: self.config, http: http).userInfo(accessToken: "at")
        }
    }

    @Test func revokeToleratesAlreadyInvalidToken() async throws {
        let http = FakeHTTP { _ in OutboundResponse(status: 400) }
        try await RobloxOAuthClient(config: config, http: http).revoke(refreshToken: "rt")
        #expect(try #require(await http.requests.first).url.path == "/oauth/v1/token/revoke")
    }
}
