import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import RBXPulseKit

struct APIClientTests {
    let future = Fixtures.now.addingTimeInterval(3_600)

    func makeClient(transport: FakeTransport, stored: AuthTokens?,
                    refresher: FakeRefresher) -> APIClient {
        let fixedNow = Fixtures.now
        let auth = AuthSessionCoordinator(store: InMemoryTokenStore(tokens: stored), refresher: refresher,
                                          now: { fixedNow })
        return APIClient(baseURL: Fixtures.baseURL, transport: transport, auth: auth)
    }

    static let seriesJSON = Data(#"{"metric":"ccu","points":[{"date":"2026-09-21T12:00:00Z","value":10}]}"#.utf8)

    @Test func buildsAuthorisedRequest() async throws {
        let transport = FakeTransport { _ in (200, Self.seriesJSON, [:]) }
        let client = makeClient(transport: transport, stored: Fixtures.tokens("a", expiresIn: 600),
                                refresher: FakeRefresher(expiresAt: future))

        let series = try await client.send(BackendAPI.series(gameID: 42, metric: .ccu, range: .week))
        #expect(series.points.count == 1)

        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.example.test/v1/games/42/series?metric=ccu&range=7d")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-a")
    }

    @Test func unauthenticatedEndpointSendsNoToken() async throws {
        let transport = FakeTransport { _ in
            (200, Data(#"{"authorizeURL":"https://apis.roblox.com/oauth/v1/authorize?x=1"}"#.utf8), [:])
        }
        let client = APIClient(baseURL: Fixtures.baseURL, transport: transport, auth: nil)
        let start = try await client.send(BackendAPI.startRobloxAuth())
        #expect(start.authorizeURL.host == "apis.roblox.com")
        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.httpMethod == "POST")
    }

    @Test func authenticatedEndpointWithoutCoordinatorThrowsSignedOut() async {
        let transport = FakeTransport { _ in (200, Self.seriesJSON, [:]) }
        let client = APIClient(baseURL: Fixtures.baseURL, transport: transport, auth: nil)
        await #expect(throws: AuthError.signedOut) { try await client.send(BackendAPI.dashboard()) }
        #expect(await transport.requests.isEmpty)
    }

    @Test func unauthorizedRefreshesOnceAndRetries() async throws {
        let transport = FakeTransport { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1"
                ? (200, Self.seriesJSON, [:])
                : (401, Data(), [:])
        }
        let refresher = FakeRefresher(expiresAt: future)
        let client = makeClient(transport: transport, stored: Fixtures.tokens("a", expiresIn: 600), refresher: refresher)

        _ = try await client.send(BackendAPI.series(gameID: 1, metric: .ccu, range: .day))
        #expect(await refresher.callCount == 1)
        #expect(await transport.requests.count == 2)
    }

    @Test func persistentUnauthorizedGivesUpAfterOneRetry() async throws {
        let transport = FakeTransport { _ in (401, Data(), [:]) }
        let refresher = FakeRefresher(expiresAt: future)
        let client = makeClient(transport: transport, stored: Fixtures.tokens("a", expiresIn: 600), refresher: refresher)

        await #expect(throws: APIError.unauthorized) {
            try await client.send(BackendAPI.dashboard())
        }
        #expect(await refresher.callCount == 1)
        #expect(await transport.requests.count == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func burstOf401sFromOneExpiredTokenTriggersOneRefresh() async throws {
        // Server-side the token expired early (e.g. revoked on another device and re-issued).
        let transport = FakeTransport { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer access-a"
                ? (401, Data(), [:])
                : (200, Self.seriesJSON, [:])
        }
        let refresher = FakeRefresher(expiresAt: future)
        let client = makeClient(transport: transport, stored: Fixtures.tokens("a", expiresIn: 600), refresher: refresher)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in 1...30 {
                group.addTask { _ = try await client.send(BackendAPI.series(gameID: Int64(id), metric: .ccu, range: .day)) }
            }
            try await group.waitForAll()
        }
        #expect(await refresher.callCount == 1)
    }

    @Test(arguments: [
        (429, ["Retry-After": "30"], APIError.rateLimited(retryAfter: 30)),
        (429, [:], .rateLimited(retryAfter: nil)),
        (429, ["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"], .rateLimited(retryAfter: nil)),
        (429, ["Retry-After": "-5"], .rateLimited(retryAfter: nil)),
        (403, [:], .forbidden),
        (404, [:], .notFound),
        (409, [:], .reconnectRequired),
        (500, [:], .server(status: 500)),
        (503, [:], .server(status: 503)),
        (302, [:], .unexpectedStatus(302)),
    ] as [(Int, [String: String], APIError)])
    func statusMapping(status: Int, headers: [String: String], expected: APIError) async {
        let transport = FakeTransport { _ in (status, Data(), headers) }
        let client = makeClient(transport: transport, stored: Fixtures.tokens("a", expiresIn: 600),
                                refresher: FakeRefresher(expiresAt: future))
        await #expect(throws: expected) { try await client.send(BackendAPI.dashboard()) }
    }

    @Test func malformedBodyIsDecodingError() async {
        let transport = FakeTransport { _ in (200, Data(#"{"games": "nope"}"#.utf8), [:]) }
        let client = makeClient(transport: transport, stored: Fixtures.tokens("a", expiresIn: 600),
                                refresher: FakeRefresher(expiresAt: future))
        await #expect {
            try await client.send(BackendAPI.dashboard())
        } throws: { error in
            if case APIError.decoding = error { return true }
            return false
        }
    }

    @Test func noContentEndpointIgnoresEmptyBody() async throws {
        let transport = FakeTransport { _ in (204, Data(), [:]) }
        let client = makeClient(transport: transport, stored: Fixtures.tokens("a", expiresIn: 600),
                                refresher: FakeRefresher(expiresAt: future))
        _ = try await client.send(BackendAPI.setFavourite(gameID: 7, value: true))
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/v1/games/7/favourite")
        #expect(request.httpBody.map { String(decoding: $0, as: UTF8.self) } == #"{"value":true}"#)
    }

    @Test(arguments: [401, 400])
    func backendRefresherMapsDeadTokenToRejected(status: Int) async {
        let transport = FakeTransport { _ in (status, Data(), [:]) }
        let refresher = BackendTokenRefresher(client: APIClient(baseURL: Fixtures.baseURL, transport: transport, auth: nil))
        await #expect(throws: RefreshTokenRejected.self) { try await refresher.refresh(using: "r") }
    }

    @Test func backendRefresherPassesThroughServerErrors() async {
        let transport = FakeTransport { _ in (503, Data(), [:]) }
        let refresher = BackendTokenRefresher(client: APIClient(baseURL: Fixtures.baseURL, transport: transport, auth: nil))
        await #expect(throws: APIError.server(status: 503)) { try await refresher.refresh(using: "r") }
    }

    @Test func dashboardDecodesContractFixture() async throws {
        let json = #"""
        {
          "games": [{
            "id": 920587237, "rootPlaceID": 7000, "name": "Attack Animals", "iconURL": null,
            "isFavourite": true, "isWorkingOn": false,
            "stats": {"ccu": 1234, "ccuYesterday": 1000, "visits": 5000000, "favourites": 20000,
                      "robux24h": null, "updatedAt": "2026-10-05T18:00:00Z"}
          }],
          "goals": [],
          "campaigns": [{"id": "c1", "name": "Launch", "gameID": 920587237, "status": "running",
                         "spentRobux": 100, "budgetRobux": null, "impressions": 1000, "clicks": 10, "plays": 4}],
          "recentAlerts": [],
          "ccuSparklines": {"920587237": {"metric": "ccu", "points": []}},
          "generatedAt": "2026-10-05T18:00:05Z"
        }
        """#
        let transport = FakeTransport { _ in (200, Data(json.utf8), [:]) }
        let client = makeClient(transport: transport, stored: Fixtures.tokens("a", expiresIn: 600),
                                refresher: FakeRefresher(expiresAt: future))
        let dashboard = try await client.send(BackendAPI.dashboard())
        #expect(dashboard.games.first?.stats.ccuChange == 0.234)
        #expect(dashboard.totalCCU == 1_234)
        #expect(dashboard.totalRobux24h == nil)
        #expect(dashboard.sparkline(for: 920_587_237) != nil)
        #expect(dashboard.campaigns.first?.clickThroughRate == 0.01)
    }
}
