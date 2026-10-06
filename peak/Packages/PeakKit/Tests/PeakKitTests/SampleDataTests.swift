import Foundation
import Testing
@testable import PeakKit

struct SampleDataTests {
    let now = Fixtures.now

    @Test func dashboardIsDeterministic() {
        #expect(SampleData.dashboard(now: now) == SampleData.dashboard(now: now))
    }

    @Test func dashboardRoundTripsThroughJSON() throws {
        let dashboard = SampleData.dashboard(now: now)
        let data = try JSONCoding.makeEncoder().encode(dashboard)
        let decoded = try JSONCoding.makeDecoder().decode(Dashboard.self, from: data)
        #expect(decoded.games.map(\.id) == dashboard.games.map(\.id))
        #expect(decoded.totalCCU == dashboard.totalCCU)
    }

    @Test func includesVisualQAEdgeCases() {
        let games = SampleData.games(now: now)
        #expect(games.contains { $0.stats.ccu == 0 })
        #expect(games.contains { $0.name.count > 50 })
        #expect(games.contains { $0.stats.robux24h == nil })
        #expect(games.contains { $0.stats.visits >= 1_000_000_000 })
    }

    @Test func seriesNeverNegativeAndEndsAtNow() throws {
        for seed in SampleData.seeds {
            let series = SampleData.ccuSeries(for: seed, end: now, duration: 7 * 86_400, step: 3_600)
            #expect(series.points.allSatisfy { $0.value >= 0 })
            let latest = try #require(series.latest)
            #expect(latest.date == now)
        }
    }

    @Test(arguments: [0.0, -10])
    func degenerateSeriesParametersReturnSinglePoint(duration: TimeInterval) {
        let series = SampleData.ccuSeries(for: SampleData.seeds[0], end: now, duration: duration, step: 60)
        #expect(series.points.count == 1)
    }

    @Test func snapshotFromSampleDashboard() {
        let snapshot = SampleData.dashboard(now: now).widgetSnapshot
        #expect(snapshot.games.count == SampleData.seeds.count)
        #expect(snapshot.games.first?.isFavourite == true)
        #expect(snapshot.goals.count == 3)
        #expect(snapshot.games.allSatisfy { $0.sparkline.count <= WidgetSnapshot.sparklinePoints })
    }
}

struct DemoDashboardServiceTests {
    @Test func favouriteEditsPersistWithinSession() async throws {
        let service = DemoDashboardService(now: { Fixtures.now })
        let id = SampleData.seeds[2].id
        try await service.setFavourite(gameID: id, isFavourite: true)
        try await service.setWorkingOn(gameID: id, isWorkingOn: true)
        let game = try #require(try await service.dashboard().games.first { $0.id == id })
        #expect(game.isFavourite)
        #expect(game.isWorkingOn)
    }

    @Test func emptyAndFailingModes() async throws {
        #expect(try await DemoDashboardService(mode: .empty).dashboard().games.isEmpty)
        let failing = DemoDashboardService(mode: .failing)
        await #expect(throws: DemoDashboardService.DemoFailure.self) { try await failing.dashboard() }
        await #expect(throws: DemoDashboardService.DemoFailure.self) {
            try await failing.series(gameID: 1, metric: .ccu, range: .day)
        }
    }

    @Test(arguments: TimeRange.allCases)
    func seriesCoversRequestedRange(range: TimeRange) async throws {
        let service = DemoDashboardService(now: { Fixtures.now })
        let series = try await service.series(gameID: SampleData.seeds[0].id, metric: .ccu, range: range)
        let first = try #require(series.points.first)
        #expect(Fixtures.now.timeIntervalSince(first.date) == range.duration)
    }

    @Test func unknownGameHasEmptySeries() async throws {
        let series = try await DemoDashboardService().series(gameID: 1, metric: .ccu, range: .day)
        #expect(series.points.isEmpty)
    }
}
