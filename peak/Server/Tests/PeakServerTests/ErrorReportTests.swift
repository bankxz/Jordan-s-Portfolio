import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import PeakKit
import Testing
@testable import PeakServerCore

@Suite("Error reports from the game")
struct ErrorReportTests {
    static let universe = DataRouteTests.universe

    static func ingestHeaders(_ key: String) -> HTTPFields {
        var headers = HTTPFields()
        headers[.authorization] = "Bearer \(key)"
        headers[.contentType] = "application/json"
        return headers
    }

    /// The JSON the Luau server script sends (`HttpService:JSONEncode`).
    static let report = """
        {"placeVersion":128,"errors":[
          {"message":"ServerScriptService.Pets:42: attempt to index nil with 'Level' (Players.Alice.Backpack)","source":"server","count":12},
          {"message":"ServerScriptService.Pets:42: attempt to index nil with 'Owner' (Players.Bob.Backpack)","source":"server","count":3},
          {"message":"Players.Carol.PlayerGui.Shop:18: attempt to perform arithmetic on nil","source":"client","count":2}
        ]}
        """

    func createKey(_ client: some TestClientProtocol, _ harness: RouteHarness, universe: Int64 = universe) async throws -> TestResponse {
        let tokens = try await harness.signIn(client)
        return try await client.execute(uri: "/v1/games/\(universe)/error-key", method: .post,
                                        headers: RouteHarness.bearer(tokens.accessToken))
    }

    @Test func fromKeyToGroupedErrorsInTheAppAndAsk() async throws {
        let harness = RouteHarness()
        try await harness.app.test(.router) { client in
            let created = try await createKey(client, harness)
            #expect(created.status == .ok)
            let setup = try RouteHarness.decode(BackendAPI.ErrorReportSetup.self, created.body)
            #expect(setup.key.hasPrefix("pk_ik_"))
            #expect(setup.secretName == "peak_ingest")
            #expect(setup.endpoint.absoluteString == "https://peak.example.test/v1/ingest/errors")

            let sent = try await client.execute(uri: "/v1/ingest/errors", method: .post, headers: Self.ingestHeaders(setup.key),
                                                body: ByteBuffer(string: Self.report))
            #expect(sent.status == .accepted)
            harness.clock.advance(60)
            _ = try await client.execute(uri: "/v1/ingest/errors", method: .post, headers: Self.ingestHeaders(setup.key),
                                         body: ByteBuffer(string: Self.report))
            #expect(try await harness.errorReports.flush(into: harness.store, now: harness.clock.now) == 2, "grouped before writing")

            let tokens = try await harness.signIn(client)
            let listed = try await client.execute(uri: "/v1/games/\(Self.universe)/errors", method: .get,
                                                  headers: RouteHarness.bearer(tokens.accessToken))
            #expect(listed.status == .ok)
            let clusters = try RouteHarness.decode([ErrorCluster].self, listed.body)
            #expect(clusters.map(\.count) == [30, 4])
            #expect(clusters[0].example == "ServerScriptService.Pets:42: attempt to index nil with '…' (Players.<player>.Backpack)")
            #expect(clusters[0].versions == [128])
            #expect(clusters[1].sources == ["client"])
            let stored = try await harness.store.errorCounts(universeID: Self.universe, since: .distantPast)
            for name in ["Alice", "Bob", "Carol"] {
                #expect(stored.allSatisfy { $0.example.contains(name) == false && $0.signature.contains(name) == false })
            }

            let auth = try await AuthService(store: harness.store, oauth: harness.oauth, box: TestKeys.box,
                                             appCallbackURL: URL(string: "peakstats://x")!, now: harness.clock.function)
                .authenticate(accessToken: tokens.accessToken)
            let dashboard = DashboardBuilder(store: harness.store, now: harness.clock.function)
            let toolbox = InsightToolbox(userID: auth.userID, dashboard: dashboard,
                                         insights: InsightBuilder(store: harness.store, dashboard: dashboard, now: harness.clock.function),
                                         now: harness.clock.function)
            let output = await toolbox.run(name: "get_errors", input: ["game_id": .number(Double(Self.universe))])
            #expect(output.isError == false)
            #expect(output.content.contains("example_untrusted"))
            #expect(output.content.contains("Happened 30 times"))
            #expect(output.content.contains("Alice") == false)
        }
    }

    @Test func aNewKeyReplacesTheOldOne() async throws {
        let harness = RouteHarness()
        try await harness.app.test(.router) { client in
            let first = try RouteHarness.decode(BackendAPI.ErrorReportSetup.self, try await createKey(client, harness).body)
            let second = try RouteHarness.decode(BackendAPI.ErrorReportSetup.self, try await createKey(client, harness).body)
            #expect(first.key != second.key)
            let old = try await client.execute(uri: "/v1/ingest/errors", method: .post, headers: Self.ingestHeaders(first.key),
                                               body: ByteBuffer(string: Self.report))
            #expect(old.status == .unauthorized)
            let new = try await client.execute(uri: "/v1/ingest/errors", method: .post, headers: Self.ingestHeaders(second.key),
                                               body: ByteBuffer(string: Self.report))
            #expect(new.status == .accepted)
        }
    }

    @Test func keysOnlyForYourGamesAndOnlyWhileYouHaveThem() async throws {
        let harness = RouteHarness()
        try await harness.app.test(.router) { client in
            #expect(try await createKey(client, harness, universe: 42).status == .notFound)
            let setup = try RouteHarness.decode(BackendAPI.ErrorReportSetup.self, try await createKey(client, harness).body)

            // The creator loses access to the game: its key stops working.
            let tokens = try await harness.signIn(client)
            let auth = try await AuthService(store: harness.store, oauth: harness.oauth, box: TestKeys.box,
                                             appCallbackURL: URL(string: "peakstats://x")!, now: harness.clock.function)
                .authenticate(accessToken: tokens.accessToken)
            var grant = try #require(try await harness.store.grant(userID: auth.userID))
            grant.universeIDs = []
            try await harness.store.saveGrant(grant)
            let response = try await client.execute(uri: "/v1/ingest/errors", method: .post, headers: Self.ingestHeaders(setup.key),
                                                    body: ByteBuffer(string: Self.report))
            #expect(response.status == .unauthorized)
        }
    }

    @Test func keyCreationIsOffWithoutAPublicAddress() async throws {
        var configured = RouteHarness()
        configured.publicBaseURL = nil
        let harness = configured
        try await harness.app.test(.router) { client in
            let response = try await createKey(client, harness)
            #expect(response.status == .serviceUnavailable)
            #expect(try RouteHarness.decode(BackendAPI.ErrorBody.self, response.body).error == "error_reports_unavailable")
        }
    }

    @Test func rejectsMissingKeysBadReportsAndFloods() async throws {
        var configured = RouteHarness()
        configured.ingestRateLimit = 7
        let harness = configured
        try await harness.app.test(.router) { client in
            let setup = try RouteHarness.decode(BackendAPI.ErrorReportSetup.self, try await createKey(client, harness).body)
            let body = ByteBuffer(string: Self.report)
            #expect(try await client.execute(uri: "/v1/ingest/errors", method: .post, body: body).status == .unauthorized)
            for key in ["pk_ik_wrong", "not-a-peak-key", "pk_ik_" + String(repeating: "a", count: 200)] {
                #expect(try await client.execute(uri: "/v1/ingest/errors", method: .post, headers: Self.ingestHeaders(key),
                                                 body: body).status == .unauthorized)
            }

            let tooMany = BackendAPI.IngestErrors(placeVersion: 1, errors: (0...BackendAPI.maxIngestEntries).map {
                .init(message: "error \($0)", count: 1)
            })
            let bad: [(String, BackendAPI.IngestErrors)] = [
                ("too_many_errors", tooMany),
                ("invalid_error", .init(placeVersion: 1, errors: [.init(message: "x", count: 0)])),
                ("invalid_error", .init(placeVersion: 1, errors: [.init(message: "x", count: ErrorReportLimits.maxEntryCount + 1)])),
                ("invalid_error", .init(placeVersion: 1, errors: [.init(message: "   ", count: 1)])),
                ("invalid_error", .init(placeVersion: 1, errors: [.init(message: "x", count: 1, source: "admin")])),
                ("invalid_place_version", .init(placeVersion: -3, errors: [.init(message: "x", count: 1)])),
            ]
            for (code, report) in bad {
                let response = try await client.execute(uri: "/v1/ingest/errors", method: .post,
                                                        headers: Self.ingestHeaders(setup.key), body: RouteHarness.json(report))
                #expect(response.status == .badRequest)
                #expect(try RouteHarness.decode(BackendAPI.ErrorBody.self, response.body).error == code)
            }
            #expect(try await client.execute(uri: "/v1/ingest/errors", method: .post, headers: Self.ingestHeaders(setup.key),
                                             body: body).status == .accepted)

            // 7 a minute per key: the 8th is refused until the window resets.
            let flooded = try await client.execute(uri: "/v1/ingest/errors", method: .post, headers: Self.ingestHeaders(setup.key),
                                                   body: body)
            #expect(flooded.status == .tooManyRequests)
            harness.clock.advance(61)
            #expect(try await client.execute(uri: "/v1/ingest/errors", method: .post, headers: Self.ingestHeaders(setup.key),
                                             body: body).status == .accepted)
            #expect(try await harness.errorReports.flush(into: harness.store, now: harness.clock.now) == 2)
        }
    }

    @Test func bufferTruncatesAndCapsWhatItHolds() async throws {
        let buffer = ErrorIngestBuffer()
        let store = InMemoryStore()
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let long = String(repeating: "x", count: 2_000)
        _ = await buffer.add(universeID: 1, report: .init(placeVersion: nil, errors: [.init(message: long, count: 1)]), at: t0)
        try await buffer.flush(into: store, now: t0)
        let row = try #require(try await store.errorCounts(universeID: 1, since: .distantPast).first)
        #expect(row.example.count == BackendAPI.maxIngestMessageLength)
        #expect(row.placeVersion == nil)
        #expect(row.source == "server", "no source means the server script")
        #expect(try await buffer.flush(into: store, now: t0) == 0, "nothing left after a flush")
    }

    @Test func publicAddressDefaultsToTheRedirectOrigin() throws {
        var env = [
            "ROBLOX_CLIENT_ID": "id", "ROBLOX_CLIENT_SECRET": "secret",
            "ROBLOX_REDIRECT_URI": "https://api.peak.example/oauth/roblox/callback?x=1",
            "TOKEN_ENCRYPTION_KEY": Data(repeating: 1, count: 32).base64EncodedString(),
        ]
        #expect(try ServerConfig.fromEnvironment(env).publicBaseURL?.absoluteString == "https://api.peak.example/")
        env["PUBLIC_BASE_URL"] = "https://ingest.peak.example"
        #expect(try ServerConfig.fromEnvironment(env).publicBaseURL?.absoluteString == "https://ingest.peak.example")
        env["PUBLIC_BASE_URL"] = "http://ingest.peak.example"
        #expect(throws: ServerConfig.ConfigError.invalid("PUBLIC_BASE_URL", reason: "must be https")) {
            try ServerConfig.fromEnvironment(env)
        }
        env["PUBLIC_BASE_URL"] = nil
        env["ROBLOX_REDIRECT_URI"] = "http://localhost:8080/oauth/roblox/callback"
        #expect(try ServerConfig.fromEnvironment(env).publicBaseURL == nil, "games can't reach localhost")
    }
}

struct StoreErrorReportContractTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func count(_ signature: String, version: Int? = 3, source: String = "server", _ n: Int = 1, at: Date) -> ErrorCount {
        ErrorCount(signature: signature, example: signature + " example", source: source, placeVersion: version, count: n,
                   firstSeen: at, lastSeen: at)
    }

    @Test(arguments: StoreFactory.allCases)
    func keysAreReplacedAndDeletedWithTheAccount(factory: StoreFactory) async throws {
        guard let store = try await factory.make() else { return }
        let user = try await store.upsertUser(robloxUserID: Int64.random(in: 1...1_000_000_000), username: "u", displayName: "U", now: t0)
        let universe = Int64.random(in: 1...1_000_000_000)
        let first = "hash-\(UUID().uuidString)", second = "hash-\(UUID().uuidString)"
        try await store.saveIngestKey(hash: first, userID: user.id, universeID: universe, createdAt: t0)
        #expect(try await store.ingestKey(hash: first) == IngestKeyRecord(userID: user.id, universeID: universe))
        try await store.saveIngestKey(hash: second, userID: user.id, universeID: universe, createdAt: t0)
        #expect(try await store.ingestKey(hash: first) == nil)
        #expect(try await store.ingestKey(hash: second)?.universeID == universe)
        try await store.deleteUser(id: user.id)
        #expect(try await store.ingestKey(hash: second) == nil)
    }

    @Test(arguments: StoreFactory.allCases)
    func countsAddUpPerDayVersionAndSourceAndExpire(factory: StoreFactory) async throws {
        guard let store = try await factory.make() else { return }
        let universe = Int64.random(in: 1...1_000_000_000)
        // Long before the other tests' data, so the retention delete below can't remove rows they are writing.
        let t0 = Date(timeIntervalSince1970: 631_152_000)
        let day = Calendar.utc.startOfDay(for: t0)
        let later = t0.addingTimeInterval(600)
        try await store.addErrorCounts(universeID: universe, day: day, counts: [
            count("A", 5, at: t0), count("A", version: nil, 1, at: t0), count("A", source: "client", 2, at: t0),
        ])
        try await store.addErrorCounts(universeID: universe, day: day, counts: [count("A", 4, at: later)])
        let rows = try await store.errorCounts(universeID: universe, since: .distantPast)
        #expect(rows.count == 3)
        let merged = try #require(rows.first { $0.placeVersion == 3 && $0.source == "server" })
        #expect(merged.count == 9)
        #expect(merged.firstSeen == t0 && merged.lastSeen == later)
        #expect(rows.contains { $0.placeVersion == nil })
        #expect(try await store.errorCounts(universeID: universe, since: later.addingTimeInterval(1)).isEmpty)

        try await store.deleteErrorCounts(before: day.addingTimeInterval(86_400))
        #expect(try await store.errorCounts(universeID: universe, since: .distantPast).isEmpty)
    }

    @Test(arguments: StoreFactory.allCases)
    func newSignaturesStopAtTheDailyCap(factory: StoreFactory) async throws {
        guard let store = try await factory.make() else { return }
        let universe = Int64.random(in: 1...1_000_000_000)
        let day = Calendar.utc.startOfDay(for: t0)
        let cap = ErrorReportLimits.signaturesPerDay
        try await store.addErrorCounts(universeID: universe, day: day, counts: (0..<cap).map { count("sig \($0)", at: t0) })
        try await store.addErrorCounts(universeID: universe, day: day, counts: [
            count("one too many", at: t0), count("sig 0", 4, at: t0), count("sig 1", source: "client", at: t0),
        ])
        let rows = try await store.errorCounts(universeID: universe, since: .distantPast)
        #expect(Set(rows.map(\.signature)).count == cap)
        #expect(rows.contains { $0.signature == "one too many" } == false)
        #expect(rows.first { $0.signature == "sig 0" }?.count == 5, "known signatures still count")
        #expect(rows.contains { $0.signature == "sig 1" && $0.source == "client" }, "a known signature from a new source is kept")
        // The next day starts fresh.
        try await store.addErrorCounts(universeID: universe, day: day.addingTimeInterval(86_400),
                                       counts: [count("one too many", at: t0.addingTimeInterval(86_400))])
        #expect(try await store.errorCounts(universeID: universe, since: .distantPast).contains { $0.signature == "one too many" })
    }
}
