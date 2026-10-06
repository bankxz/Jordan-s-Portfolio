import Foundation
import PeakKit
import Testing
@testable import Peak

/// Fails on demand, so tests can exercise stale-data and revert paths.
actor ScriptedService: DashboardService {
    private let inner = DemoDashboardService(now: { Date(timeIntervalSince1970: 1_790_000_000) })
    var failDashboard = false
    var failWrites = false
    private(set) var favouriteWrites: [(Int64, Bool)] = []

    func setFailDashboard(_ value: Bool) { failDashboard = value }
    func setFailWrites(_ value: Bool) { failWrites = value }

    func dashboard() async throws -> Dashboard {
        if failDashboard { throw URLError(.notConnectedToInternet) }
        return try await inner.dashboard()
    }

    func series(gameID: Int64, metric: Metric, range: TimeRange) async throws -> MetricSeries {
        try await inner.series(gameID: gameID, metric: metric, range: range)
    }

    func setFavourite(gameID: Int64, isFavourite: Bool) async throws {
        favouriteWrites.append((gameID, isFavourite))
        if failWrites { throw URLError(.timedOut) }
        try await inner.setFavourite(gameID: gameID, isFavourite: isFavourite)
    }

    func setWorkingOn(gameID: Int64, isWorkingOn: Bool) async throws {
        if failWrites { throw URLError(.timedOut) }
        try await inner.setWorkingOn(gameID: gameID, isWorkingOn: isWorkingOn)
    }
}

@MainActor
struct AppModelTests {
    let service = ScriptedService()
    let snapshotURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("app-model-\(UUID().uuidString)/snapshot.json")

    func makeModel(publishCount: Counter? = nil) -> AppModel {
        AppModel(service: service, snapshotStore: SnapshotStore(fileURL: snapshotURL),
                 onSnapshotPublished: { publishCount?.value += 1 },
                 now: { Date(timeIntervalSince1970: 1_790_000_000) })
    }

    @MainActor
    final class Counter {
        var value = 0
    }

    @Test func refreshLoadsDashboardAndPublishesSnapshot() async throws {
        let counter = Counter()
        let model = makeModel(publishCount: counter)
        #expect(model.phase == .idle)

        await model.refresh()

        #expect(model.phase == .loaded)
        #expect(model.dashboard?.games.isEmpty == false)
        #expect(counter.value == 1)
        let snapshot = try #require(SnapshotStore(fileURL: snapshotURL).load())
        #expect(snapshot.games.count == model.dashboard?.games.count)
    }

    @Test func failedRefreshKeepsPreviousDataAndFlagsStale() async {
        let model = makeModel()
        await model.refresh()
        await service.setFailDashboard(true)

        await model.refresh()

        #expect(model.dashboard != nil)
        #expect(model.isShowingStaleData)
        if case .failed(let message) = model.phase {
            #expect(message.contains("offline"))
        } else {
            Issue.record("Expected failed phase, got \(model.phase)")
        }
    }

    @Test func firstLoadFailureHasNoStaleData() async {
        await service.setFailDashboard(true)
        let model = makeModel()
        await model.refresh()
        #expect(model.dashboard == nil)
        #expect(model.isShowingStaleData == false)
    }

    @Test func favouriteIsOptimisticAndPersisted() async throws {
        let model = makeModel()
        await model.refresh()
        let game = try #require(model.dashboard?.games.first { $0.isFavourite == false })

        await model.toggleFavourite(gameID: game.id)

        #expect(model.game(id: game.id)?.isFavourite == true)
        #expect(model.actionError == nil)
        let writes = await service.favouriteWrites
        #expect(writes.count == 1)
        #expect(writes.first?.0 == game.id)
        #expect(writes.first?.1 == true)
    }

    @Test func failedFavouriteRevertsAndReportsError() async throws {
        let model = makeModel()
        await model.refresh()
        let game = try #require(model.dashboard?.games.first { $0.isFavourite == false })
        await service.setFailWrites(true)

        await model.toggleFavourite(gameID: game.id)

        #expect(model.game(id: game.id)?.isFavourite == false)
        #expect(model.actionError != nil)
    }

    @Test func togglingUnknownGameIsANoOp() async {
        let model = makeModel()
        await model.refresh()
        await model.toggleFavourite(gameID: -1)
        #expect(await service.favouriteWrites.isEmpty)
    }

    @Test(arguments: [
        ("peakstats://game/920587237", AppTab.games),
        ("peakstats://goals", .goals),
        ("peakstats://alerts", .alerts),
        ("peakstats://campaign/spring-launch", .ads),
        ("peakstats://home", .home),
    ])
    func deepLinksSelectTab(urlString: String, tab: AppTab) throws {
        let model = makeModel()
        model.selectedTab = tab == .ads ? .home : .ads
        #expect(model.handle(url: try #require(URL(string: urlString))))
        #expect(model.selectedTab == tab)
    }

    @Test func gameDeepLinkPushesDetail() throws {
        let model = makeModel()
        model.gamesPath = [.game(id: 1), .game(id: 2)]
        model.handle(url: try #require(URL(string: "peakstats://game/42")))
        #expect(model.gamesPath == [.game(id: 42)])
    }

    @Test func invalidDeepLinkChangesNothing() throws {
        let model = makeModel()
        model.selectedTab = .goals
        #expect(model.handle(url: try #require(URL(string: "peakstats://game/abc"))) == false)
        #expect(model.handle(url: try #require(URL(string: "https://evil.example/game/1"))) == false)
        #expect(model.selectedTab == .goals)
    }

    @Test func errorMessages() {
        #expect(AppModel.message(for: AuthError.sessionExpired).contains("Reconnect"))
        #expect(AppModel.message(for: APIError.reconnectRequired).contains("Reconnect"))
        #expect(AppModel.message(for: APIError.rateLimited(retryAfter: 3)).contains("busy"))
        #expect(AppModel.message(for: URLError(.timedOut)).contains("offline"))
    }
}

struct AppConfigurationTests {
    @Test func demoModeArgumentWins() {
        let config = AppConfiguration.current(arguments: ["app", "-demoMode", "failing", "-colorScheme", "dark"])
        #expect(config.dataSource == .demo(.failing))
        #expect(config.forcedColorScheme == .dark)
    }

    @Test func launchURLArgument() {
        let config = AppConfiguration.current(arguments: ["app", "-openURL", "peakstats://goals"])
        #expect(config.launchURL?.absoluteString == "peakstats://goals")
        #expect(AppConfiguration.current(arguments: ["app"]).launchURL == nil)
    }

    @Test func missingValueFallsBackToDemo() {
        let config = AppConfiguration.current(arguments: ["app", "-demoMode"])
        #expect(config.dataSource == .demo(.normal))
        #expect(config.forcedColorScheme == nil)
    }
}
