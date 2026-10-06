import Foundation
import Hummingbird
import HummingbirdTesting
import PeakKit
import Testing
@testable import PeakServerCore

@Suite("Analytics query client")
struct AnalyticsQueryClientTests {
    @Test func sendsBreakdownsAndFiltersAndDropsInsignificantPoints() async throws {
        let body = #"""
            {"done":true,"response":{"values":[
              {"breakdowns":[{"dimension":"FunnelName","value":"f1","displayValue":"Onboarding"},{"dimension":"FunnelStep","value":"2"}],
               "dataPoints":[{"time":"2026-09-20T00:00:00Z","value":0.21,"status":"Valid"},
                             {"time":"2026-09-21T00:00:00.000Z","value":0.19,"status":"Projected"},
                             {"time":"2026-09-22T00:00:00Z","value":0.9,"status":"NotStatisticallySignificant"},
                             {"value":5}]}]}}
            """#
        let http = FakeHTTP { _ in OutboundResponse(status: 200, body: Data(body.utf8)) }
        let client = RobloxAnalyticsClient(baseURL: URL(string: "https://apis.roblox.com/")!, http: http, pollDelays: [])
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let series = try await client.query(
            AnalyticsQuery(metric: "FunnelUserTotalCount", granularity: "None", start: start, end: start.addingTimeInterval(86_400),
                           breakdown: ["FunnelName", "FunnelStep"],
                           filters: [.init(dimension: "Platform", values: ["Phone"])], limit: 50),
            universeID: 7, accessToken: "at")

        let first = try #require(series.first)
        #expect(first.breakdown == ["FunnelName": "Onboarding", "FunnelStep": "2"], "display value when present, else the raw value")
        #expect(first.points.map(\.value) == [0.21, 0.19, 5])
        #expect(first.points.map(\.isProjected) == [false, true, false])
        #expect(first.points[1].time != nil, "fractional-second timestamps parse")

        let request = try #require(await http.requests.first)
        let sent = try #require(try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
        #expect(sent["breakdown"] as? [String] == ["FunnelName", "FunnelStep"])
        #expect(sent["limit"] as? Int == 50)
        let filter = try #require((sent["filter"] as? [[String: Any]])?.first)
        #expect(filter["dimension"] as? String == "Platform")
        #expect(filter["operation"] as? String == "In")
        #expect(filter["values"] as? [String] == ["Phone"])
    }
}

@Suite("Analytics poller")
struct AnalyticsPollerTests {
    let store = InMemoryStore()
    let clock = TestClock()

    actor FakeQuerying: RobloxAnalyticsQuerying {
        private(set) var metrics: [String] = []
        let today: Date

        init(today: Date) { self.today = today }

        func query(_ query: AnalyticsQuery, universeID: Int64, accessToken: String) async throws -> [AnalyticsSeries] {
            metrics.append(query.metric)
            func day(_ offset: Int) -> Date { today.addingTimeInterval(Double(offset) * 86_400) }
            switch query.metric {
            case "ForwardD1Retention":
                // Reported as percentages: normalised to fractions.
                return [AnalyticsSeries(breakdown: [:], points: [.init(time: day(-2), value: 21, isProjected: false),
                                                                  .init(time: day(-1), value: 18.5, isProjected: true)])]
            case "AverageSessionLengthMinutes":
                return [AnalyticsSeries(breakdown: [:], points: [.init(time: day(-1), value: 12.5, isProjected: false)])]
            case "ClientCrashRate15m":
                throw RobloxAPIError.upstream(status: 500)
            case "FunnelUserTotalCount":
                let isCurrent = query.end == today
                func step(_ name: String, _ players: Double) -> AnalyticsSeries {
                    AnalyticsSeries(breakdown: ["FunnelName": "Onboarding", "FunnelStep": name],
                                    points: [.init(time: nil, value: isCurrent ? players : players * 1.1, isProjected: false)])
                }
                return [step("Tutorial", 800), step("Join", 1_000), step("First Egg", 400)]
            default:
                return []
            }
        }
    }

    final class PauseCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    @Test func pacesQueriesNormalisesRatesAndBuildsFunnels() async throws {
        let user = try await store.upsertUser(robloxUserID: 1, username: "u", displayName: "U", now: clock.now)
        var grant = try RobloxTokenManager.makeGrant(
            userID: user.id, tokens: RobloxTokenSet(accessToken: "at", refreshToken: "rt", expiresIn: 3_600, scope: nil),
            universeIDs: [5], box: TestKeys.box, now: clock.now)
        grant.scopes = ["openid", AnalyticsPoller.scope]
        try await store.saveGrant(grant)
        let other = try await store.upsertUser(robloxUserID: 2, username: "v", displayName: "V", now: clock.now)
        var noScope = try RobloxTokenManager.makeGrant(
            userID: other.id, tokens: RobloxTokenSet(accessToken: "at2", refreshToken: "rt2", expiresIn: 3_600, scope: nil),
            universeIDs: [6], box: TestKeys.box, now: clock.now)
        noScope.scopes = ["openid"]
        try await store.saveGrant(noScope)

        let today = Calendar.utc.startOfDay(for: clock.now)
        let fake = FakeQuerying(today: today)
        let pauses = PauseCounter()
        let poller = AnalyticsPoller(store: store, tokens: RobloxTokenManager(store: store, oauth: FakeRobloxOAuth(), box: TestKeys.box, now: clock.function),
                                     analytics: fake, now: clock.function, pause: { _ in pauses.increment() })
        let succeeded = try await poller.tick(logger: testLogger)

        // 6 daily metrics (one fails) + 1 funnel pass for universe 5 only; every query is followed by a pause.
        #expect(succeeded == 6)
        let metrics = await fake.metrics
        #expect(metrics.count == AnalyticsPoller.dailyMetrics.count + 2)
        #expect(pauses.value == metrics.count)

        let d1 = try await store.insightSamples(universeID: 5, metric: .d1Retention, from: .distantPast, to: .distantFuture)
        #expect(d1.map(\.value) == [0.21, 0.185])
        let sessions = try await store.insightSamples(universeID: 5, metric: .sessionLength, from: .distantPast, to: .distantFuture)
        #expect(sessions.map(\.value) == [12.5], "minutes aren't treated as percentages")

        let funnel = try #require(try await store.latestFunnelSnapshots(universeID: 5).first)
        #expect(funnel.steps.map(\.name) == ["Join", "Tutorial", "First Egg"], "ordered by players, not by response order")
        #expect(funnel.steps.map(\.previousPlayers) == [1_100, 880, 440])
        #expect(funnel.periodEnd == today)
        #expect(try await store.latestFunnelSnapshots(universeID: 6).isEmpty)
    }

    @Test func normalisationOnlyTouchesRatesReportedAsPercentages() {
        #expect(AnalyticsPoller.normalise([0.2, 0.3], metric: .d1Retention) == [0.2, 0.3])
        #expect(AnalyticsPoller.normalise([20, 0.5], metric: .payerConversion) == [0.2, 0.005])
        #expect(AnalyticsPoller.normalise([14, 16], metric: .sessionLength) == [14, 16])
    }
}

struct StoreAnalyticsContractTests {
    @Test(arguments: StoreFactory.allCases)
    func insightSamplesUpsertAndFunnelsKeepTheLatest(factory: StoreFactory) async throws {
        guard let store = try await factory.make() else { return }
        let universe = Int64.random(in: 1_000_000...9_000_000_000)
        let day = Date(timeIntervalSince1970: 1_789_948_800)  // 2026-09-21T00:00:00Z
        try await store.upsertInsightSamples([InsightSample(universeID: universe, metric: .d1Retention, time: day, value: 0.18),
                                              InsightSample(universeID: universe, metric: .d1Retention, time: day.addingTimeInterval(-86_400), value: 0.2),
                                              InsightSample(universeID: universe, metric: .crashRate, time: day, value: .nan)])
        try await store.upsertInsightSamples([InsightSample(universeID: universe, metric: .d1Retention, time: day, value: 0.19)])
        let d1 = try await store.insightSamples(universeID: universe, metric: .d1Retention, from: day.addingTimeInterval(-86_400), to: day)
        #expect(d1.map(\.value) == [0.2, 0.19], "revised values replace, oldest first")
        #expect(try await store.insightSamples(universeID: universe, metric: .crashRate, from: .distantPast, to: .distantFuture).isEmpty)

        let steps = [FunnelStep(name: "Join", players: 10), FunnelStep(name: "Tutorial", players: 5)]
        try await store.saveFunnelSnapshots([
            FunnelSnapshot(universeID: universe, funnelName: "Onboarding", periodEnd: day.addingTimeInterval(-86_400), steps: steps),
            FunnelSnapshot(universeID: universe, funnelName: "Onboarding", periodEnd: day, steps: Array(steps.prefix(1))),
            FunnelSnapshot(universeID: universe, funnelName: "Shop", periodEnd: day, steps: steps),
        ])
        let latest = try await store.latestFunnelSnapshots(universeID: universe)
        #expect(latest.map(\.funnelName) == ["Onboarding", "Shop"])
        #expect(latest[0].periodEnd == day && latest[0].steps.count == 1)
    }
}

@Suite("Analytics in insights")
struct AnalyticsInsightRouteTests {
    static let universe = DataRouteTests.universe

    @Test func retentionFeedsUpdateReportsAlertsAndFunnelsAreScoped() async throws {
        let harness = RouteHarness()
        let now = harness.clock.now
        let today = Calendar.utc.startOfDay(for: now)
        let update = today.addingTimeInterval(-10 * 86_400 + 3_600)
        try await harness.store.appendTimelineEvents([TimelineEvent(kind: .update, gameID: Self.universe, date: update, detail: "v7")])
        var samples: [InsightSample] = []
        for offset in 1...35 {
            let day = today.addingTimeInterval(-Double(offset) * 86_400)
            // Steady 20% before the update, 24% after, and a collapse to 10% on the latest day.
            let value = offset == 1 ? 0.10 : (day >= update ? 0.24 : 0.20)
            samples.append(InsightSample(universeID: Self.universe, metric: .d1Retention, time: day, value: value))
        }
        try await harness.store.upsertInsightSamples(samples)
        try await harness.store.saveFunnelSnapshots([FunnelSnapshot(
            universeID: Self.universe, funnelName: "Onboarding", periodEnd: today,
            steps: [FunnelStep(name: "Join", players: 1_000), FunnelStep(name: "Tutorial", players: 300)])])

        try await harness.app.test(.router) { client in
            let tokens = try await harness.signIn(client)
            let headers = RouteHarness.bearer(tokens.accessToken)

            let report = try RouteHarness.decode(UpdateImpactReport.self,
                                                 try await client.execute(uri: "/v1/games/\(Self.universe)/update-impact", method: .get, headers: headers).body)
            let d1 = try #require(report.metrics.first { $0.metric == .d1Retention })
            #expect(d1.verdict == .improved)
            #expect(d1.before.map { abs($0 - 0.20) < 1e-9 } == true)

            let alerts = try RouteHarness.decode([AlertDigest].self,
                                                 try await client.execute(uri: "/v1/insights/alerts", method: .get, headers: headers).body)
            #expect(alerts.contains { $0.headline.metric == .d1Retention && $0.headline.direction == .drop })

            let funnels = try RouteHarness.decode([NamedFunnel].self,
                                                  try await client.execute(uri: "/v1/games/\(Self.universe)/funnels", method: .get, headers: headers).body)
            #expect(funnels.first?.report.focus?.to == "Tutorial")
            let other = try await client.execute(uri: "/v1/games/42/funnels", method: .get, headers: headers)
            #expect(other.status == .notFound)
        }
    }
}
