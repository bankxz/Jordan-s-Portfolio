import Foundation
import Hummingbird
import HummingbirdTesting
import PeakKit
import Testing
@testable import PeakServerCore

@Suite("Briefing notifier")
struct BriefingNotifierTests {
    let store = InMemoryStore()
    static let universe: Int64 = 3_828_411_582

    /// 2026-09-21 12:05 UTC = 08:05 in New York (EDT).
    let clock = TestClock(Date(timeIntervalSince1970: 1_789_992_300))

    func seed(timeZone: String?, favourite: Bool = true) async throws {
        let user = try await store.upsertUser(robloxUserID: 1, username: "u", displayName: "U", now: clock.now)
        try await store.saveGrant(RobloxGrant(userID: user.id, accessTokenSealed: Data(), refreshTokenSealed: Data(), refreshTokenHash: "h",
                                              accessTokenExpiresAt: clock.now, scopes: [], universeIDs: [Self.universe], updatedAt: clock.now))
        try await store.upsertGameInfo([GameInfo(universeID: Self.universe, rootPlaceID: 1, name: "Attack Animals", updatedAt: clock.now)])
        try await store.appendSamples([MetricSample(universeID: Self.universe, metric: .ccu, time: clock.now, value: 4_800)])
        try await store.setFavourite(userID: user.id, universeID: Self.universe, value: favourite)
        try await store.saveDevice(DeviceRecord(userID: user.id, token: String(repeating: "b", count: 64), sandbox: true,
                                                updatedAt: clock.now, timeZone: timeZone))
    }

    func notifier(_ push: DigestNotifierTests.Pushes) -> BriefingNotifier {
        let dashboard = DashboardBuilder(store: store, now: clock.function)
        return BriefingNotifier(store: store, insights: InsightBuilder(store: store, dashboard: dashboard, now: clock.function),
                                ai: AIService(store: store, claude: nil, settings: nil, now: clock.function),
                                push: push, now: clock.function)
    }

    @Test func arrivesOnceAtEightLocalTime() async throws {
        try await seed(timeZone: "America/New_York")
        let push = DigestNotifierTests.Pushes()
        #expect(try await notifier(push).tick(logger: testLogger) == 1)
        let message = try #require(await push.sent.first)
        #expect(message.title == "Today's briefing")
        #expect(message.body.hasPrefix("All quiet"))
        #expect(message.url == Route.home.url)

        clock.advance(15 * 60)
        #expect(try await notifier(push).tick(logger: testLogger) == 0, "once per local day")
        clock.advance(24 * 3_600)
        #expect(try await notifier(push).tick(logger: testLogger) == 1, "and again the next morning")
    }

    @Test func otherHoursUnknownZonesAndNoFavouritesAreSkipped() async throws {
        try await seed(timeZone: "Europe/London")  // 13:05 there
        let push = DigestNotifierTests.Pushes()
        #expect(try await notifier(push).tick(logger: testLogger) == 0)

        let noZone = BriefingNotifierTests()
        try await noZone.seed(timeZone: nil)
        #expect(try await noZone.notifier(push).tick(logger: testLogger) == 0)

        let noFavourites = BriefingNotifierTests()
        try await noFavourites.seed(timeZone: "America/New_York", favourite: false)
        #expect(try await noFavourites.notifier(push).tick(logger: testLogger) == 0)
    }

    @Test func registrationKeepsOnlyRealTimeZones() async throws {
        let harness = RouteHarness()
        try await harness.app.test(.router) { client in
            let tokens = try await harness.signIn(client)
            let headers = RouteHarness.bearer(tokens.accessToken)
            for (token, zone) in [(String(repeating: "c", count: 64), "Asia/Tokyo"), (String(repeating: "d", count: 64), "Mars/Olympus")] {
                let response = try await client.execute(uri: "/v1/devices", method: .post, headers: headers,
                                                        body: RouteHarness.json(BackendAPI.DeviceBody(apnsToken: token, sandbox: true, timeZone: zone)))
                #expect(response.status == .noContent)
            }
            let auth = try await AuthService(store: harness.store, oauth: harness.oauth, box: TestKeys.box,
                                             appCallbackURL: URL(string: "peakstats://x")!, now: harness.clock.function)
                .authenticate(accessToken: tokens.accessToken)
            let zones = try await harness.store.devices(userID: auth.userID).map(\.timeZone)
            #expect(zones == ["Asia/Tokyo", nil])
        }
    }
}

struct StoreDeviceTimeZoneContractTests {
    @Test(arguments: StoreFactory.allCases)
    func timeZoneRoundTrips(factory: StoreFactory) async throws {
        guard let store = try await factory.make() else { return }
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let user = try await store.upsertUser(robloxUserID: Int64.random(in: 1...1_000_000_000), username: "u", displayName: "U", now: t0)
        let token = "tz-\(UUID().uuidString)"
        try await store.saveDevice(DeviceRecord(userID: user.id, token: token, sandbox: false, updatedAt: t0, timeZone: "Europe/Paris"))
        #expect(try await store.devices(userID: user.id).first?.timeZone == "Europe/Paris")
        try await store.saveDevice(DeviceRecord(userID: user.id, token: token, sandbox: false, updatedAt: t0, timeZone: nil))
        #expect(try await store.devices(userID: user.id).first?.timeZone == nil)
    }
}
