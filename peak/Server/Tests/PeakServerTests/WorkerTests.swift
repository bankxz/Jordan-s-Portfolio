import Crypto
import Foundation
import Logging
import PeakKit
import ServiceLifecycle
import Testing
@testable import PeakServerCore

let testLogger = Logger(label: "test")

struct RobloxGamesClientTests {
    @Test func parsesGamesResponseLeniently() async throws {
        let json = #"""
        {"data":[
          {"id":3828411582,"rootPlaceId":10,"name":"Attack Animals","playing":4820,"visits":48300000,"favoritedCount":312000,"maxPlayers":50},
          {"id":42,"name":"No numbers"},
          {"id":7,"rootPlaceId":1,"playing":5},
          {"id":999,"name":"Not requested","playing":1},
          {"id":43,"name":"Negative","playing":-3,"visits":-1}
        ]}
        """#
        let http = FakeHTTP { _ in OutboundResponse(status: 200, body: Data(json.utf8)) }
        let client = RobloxGamesClient(baseURL: URL(string: "https://games.roblox.com/")!, http: http)
        let stats = try await client.stats(universeIDs: [3_828_411_582, 42, 7, 43])
        #expect(stats.map(\.universeID) == [3_828_411_582, 42, 43])
        #expect(stats[0] == UniverseStats(universeID: 3_828_411_582, rootPlaceID: 10, name: "Attack Animals",
                                          playing: 4_820, visits: 48_300_000, favourites: 312_000))
        #expect(stats[1].playing == 0)
        #expect(stats[2].playing == 0 && stats[2].visits == 0)
        let url = try #require(await http.requests.first).url.absoluteString
        #expect(url == "https://games.roblox.com/v1/games?universeIds=3828411582,42,7,43")
    }

    @Test(arguments: [(429, RobloxAPIError.rateLimited(retryAfter: nil)), (500, .upstream(status: 500))])
    func errors(status: Int, expected: RobloxAPIError) async {
        let http = FakeHTTP { _ in OutboundResponse(status: status) }
        await #expect(throws: expected) {
            try await RobloxGamesClient(baseURL: URL(string: "https://games.roblox.com/")!, http: http).stats(universeIDs: [1])
        }
    }
}

struct RobloxAnalyticsClientTests {
    let base = URL(string: "https://apis.roblox.com/")!
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    static let done = #"{"path":"v1/universes/1/operations/metrics/abc","done":true,"response":{"values":[{"breakdowns":[],"dataPoints":[{"time":"2026-09-21T10:00:00Z","value":120},{"time":"2026-09-21T11:00:00Z","value":80}]}]}}"#

    @Test func immediateResultAndRequestShape() async throws {
        let http = FakeHTTP { _ in OutboundResponse(status: 200, body: Data(Self.done.utf8)) }
        let points = try await RobloxAnalyticsClient(baseURL: base, http: http, pollDelays: [])
            .hourly(metric: "ItemMonetizationRevenue", universeID: 1, start: start, end: start.addingTimeInterval(86_400), accessToken: "at")
        #expect(points.map(\.1) == [120, 80])
        let request = try #require(await http.requests.first)
        #expect(request.url.absoluteString == "https://apis.roblox.com/analytics-query-api/v1/universes/1/metrics")
        #expect(request.headers["Authorization"] == "Bearer at")
        let body = try #require(try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: String])
        #expect(body["metric"] == "ItemMonetizationRevenue")
        #expect(body["granularity"] == "OneHour")
        #expect(body["startTime"] == "2026-09-21T14:13:20Z")
    }

    @Test func pollsLongRunningOperation() async throws {
        let pending = #"{"path":"v1/universes/1/operations/metrics/abc","done":false}"#
        let http = FakeHTTP { request in
            request.method == "POST" ? OutboundResponse(status: 202, body: Data(pending.utf8))
                                     : OutboundResponse(status: 200, body: Data(Self.done.utf8))
        }
        let points = try await RobloxAnalyticsClient(baseURL: base, http: http, pollDelays: [.milliseconds(1)])
            .hourly(metric: "m", universeID: 1, start: start, end: start, accessToken: "at")
        #expect(points.count == 2)
        let poll = try #require(await http.requests.last)
        #expect(poll.url.absoluteString == "https://apis.roblox.com/analytics-query-api/v1/universes/1/operations/metrics/abc")
        #expect(poll.method == "GET")
    }

    @Test func givesUpAfterBoundedPolls() async {
        let pending = #"{"path":"v1/x","done":false}"#
        let http = FakeHTTP { _ in OutboundResponse(status: 202, body: Data(pending.utf8)) }
        await #expect(throws: RobloxAnalyticsClient.AnalyticsError.timedOut) {
            try await RobloxAnalyticsClient(baseURL: self.base, http: http, pollDelays: [.milliseconds(1), .milliseconds(1)])
                .hourly(metric: "m", universeID: 1, start: self.start, end: self.start, accessToken: "at")
        }
        #expect(await http.requests.count == 3)
    }

    @Test(arguments: ["https://evil.example/v1/x", "../../oauth/v1/token", "v1/../../x", "/v1/x", "v1/x?y=1"])
    func refusesUnsafePollPaths(path: String) async {
        let pending = #"{"path":"\#(path)","done":false}"#
        let http = FakeHTTP { _ in OutboundResponse(status: 202, body: Data(pending.utf8)) }
        await #expect(throws: RobloxAnalyticsClient.AnalyticsError.queryFailed) {
            try await RobloxAnalyticsClient(baseURL: self.base, http: http, pollDelays: [.milliseconds(1)])
                .hourly(metric: "m", universeID: 1, start: self.start, end: self.start, accessToken: "at")
        }
        #expect(await http.requests.count == 1, "never follows an unsafe path with the bearer token")
    }

    @Test func operationErrorIsFailure() async {
        let failed = #"{"path":"v1/x","done":true,"error":{"message":"The requested granularity is not supported for this metric."}}"#
        let http = FakeHTTP { _ in OutboundResponse(status: 200, body: Data(failed.utf8)) }
        await #expect(throws: RobloxAnalyticsClient.AnalyticsError.queryFailed) {
            try await RobloxAnalyticsClient(baseURL: self.base, http: http, pollDelays: [])
                .hourly(metric: "m", universeID: 1, start: self.start, end: self.start, accessToken: "at")
        }
    }
}

/// Games API fake: counts calls and can fail specific batches.
actor FakeGames: RobloxGamesAPI {
    private(set) var batches: [[Int64]] = []
    var failingUniverse: Int64?
    var playing = 100

    func setFailing(_ id: Int64?) { failingUniverse = id }
    func setPlaying(_ value: Int) { playing = value }

    func stats(universeIDs: [Int64]) async throws -> [UniverseStats] {
        batches.append(universeIDs)
        if let failingUniverse, universeIDs.contains(failingUniverse) { throw RobloxAPIError.upstream(status: 503) }
        return universeIDs.map { UniverseStats(universeID: $0, rootPlaceID: $0 + 1, name: "Game \($0)", playing: playing,
                                               visits: 10, favourites: 5) }
    }
}

actor RecordingPush: PushSender {
    private(set) var sent: [(PushMessage, String)] = []
    var result: PushResult = .delivered
    func setResult(_ value: PushResult) { result = value }
    func send(_ message: PushMessage, to device: DeviceRecord) async -> PushResult {
        sent.append((message, device.token))
        return result
    }
}

struct WorkerTests {
    let store = InMemoryStore()
    let clock = TestClock()
    let games = FakeGames()
    let push = RecordingPush()

    var alerts: AlertEvaluator { AlertEvaluator(store: store, push: push, now: clock.function) }
    var poller: StatsPoller { StatsPoller(store: store, games: games, alerts: alerts, now: clock.function) }

    @discardableResult
    func seedUser(universes: [Int64], robloxID: Int64 = 1, scopes: [String] = ["openid"]) async throws -> UUID {
        let user = try await store.upsertUser(robloxUserID: robloxID, username: "u\(robloxID)", displayName: "U", now: clock.now)
        var grant = try RobloxTokenManager.makeGrant(
            userID: user.id, tokens: RobloxTokenSet(accessToken: "at", refreshToken: "rt-\(robloxID)", expiresIn: 3_600, scope: nil),
            universeIDs: universes, box: TestKeys.box, now: clock.now)
        grant.scopes = scopes
        try await store.saveGrant(grant)
        return user.id
    }

    @Test func pollerBatchesDeduplicatesAndStores() async throws {
        try await seedUser(universes: Array(1...150), robloxID: 1)
        try await seedUser(universes: [150, 151], robloxID: 2)  // overlap is polled once
        #expect(try await poller.tick(logger: testLogger) == 151)
        let batches = await games.batches
        #expect(batches.map(\.count) == [100, 51])
        #expect(try await store.gameInfo(universeIDs: [151])[151]?.name == "Game 151")
        #expect(try await store.latestSample(universeIDs: [1], metric: .ccu, atOrBefore: clock.now)[1]?.value == 100)
    }

    @Test func failingBatchDoesNotStopOthers() async throws {
        try await seedUser(universes: Array(1...150))
        await games.setFailing(5)
        #expect(try await poller.tick(logger: testLogger) == 50)
        #expect(try await store.latestSample(universeIDs: [5], metric: .ccu, atOrBefore: clock.now).isEmpty)
        #expect(try await store.latestSample(universeIDs: [120], metric: .ccu, atOrBefore: clock.now)[120] != nil)
    }

    @Test func retriedTickInSameMinuteIsIdempotent() async throws {
        try await seedUser(universes: [1])
        try await poller.tick(logger: testLogger)
        clock.advance(10)
        try await poller.tick(logger: testLogger)
        #expect(try await store.samples(universeID: 1, metric: .ccu, from: .distantPast, to: .distantFuture).count == 1)
    }

    @Test func alertFiresOncePushesAndDropsDeadDevices() async throws {
        let user = try await seedUser(universes: [9])
        try await store.saveDevice(DeviceRecord(userID: user, token: "live", sandbox: false, updatedAt: clock.now))
        try await store.saveDevice(DeviceRecord(userID: user, token: "dead", sandbox: false, updatedAt: clock.now))
        try await store.saveAlertRule(userID: user, rule: AlertRule(gameID: 9, metric: .ccu, condition: .above(500)))

        await games.setPlaying(100)
        try await poller.tick(logger: testLogger)
        #expect(await push.sent.isEmpty)

        clock.advance(60)
        await games.setPlaying(900)
        await push.setResult(.unregistered)
        try await poller.tick(logger: testLogger)
        let sent = await push.sent
        #expect(sent.count == 2)
        #expect(sent.first?.0.url.absoluteString == "peakstats://game/9")
        #expect(sent.first?.0.body == "900 players: above 500")
        #expect(try await store.devices(userID: user).isEmpty, "unregistered tokens are removed")
        #expect(try await store.recentAlertEvents(userID: user, limit: 5).count == 1)

        clock.advance(60)
        try await poller.tick(logger: testLogger)
        #expect(await push.sent.count == 2, "stays quiet while the condition persists")
    }

    @Test func rulesForRevokedUniversesAreSkipped() async throws {
        let user = try await seedUser(universes: [9])
        try await store.saveAlertRule(userID: user, rule: AlertRule(gameID: 77, metric: .ccu, condition: .above(1)))
        try await store.appendSamples([MetricSample(universeID: 77, metric: .ccu, time: clock.now, value: 50)])
        #expect(try await alerts.evaluate(logger: testLogger).isEmpty)
    }

    @Test func revenuePollerSumsLast24hForGrantedScopeOnly() async throws {
        actor FakeAnalytics: RobloxAnalyticsAPI {
            private(set) var calls: [Int64] = []
            func hourly(metric: String, universeID: Int64, start: Date, end: Date, accessToken: String) async throws -> [(Date, Double)] {
                calls.append(universeID)
                if universeID == 3 { throw RobloxAPIError.upstream(status: 500) }
                return [(start.addingTimeInterval(3_600), 100), (start.addingTimeInterval(7_200), 50.4), (start.addingTimeInterval(-10), 999), (start, -5)]
            }
        }
        let analytics = FakeAnalytics()
        try await seedUser(universes: [1, 3], robloxID: 1, scopes: ["openid", RevenuePoller.scope])
        try await seedUser(universes: [2], robloxID: 2, scopes: ["openid"])
        let tokens = RobloxTokenManager(store: store, oauth: FakeRobloxOAuth(), box: TestKeys.box, now: clock.function)
        let revenue = RevenuePoller(store: store, tokens: tokens, analytics: analytics, now: clock.function)
        #expect(try await revenue.tick(logger: testLogger) == 1)
        #expect(Set(await analytics.calls) == [1, 3])
        #expect(try await store.latestSample(universeIDs: [1], metric: .robux, atOrBefore: clock.now)[1]?.value == 150)
    }

    @Test(.timeLimit(.minutes(1)))
    func periodicServiceRunsAndStopsOnCancellation() async throws {
        actor Counter { var value = 0; func increment() { value += 1 } }
        let counter = Counter()
        let service = PeriodicService(name: "t", interval: .milliseconds(5), logger: testLogger) { _ in
            await counter.increment()
            if await counter.value == 2 { throw RobloxAPIError.upstream(status: 500) }  // errors don't stop it
        }
        let task = Task { try await service.run() }
        while await counter.value < 4 { await Task.yield() }
        task.cancel()
        try await task.value
        let stoppedAt = await counter.value
        try await Task.sleep(for: .milliseconds(30))
        #expect(await counter.value == stoppedAt)
    }
}

struct APNsSenderTests {
    let key = P256.Signing.PrivateKey()

    var config: ServerConfig.APNs {
        ServerConfig.APNs(teamID: "TEAM123456", keyID: "KEY1234567", privateKeyPEM: key.pemRepresentation, bundleID: "com.peakstats.app")
    }

    func decodePart(_ part: Substring) throws -> [String: Any] {
        var base64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        let data = try #require(Data(base64Encoded: base64))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func providerTokenIsValidES256AndCached() async throws {
        let clock = TestClock()
        let sender = try APNsSender(config: config, http: FakeHTTP { _ in OutboundResponse(status: 200) }, now: clock.function)
        let jwt = try await sender.providerToken()
        let parts = jwt.split(separator: ".")
        #expect(parts.count == 3)
        #expect(try decodePart(parts[0])["kid"] as? String == "KEY1234567")
        #expect(try decodePart(parts[0])["alg"] as? String == "ES256")
        #expect(try decodePart(parts[1])["iss"] as? String == "TEAM123456")

        var sigBase64 = String(parts[2]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while sigBase64.count % 4 != 0 { sigBase64 += "=" }
        let signatureData = try #require(Data(base64Encoded: sigBase64))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
        #expect(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))

        clock.advance(49 * 60)
        #expect(try await sender.providerToken() == jwt)
        clock.advance(2 * 60)
        #expect(try await sender.providerToken() != jwt)
    }

    @Test(arguments: [
        (200, "", PushResult.delivered),
        (410, #"{"reason":"Unregistered"}"#, .unregistered),
        (400, #"{"reason":"BadDeviceToken"}"#, .unregistered),
        (400, #"{"reason":"PayloadTooLarge"}"#, .failed(status: 400)),
        (500, "", .failed(status: 500)),
    ])
    func statusMapping(status: Int, body: String, expected: PushResult) async throws {
        let http = FakeHTTP { _ in OutboundResponse(status: status, body: Data(body.utf8)) }
        let sender = try APNsSender(config: config, http: http)
        let message = PushMessage(title: "Attack Animals", body: "900 players", url: URL(string: "peakstats://game/9")!, threadID: "game-9")
        let result = await sender.send(message, to: DeviceRecord(userID: UUID(), token: "abcd", sandbox: true, updatedAt: Date()))
        #expect(result == expected)
        let request = try #require(await http.requests.first)
        #expect(request.url.absoluteString == "https://api.sandbox.push.apple.com/3/device/abcd")
        #expect(request.headers["apns-topic"] == "com.peakstats.app")
        #expect(request.headers["apns-push-type"] == "alert")
        let payload = try #require(try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
        #expect(payload["url"] as? String == "peakstats://game/9")
    }

    @Test func invalidKeyIsRejectedAtStartup() {
        let bad = ServerConfig.APNs(teamID: "T", keyID: "K", privateKeyPEM: "not a key", bundleID: "b")
        #expect(throws: (any Error).self) { try APNsSender(config: bad, http: FakeHTTP { _ in OutboundResponse(status: 200) }) }
    }
}
