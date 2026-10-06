import Foundation
import Hummingbird
import HummingbirdTesting
import PeakKit
import Testing
@testable import PeakServerCore

struct CampaignImportRouteTests {
    static let universe = DataRouteTests.universe
    static let csv = """
        Campaign Name,Status,Impressions,Clicks,Plays,Spend (Robux)
        Spring launch,Active,3200000,41600,18900,42000
        Weekend boost,Completed,610000,5490,2020,8000
        """

    @Test func importsCampaignsIntoTheDashboardAndAskTools() async throws {
        let harness = RouteHarness()
        try await harness.app.test(.router) { client in
            let tokens = try await harness.signIn(client)
            let headers = RouteHarness.bearer(tokens.accessToken)
            let body = RouteHarness.json(BackendAPI.CampaignImportBody(gameID: Self.universe, csv: Self.csv))
            let response = try await client.execute(uri: "/v1/campaigns/import", method: .post, headers: headers, body: body)
            #expect(response.status == .ok)
            let imported = try RouteHarness.decode([Campaign].self, response.body)
            #expect(imported.map(\.name) == ["Spring launch", "Weekend boost"])

            // Re-importing replaces rather than duplicates.
            _ = try await client.execute(uri: "/v1/campaigns/import", method: .post, headers: headers, body: body)
            let dashboard = try RouteHarness.decode(Dashboard.self, try await client.execute(uri: "/v1/dashboard", method: .get, headers: headers).body)
            #expect(dashboard.campaigns.count == 2)
            #expect(dashboard.campaigns.first?.spentRobux == 42_000)

            let auth = try await AuthService(store: harness.store, oauth: harness.oauth, box: TestKeys.box,
                                             appCallbackURL: URL(string: "peakstats://x")!, now: harness.clock.function)
                .authenticate(accessToken: tokens.accessToken)
            let dashboardBuilder = DashboardBuilder(store: harness.store, now: harness.clock.function)
            let toolbox = InsightToolbox(userID: auth.userID, dashboard: dashboardBuilder,
                                         insights: InsightBuilder(store: harness.store, dashboard: dashboardBuilder, now: harness.clock.function),
                                         now: harness.clock.function)
            let output = await toolbox.run(name: "get_campaigns", input: [:])
            #expect(output.isError == false)
            #expect(output.content.contains("\"suggestion\":\"increase\""))
            #expect(output.content.contains("R$42K"))
        }
    }

    @Test func rejectsOtherGamesAndUnreadableFiles() async throws {
        let harness = RouteHarness()
        try await harness.app.test(.router) { client in
            let tokens = try await harness.signIn(client)
            let headers = RouteHarness.bearer(tokens.accessToken)
            let notMine = try await client.execute(uri: "/v1/campaigns/import", method: .post, headers: headers,
                                                   body: RouteHarness.json(BackendAPI.CampaignImportBody(gameID: 42, csv: Self.csv)))
            #expect(notMine.status == .notFound)

            let missing = try await client.execute(uri: "/v1/campaigns/import", method: .post, headers: headers,
                                                   body: RouteHarness.json(BackendAPI.CampaignImportBody(gameID: Self.universe, csv: "Campaign,Clicks\nA,1")))
            #expect(missing.status == .badRequest)
            #expect(try RouteHarness.decode(BackendAPI.ErrorBody.self, missing.body).error == "csv_missing_columns")
        }
    }
}

struct StoreCampaignContractTests {
    @Test(arguments: StoreFactory.allCases)
    func campaignsAreReplacedByIDAndDeletedWithTheAccount(factory: StoreFactory) async throws {
        guard let store = try await factory.make() else { return }
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let user = try await store.upsertUser(robloxUserID: Int64.random(in: 1...1_000_000_000), username: "u", displayName: "U", now: t0)
        let first = Campaign(id: "import-1", name: "A", gameID: 1, status: .running, spentRobux: 10, impressions: 100, clicks: 1, plays: 1)
        var updated = first
        updated.spentRobux = 20
        try await store.saveImportedCampaigns(userID: user.id, campaigns: [first], now: t0)
        try await store.saveImportedCampaigns(userID: user.id, campaigns: [updated], now: t0)
        #expect(try await store.importedCampaigns(userID: user.id) == [updated])
        try await store.deleteUser(id: user.id)
        #expect(try await store.importedCampaigns(userID: user.id).isEmpty)
    }
}
