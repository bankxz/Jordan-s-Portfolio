import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Hummingbird
import HummingbirdTesting
import PeakKit
import Testing
@testable import PeakServerCore

/// The iOS app's own networking stack (PeakKit: APIClient + AuthSessionCoordinator +
/// BackendTokenRefresher + URLSessionTransport) talking to the real server over real HTTP.
/// If the contract drifts on either side, this fails.
struct AppCompatibilityTests {
    @Test(.timeLimit(.minutes(1)))
    func appStackSignsInLoadsDashboardAndRefreshes() async throws {
        let harness = RouteHarness()
        try await DataRouteTests().seedStats(harness)

        try await harness.app.test(.live) { client in
            let port = try #require(client.port)
            let baseURL = try #require(URL(string: "http://localhost:\(port)/"))
            let transport = URLSessionTransport()

            // 1. Sign-in as the app does: start → (browser + Roblox, simulated here) → session exchange.
            let anonymous = APIClient(baseURL: baseURL, transport: transport, auth: nil)
            let start = try await anonymous.send(BackendAPI.startRobloxAuth())
            let state = try #require(URLComponents(url: start.authorizeURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "state" }?.value)
            let callback = await AuthService(store: harness.store, oauth: harness.oauth, box: TestKeys.box,
                                             appCallbackURL: URL(string: "peakstats://auth/complete")!, now: harness.clock.function)
                .completeAuthorization(code: "good-code", state: state, error: nil)
            guard case .authComplete(let code) = Route(url: callback) else {
                Issue.record("callback isn't an app route: \(callback)")
                return
            }
            let tokens = try await anonymous.send(BackendAPI.exchangeSessionCode(code))

            // 2. The app's session coordinator + authenticated client.
            let refresher = BackendTokenRefresher(client: anonymous)
            let coordinator = AuthSessionCoordinator(store: InMemoryTokenStore(), refresher: refresher, now: harness.clock.function)
            try await coordinator.signIn(with: tokens)
            let api = APIClient(baseURL: baseURL, transport: transport, auth: coordinator)
            let service = RemoteDashboardService(client: api)

            let dashboard = try await service.dashboard()
            #expect(dashboard.games.first?.name == "Attack Animals")
            #expect(dashboard.games.first?.stats.robux24h == 182_400)
            #expect(dashboard.widgetSnapshot.games.count == 1, "feeds the widget snapshot path unchanged")

            try await service.setFavourite(gameID: DataRouteTests.universe, isFavourite: true)
            let series = try await service.series(gameID: DataRouteTests.universe, metric: .ccu, range: .day)
            #expect(series.points.isEmpty == false)

            // 3. Access token expires: the coordinator refreshes through /v1/auth/refresh transparently.
            harness.clock.advance(AuthService.accessTokenLifetime + 5)
            let afterExpiry = try await service.dashboard()
            #expect(afterExpiry.games.first?.isFavourite == true)

            // 4. Rule round trip with the shared model.
            let rule = AlertRule(gameID: DataRouteTests.universe, metric: .ccu, condition: .dropFrom(fraction: 0.25, window: 1_800))
            #expect(try await api.send(BackendAPI.saveAlertRule(rule)) == rule)
            #expect(try await api.send(BackendAPI.alertRules()) == [rule])

            // 5. Insights through the app's RemoteInsightService. AI is off on this server.
            let insights = RemoteInsightService(client: api)
            let settings = try await insights.settings()
            #expect(settings.available == false && settings.consented == false)
            let briefing = try await insights.briefing()
            #expect(briefing.games.map(\.name) == ["Attack Animals"], "favourited above")
            #expect(briefing.isAIWritten == false)
            #expect(try await insights.alertDigests().isEmpty)
            #expect(try await insights.portfolio().map(\.gameID) == [DataRouteTests.universe])
            #expect(try await insights.updateImpact(gameID: DataRouteTests.universe) == nil, "404 maps to nil")
            #expect(try await insights.setConsent(true).consented)
            await #expect(throws: APIError.server(status: 503)) { try await insights.ask("Why?") }

            // 6. Reconnect state reaches the app as its own error case.
            let auth = try await AuthService(store: harness.store, oauth: harness.oauth, box: TestKeys.box,
                                             appCallbackURL: URL(string: "peakstats://x")!, now: harness.clock.function)
                .authenticate(accessToken: try await coordinator.validAccessToken())
            try await harness.store.deleteGrant(userID: auth.userID)
            await #expect(throws: APIError.reconnectRequired) { try await service.dashboard() }

            // 7. Sign out on the server ends the session for the app: the 401 triggers one refresh attempt,
            //    the revoked refresh token is rejected, and the coordinator clears the local session.
            _ = try await api.send(BackendAPI.logout())
            await #expect(throws: AuthError.sessionExpired) { try await service.dashboard() }
            #expect(await coordinator.isSignedIn() == false)
        }
    }
}
