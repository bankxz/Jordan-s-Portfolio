import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import RBXPulseKit
import Testing
@testable import RBXPulseServerCore

struct DataRouteTests {
    static let universe: Int64 = 3_828_411_582

    /// Seeds stats as the poller would.
    func seedStats(_ harness: RouteHarness) async throws {
        let now = harness.clock.now
        try await harness.store.upsertGameInfo([GameInfo(universeID: Self.universe, rootPlaceID: 99, name: "Attack Animals", updatedAt: now)])
        var samples: [MetricSample] = []
        for minute in stride(from: 0, through: 24 * 60, by: 30) {
            let time = now.addingTimeInterval(-Double(minute) * 60)
            samples.append(MetricSample(universeID: Self.universe, metric: .ccu, time: time, value: Double(1_000 + minute)))
        }
        samples.append(MetricSample(universeID: Self.universe, metric: .visits, time: now, value: 48_300_000))
        samples.append(MetricSample(universeID: Self.universe, metric: .favourites, time: now, value: 312_000))
        samples.append(MetricSample(universeID: Self.universe, metric: .robux, time: now.addingTimeInterval(-600), value: 182_400))
        try await harness.store.appendSamples(samples)
    }

    @Test func dashboardDecodesAsTheAppsModel() async throws {
        let harness = RouteHarness()
        try await seedStats(harness)
        try await harness.app.test(.router) { client in
            let tokens = try await harness.signIn(client)
            let response = try await client.execute(uri: "/v1/dashboard", method: .get, headers: RouteHarness.bearer(tokens.accessToken))
            #expect(response.status == .ok)
            let dashboard = try RouteHarness.decode(Dashboard.self, response.body)
            let game = try #require(dashboard.games.first)
            #expect(game.id == Self.universe)
            #expect(game.name == "Attack Animals")
            #expect(game.stats.ccu == 1_000)
            #expect(game.stats.ccuYesterday == 1_000 + 24 * 60)
            #expect(game.stats.visits == 48_300_000)
            #expect(game.stats.robux24h == 182_400)
            #expect(dashboard.sparkline(for: Self.universe)?.points.count == 24)
            #expect(dashboard.generatedAt == harness.clock.now)
        }
    }

    @Test func staleCCUIsNotShownAsLive() async throws {
        let harness = RouteHarness()
        try await seedStats(harness)
        harness.clock.advance(DashboardBuilder.ccuMaxAge + 60)
        try await harness.app.test(.router) { client in
            let tokens = try await harness.signIn(client)
            let response = try await client.execute(uri: "/v1/dashboard", method: .get, headers: RouteHarness.bearer(tokens.accessToken))
            let game = try #require(try RouteHarness.decode(Dashboard.self, response.body).games.first)
            #expect(game.stats.ccu == 0)
            #expect(game.stats.updatedAt == harness.clock.now.addingTimeInterval(-(DashboardBuilder.ccuMaxAge + 60)),
                    "updatedAt keeps the real age so the app labels it stale")
        }
    }

    @Test func unknownUniverseGetsPlaceholderName() async throws {
        let harness = RouteHarness()
        try await harness.app.test(.router) { client in
            let tokens = try await harness.signIn(client)
            let response = try await client.execute(uri: "/v1/dashboard", method: .get, headers: RouteHarness.bearer(tokens.accessToken))
            let dashboard = try RouteHarness.decode(Dashboard.self, response.body)
            #expect(dashboard.games.first?.name == "Experience \(Self.universe)")
            #expect(dashboard.campaigns.isEmpty)
        }
    }

    @Test func lostGrantMeansReconnect() async throws {
        let harness = RouteHarness()
        try await harness.app.test(.router) { client in
            let tokens = try await harness.signIn(client)
            let auth = try await AuthService(store: harness.store, oauth: harness.oauth, box: TestKeys.box,
                                             appCallbackURL: URL(string: "rbxpulse://x")!, now: harness.clock.function)
                .authenticate(accessToken: tokens.accessToken)
            try await harness.store.deleteGrant(userID: auth.userID)
            let response = try await client.execute(uri: "/v1/dashboard", method: .get, headers: RouteHarness.bearer(tokens.accessToken))
            #expect(response.status == .conflict)
            #expect(try RouteHarness.decode(BackendAPI.ErrorBody.self, response.body).error == "reconnect_required")
        }
    }

    @Test func seriesValidationAndRange() async throws {
        let harness = RouteHarness()
        try await seedStats(harness)
        try await harness.app.test(.router) { client in
            let headers = RouteHarness.bearer(try await harness.signIn(client).accessToken)
            let ok = try await client.execute(uri: "/v1/games/\(Self.universe)/series?metric=ccu&range=24h", method: .get, headers: headers)
            #expect(ok.status == .ok)
            let series = try RouteHarness.decode(MetricSeries.self, ok.body)
            #expect(series.points.count == 49)
            #expect(series.points.first!.date >= harness.clock.now.addingTimeInterval(-86_400))

            for bad in ["metric=ccu", "range=24h", "metric=cash&range=24h", "metric=ccu&range=1y"] {
                let response = try await client.execute(uri: "/v1/games/\(Self.universe)/series?\(bad)", method: .get, headers: headers)
                #expect(response.status == .badRequest, "\(bad)")
            }
            for path in ["/v1/games/abc/series?metric=ccu&range=24h", "/v1/games/-5/series?metric=ccu&range=24h"] {
                #expect(try await client.execute(uri: path, method: .get, headers: headers).status == .badRequest)
            }
        }
    }

    @Test func creatorsCannotTouchEachOthersGames() async throws {
        let harness = RouteHarness()
        try await seedStats(harness)
        try await harness.app.test(.router) { client in
            let owner = try await harness.signIn(client)
            // A second creator with a different Roblox account and no access to the universe.
            await harness.oauth.setUniverses([1])
            await harness.oauth.setRobloxUserID("999")
            let stranger = RouteHarness.bearer(try await harness.signIn(client).accessToken)

            let series = try await client.execute(uri: "/v1/games/\(Self.universe)/series?metric=ccu&range=24h", method: .get, headers: stranger)
            #expect(series.status == .notFound)
            let flag = try await client.execute(uri: "/v1/games/\(Self.universe)/favourite", method: .put, headers: stranger,
                                                body: RouteHarness.json(BackendAPI.FlagBody(value: true)))
            #expect(flag.status == .notFound)
            let rule = AlertRule(gameID: Self.universe, metric: .ccu, condition: .above(5))
            let ruleResponse = try await client.execute(uri: "/v1/alerts/rules/\(rule.id.uuidString)", method: .put,
                                                        headers: stranger, body: RouteHarness.json(rule))
            #expect(ruleResponse.status == .notFound)

            let dashboard = try await client.execute(uri: "/v1/dashboard", method: .get, headers: stranger)
            #expect(try RouteHarness.decode(Dashboard.self, dashboard.body).games.map(\.id) == [1])
            _ = owner
        }
    }

    @Test func flagsPersistIntoDashboard() async throws {
        let harness = RouteHarness()
        try await harness.app.test(.router) { client in
            let headers = RouteHarness.bearer(try await harness.signIn(client).accessToken)
            for path in ["favourite", "working-on"] {
                let response = try await client.execute(uri: "/v1/games/\(Self.universe)/\(path)", method: .put, headers: headers,
                                                        body: RouteHarness.json(BackendAPI.FlagBody(value: true)))
                #expect(response.status == .noContent)
            }
            let dashboard = try RouteHarness.decode(Dashboard.self,
                try await client.execute(uri: "/v1/dashboard", method: .get, headers: headers).body)
            #expect(dashboard.games.first?.isFavourite == true)
            #expect(dashboard.games.first?.isWorkingOn == true)
        }
    }

    @Test(arguments: [
        ("a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90", HTTPResponse.Status.noContent),
        ("short", .badRequest),
        ("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz", .badRequest),
    ])
    func deviceRegistrationValidatesToken(token: String, status: HTTPResponse.Status) async throws {
        let harness = RouteHarness()
        try await harness.app.test(.router) { client in
            let headers = RouteHarness.bearer(try await harness.signIn(client).accessToken)
            let response = try await client.execute(uri: "/v1/devices", method: .post, headers: headers,
                                                    body: RouteHarness.json(BackendAPI.DeviceBody(apnsToken: token, sandbox: true)))
            #expect(response.status == status)
        }
    }

    @Test func alertRuleLifecycle() async throws {
        let harness = RouteHarness()
        try await harness.app.test(.router) { client in
            let headers = RouteHarness.bearer(try await harness.signIn(client).accessToken)
            let rule = AlertRule(gameID: Self.universe, metric: .ccu, condition: .dropFrom(fraction: 0.3, window: 3_600))
            let saved = try await client.execute(uri: "/v1/alerts/rules/\(rule.id.uuidString)", method: .put,
                                                 headers: headers, body: RouteHarness.json(rule))
            #expect(saved.status == .ok)
            #expect(try RouteHarness.decode(AlertRule.self, saved.body) == rule)

            let list = try await client.execute(uri: "/v1/alerts/rules", method: .get, headers: headers)
            #expect(try RouteHarness.decode([AlertRule].self, list.body) == [rule])

            let mismatched = try await client.execute(uri: "/v1/alerts/rules/\(UUID().uuidString)", method: .put,
                                                      headers: headers, body: RouteHarness.json(rule))
            #expect(mismatched.status == .badRequest)

            #expect(try await client.execute(uri: "/v1/alerts/rules/\(rule.id.uuidString)", method: .delete, headers: headers).status == .noContent)
            #expect(try await client.execute(uri: "/v1/alerts/rules/\(rule.id.uuidString)", method: .delete, headers: headers).status == .notFound)
            #expect(try await client.execute(uri: "/v1/alerts/rules/not-a-uuid", method: .delete, headers: headers).status == .badRequest)
        }
    }

    @Test(arguments: [
        AlertRule.Condition.above(-1), .above(.nan), .above(.infinity), .below(1e16),
        .dropFrom(fraction: 0, window: 3_600), .dropFrom(fraction: 1.5, window: 3_600),
        .dropFrom(fraction: 0.3, window: 10), .dropFrom(fraction: 0.3, window: 30.0 * 86_400),
    ])
    func invalidRulesRejected(condition: AlertRule.Condition) async throws {
        let harness = RouteHarness()
        try await harness.app.test(.router) { client in
            let headers = RouteHarness.bearer(try await harness.signIn(client).accessToken)
            let rule = AlertRule(gameID: Self.universe, metric: .ccu, condition: condition)
            // NaN/infinity can't be encoded as JSON; build the body by hand for those.
            let body: ByteBuffer
            if let data = try? JSONCoding.makeEncoder().encode(rule) {
                body = ByteBuffer(bytes: data)
            } else {
                body = ByteBuffer(string: #"{"id":"\#(rule.id.uuidString)","gameID":\#(Self.universe),"metric":"ccu","condition":{"above":{"_0":"NaN"}},"cooldown":1800,"isEnabled":true}"#)
            }
            let response = try await client.execute(uri: "/v1/alerts/rules/\(rule.id.uuidString)", method: .put, headers: headers, body: body)
            #expect(response.status == .badRequest)
        }
    }

    @Test func cannotHijackAnotherUsersDisabledRule() async throws {
        let harness = RouteHarness()
        try await harness.app.test(.router) { client in
            let ownerHeaders = RouteHarness.bearer(try await harness.signIn(client).accessToken)
            var rule = AlertRule(gameID: Self.universe, metric: .ccu, condition: .above(10))
            rule.isEnabled = false
            #expect(try await client.execute(uri: "/v1/alerts/rules/\(rule.id.uuidString)", method: .put,
                                             headers: ownerHeaders, body: RouteHarness.json(rule)).status == .ok)

            await harness.oauth.setRobloxUserID("777")  // different creator, same universe grant
            let attacker = RouteHarness.bearer(try await harness.signIn(client).accessToken)
            var hijack = rule
            hijack.isEnabled = true
            let response = try await client.execute(uri: "/v1/alerts/rules/\(rule.id.uuidString)", method: .put,
                                                    headers: attacker, body: RouteHarness.json(hijack))
            #expect(response.status == .notFound)
            let ownerRules = try RouteHarness.decode([AlertRule].self,
                try await client.execute(uri: "/v1/alerts/rules", method: .get, headers: ownerHeaders).body)
            #expect(ownerRules.first?.isEnabled == false)
        }
    }

    @Test func ruleLimitEnforced() async throws {
        let harness = RouteHarness()
        try await harness.app.test(.router) { client in
            let headers = RouteHarness.bearer(try await harness.signIn(client).accessToken)
            for _ in 0..<AlertRuleValidator.maxRulesPerUser {
                let rule = AlertRule(gameID: Self.universe, metric: .ccu, condition: .above(1))
                #expect(try await client.execute(uri: "/v1/alerts/rules/\(rule.id.uuidString)", method: .put,
                                                 headers: headers, body: RouteHarness.json(rule)).status == .ok)
            }
            let extra = AlertRule(gameID: Self.universe, metric: .ccu, condition: .above(1))
            let response = try await client.execute(uri: "/v1/alerts/rules/\(extra.id.uuidString)", method: .put,
                                                    headers: headers, body: RouteHarness.json(extra))
            #expect(response.status == .badRequest)
        }
    }
}
