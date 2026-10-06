import Foundation
import Testing
@testable import PeakKit

@Suite("Campaign import")
struct CampaignImportTests {
    @Test func readsCommonHeadersSumsRowsAndSkipsTotals() throws {
        let csv = """
            Date,Campaign Name,Status,Impressions,Clicks,Plays,"Spend (Robux)",Budget
            2026-10-01,Spring launch,Active,"1,200,000",15600,7100,"16,000",60000
            2026-10-02,Spring launch,Active,2000000,26000,11800,26000,60000
            2026-10-02,"Weekend, boost",Paused,610000,5490,2020,8000,8000
            ,Total,,3810000,47090,20920,50000,
            2026-10-02,Broken row,Active,n/a,1,1,1,1
            """
        let result = try CampaignImport.parse(csv: csv, gameID: 7)
        #expect(result.campaigns.map(\.name) == ["Spring launch", "Weekend, boost"])
        let spring = result.campaigns[0]
        #expect(spring.impressions == 3_200_000)
        #expect(spring.clicks == 41_600)
        #expect(spring.plays == 18_900)
        #expect(spring.spentRobux == 42_000)
        #expect(spring.budgetRobux == 60_000)
        #expect(spring.status == .running)
        #expect(result.campaigns[1].status == .paused)
        #expect(result.mapping[.spend] == "Spend (Robux)")
        #expect(result.skippedRows == 2)
        // Re-importing the same campaign gives the same ID, so it replaces rather than duplicates.
        #expect(try CampaignImport.parse(csv: csv, gameID: 7).campaigns[0].id == spring.id)
    }

    @Test func missingRequiredColumnsAreReportedNotGuessed() {
        #expect(throws: CampaignImport.Failure.missingColumns([.impressions, .spend])) {
            try CampaignImport.parse(csv: "Campaign,Clicks\nA,5", gameID: 1)
        }
        #expect(throws: CampaignImport.Failure.empty) { try CampaignImport.parse(csv: "Campaign,Impressions,Spend\n", gameID: 1) }
        #expect(throws: CampaignImport.Failure.tooLarge) {
            try CampaignImport.parse(csv: String(repeating: "a", count: CampaignImport.maxBytes + 1), gameID: 1)
        }
    }

    @Test func csvHandlesQuotesAndLineEndings() {
        let rows = CSV.rows("a,\"b \"\"quoted\"\"\",\"c\nd\"\r\n1,2,3")
        #expect(rows == [["a", "b \"quoted\"", "c\nd"], ["1", "2", "3"]])
    }
}

@Suite("Campaign analyst")
struct CampaignAnalystTests {
    func campaign(_ id: String, impressions: Int64 = 100_000, clicks: Int64, plays: Int64, spend: Int64) -> Campaign {
        Campaign(id: id, name: id, gameID: 1, status: .running, spentRobux: spend, impressions: impressions, clicks: clicks, plays: plays)
    }

    @Test func comparesCampaignsWithEachOther() throws {
        let insights = CampaignAnalyst.analyze([
            campaign("cheap", clicks: 2_000, plays: 1_000, spend: 1_000),   // R$1/play, 2% CTR
            campaign("middle", clicks: 1_200, plays: 500, spend: 1_000),    // R$2/play
            campaign("pricey", clicks: 400, plays: 200, spend: 1_000),      // R$5/play, 0.4% CTR
            campaign("dud", clicks: 300, plays: 0, spend: 900),
            campaign("new", impressions: 300, clicks: 3, plays: 1, spend: 5),
        ])
        let byID = Dictionary(uniqueKeysWithValues: insights.map { ($0.campaignID, $0.suggestion) })
        #expect(byID == ["cheap": .increase, "middle": .maintain, "pricey": .reduce, "dud": .pause, "new": .needsData])
        let cheap = try #require(insights.first)
        #expect(cheap.summary.hasPrefix("CTR 2% (median 1.2%), R$1 per play (median R$2)."))
    }

    @Test func aSingleCampaignIsNeverJudgedAgainstItself() {
        let insight = CampaignAnalyst.analyze([campaign("only", clicks: 100, plays: 50, spend: 500)])[0]
        #expect(insight.suggestion == .maintain)
        #expect(insight.summary.contains("Import another campaign"))
        #expect(insight.summary.contains("median") == false)
    }
}

@Suite("Demo campaign import")
struct DemoCampaignImportTests {
    @Test func importedCampaignsJoinTheDashboard() async throws {
        let service = DemoDashboardService(now: { Fixtures.now })
        let imported = try await service.importCampaigns(csv: "Campaign,Impressions,Clicks,Plays,Spend\nAutumn,50000,600,250,900", gameID: 735_030_788)
        #expect(imported.map(\.name) == ["Autumn"])
        let dashboard = try await service.dashboard()
        #expect(dashboard.campaigns.contains { $0.name == "Autumn" && $0.gameID == 735_030_788 })
        await #expect(throws: CampaignImport.Failure.missingColumns([.impressions, .spend])) {
            try await service.importCampaigns(csv: "Campaign\nX", gameID: 1)
        }
    }
}
