import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import PeakKit
import Testing
@testable import PeakServerCore

/// Shared harness: the real router with fakes behind it.
struct RouteHarness {
    let store = InMemoryStore()
    let oauth = FakeRobloxOAuth()
    let clock = TestClock()
    var rateLimit = 1_000
    var claude: (any ClaudeAPI)?
    var aiSettings: AIService.Settings?

    var deps: ServerDependencies {
        ServerDependencies(store: store, oauth: oauth, box: TestKeys.box,
                           appCallbackURL: URL(string: "peakstats://auth/complete")!,
                           authRateLimit: rateLimit, claude: claude, aiSettings: aiSettings, now: clock.function)
    }

    var app: some ApplicationProtocol {
        Application(router: PeakServerApp.buildRouter(deps))
    }

    static func json(_ value: some Encodable) -> ByteBuffer {
        ByteBuffer(bytes: try! JSONCoding.makeEncoder().encode(value))
    }

    static func decode<T: Decodable>(_ type: T.Type, _ buffer: ByteBuffer) throws -> T {
        try JSONCoding.makeDecoder().decode(T.self, from: Data(buffer: buffer))
    }

    /// Full sign-in over HTTP; returns the app's tokens.
    func signIn(_ client: some TestClientProtocol) async throws -> AuthTokens {
        let start = try await client.execute(uri: "/v1/auth/roblox/start", method: .post)
        let authorize = try Self.decode(BackendAPI.AuthStart.self, start.body).authorizeURL
        let state = try #require(URLComponents(url: authorize, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value)
        let callback = try await client.execute(uri: "/oauth/roblox/callback?code=good-code&state=\(state)", method: .get)
        let location = try #require(callback.headers[.location])
        let code = try #require(URLComponents(string: location)?.queryItems?.first { $0.name == "code" }?.value)
        let session = try await client.execute(uri: "/v1/auth/session", method: .post,
                                               body: Self.json(BackendAPI.SessionCodeBody(code: code)))
        #expect(session.status == .ok)
        return try Self.decode(AuthTokens.self, session.body)
    }

    static func bearer(_ token: String) -> HTTPFields { [.authorization: "Bearer \(token)"] }
}

struct AuthRouteTests {
    @Test func healthCheck() async throws {
        try await RouteHarness().app.test(.router) { client in
            let response = try await client.execute(uri: "/health", method: .get)
            #expect(response.status == .ok)
            #expect(String(buffer: response.body) == "ok")
        }
    }

    @Test func fullSignInRefreshAndLogoutOverHTTP() async throws {
        let harness = RouteHarness()
        try await harness.app.test(.router) { client in
            let tokens = try await harness.signIn(client)

            let refreshed = try await client.execute(uri: "/v1/auth/refresh", method: .post,
                                                     body: RouteHarness.json(BackendAPI.RefreshBody(refreshToken: tokens.refreshToken)))
            #expect(refreshed.status == .ok)
            #expect(refreshed.headers[.cacheControl] == "no-store")
            let next = try RouteHarness.decode(AuthTokens.self, refreshed.body)

            let logout = try await client.execute(uri: "/v1/auth/logout", method: .post, headers: RouteHarness.bearer(next.accessToken))
            #expect(logout.status == .noContent)
            let after = try await client.execute(uri: "/v1/auth/logout", method: .post, headers: RouteHarness.bearer(next.accessToken))
            #expect(after.status == .unauthorized)
        }
    }

    @Test func callbackRedirectsIntoApp() async throws {
        try await RouteHarness().app.test(.router) { client in
            let response = try await client.execute(uri: "/oauth/roblox/callback?error=access_denied&state=x", method: .get)
            #expect(response.status == .found)
            #expect(response.headers[.location] == "peakstats://auth/complete?error=access_denied")
        }
    }

    @Test(arguments: [
        ("/v1/auth/session", #"{"code":"pk_sc_nope"}"#, HTTPResponse.Status.unauthorized, "unauthorized"),
        ("/v1/auth/refresh", #"{"refreshToken":"pk_rt_nope"}"#, .unauthorized, "unauthorized"),
        ("/v1/auth/session", #"{"nope":1}"#, .badRequest, "invalid_body"),
        ("/v1/auth/refresh", "not json", .badRequest, "invalid_body"),
    ])
    func errorsUseStableJSONShape(path: String, body: String, status: HTTPResponse.Status, code: String) async throws {
        try await RouteHarness().app.test(.router) { client in
            let response = try await client.execute(uri: path, method: .post, body: ByteBuffer(string: body))
            #expect(response.status == status)
            #expect(try RouteHarness.decode(BackendAPI.ErrorBody.self, response.body).error == code)
        }
    }

    @Test func oversizedBodyRejected() async throws {
        try await RouteHarness().app.test(.router) { client in
            let huge = #"{"code":""# + String(repeating: "a", count: 200_000) + #""}"#
            let response = try await client.execute(uri: "/v1/auth/session", method: .post, body: ByteBuffer(string: huge))
            #expect(response.status.code >= 400)
            #expect(response.status != .ok)
        }
    }

    @Test(arguments: [nil, "Bearer", "Bearer pk_at_fake", "Basic abc"] as [String?])
    func protectedRoutesNeedValidBearer(header: String?) async throws {
        try await RouteHarness().app.test(.router) { client in
            var headers = HTTPFields()
            if let header { headers[.authorization] = header }
            let response = try await client.execute(uri: "/v1/auth/logout", method: .post, headers: headers)
            #expect(response.status == .unauthorized)
            #expect(response.headers[.wwwAuthenticate] == "Bearer")
        }
    }

    @Test func authEndpointsAreRateLimited() async throws {
        var configured = RouteHarness()
        configured.rateLimit = 3
        let harness = configured
        try await harness.app.test(.router) { client in
            for _ in 0..<3 {
                #expect(try await client.execute(uri: "/v1/auth/roblox/start", method: .post).status == .ok)
            }
            let limited = try await client.execute(uri: "/v1/auth/roblox/start", method: .post)
            #expect(limited.status == .tooManyRequests)
            #expect(limited.headers[.retryAfter] != nil)
            harness.clock.advance(61)
            #expect(try await client.execute(uri: "/v1/auth/roblox/start", method: .post).status == .ok)
        }
    }

    @Test func deleteAccountOverHTTP() async throws {
        let harness = RouteHarness()
        try await harness.app.test(.router) { client in
            let tokens = try await harness.signIn(client)
            let response = try await client.execute(uri: "/v1/account", method: .delete, headers: RouteHarness.bearer(tokens.accessToken))
            #expect(response.status == .noContent)
            #expect(await harness.oauth.revoked.count == 1)
            let after = try await client.execute(uri: "/v1/auth/logout", method: .post, headers: RouteHarness.bearer(tokens.accessToken))
            #expect(after.status == .unauthorized)
        }
    }
}
