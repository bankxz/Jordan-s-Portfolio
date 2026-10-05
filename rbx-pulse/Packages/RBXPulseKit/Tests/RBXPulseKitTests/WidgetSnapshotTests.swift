import Foundation
import Testing
@testable import RBXPulseKit

struct WidgetSnapshotTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func game(_ id: Int64, ccu: Int, favourite: Bool = false) -> Game {
        Game(id: id, rootPlaceID: id * 10, name: "Game \(id)", isFavourite: favourite,
             stats: GameStats(ccu: ccu, ccuYesterday: 100, visits: 1_000, favourites: 10,
                              robux24h: 50, updatedAt: now))
    }

    @Test func ordersFavouritesFirstThenByCCU() {
        let snapshot = WidgetSnapshot.make(
            games: [game(1, ccu: 50), game(2, ccu: 900), game(3, ccu: 10, favourite: true), game(4, ccu: 900)],
            ccuHistory: [:], goals: [], now: now)
        #expect(snapshot.games.map(\.id) == [3, 2, 4, 1])
        #expect(snapshot.defaultGame?.id == 3)
    }

    @Test func sparklineIsDownsampled() {
        let history = MetricSeries(metric: .ccu, points: (0..<500).map {
            MetricPoint(date: now.addingTimeInterval(Double($0) * 60), value: Double($0))
        })
        let snapshot = WidgetSnapshot.make(games: [game(1, ccu: 1)], ccuHistory: [1: history], goals: [], now: now)
        #expect(snapshot.game(id: 1)?.sparkline.count == WidgetSnapshot.sparklinePoints)
        #expect(snapshot.game(id: 99) == nil)
    }

    @Test func goalUsesCurrentGameValue() throws {
        let goal = Goal(title: "1K CCU", gameID: 1, metric: .ccu, startValue: 0, targetValue: 1_000, createdAt: now)
        let orphan = Goal(title: "Unknown game", gameID: 404, metric: .ccu, startValue: 0, targetValue: 10, createdAt: now)
        let snapshot = WidgetSnapshot.make(games: [game(1, ccu: 250)], ccuHistory: [:], goals: [goal, orphan], now: now)
        let entry = try #require(snapshot.goals.first)
        #expect(entry.progress == 0.25)
        #expect(snapshot.goals.last?.progress == 0)
    }

    @Test func duplicateGameIDsDoNotCrash() {
        let snapshot = WidgetSnapshot.make(games: [game(1, ccu: 5), game(1, ccu: 6)], ccuHistory: [:],
                                           goals: [Goal(title: "g", gameID: 1, metric: .ccu, startValue: 0,
                                                        targetValue: 10, createdAt: now)], now: now)
        #expect(snapshot.games.count == 2)
    }
}

struct SnapshotStoreTests {
    let directory: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rbxpulse-tests-\(UUID().uuidString)", isDirectory: true)
    }

    var store: SnapshotStore { SnapshotStore(fileURL: directory.appendingPathComponent("nested/snap.json")) }

    func sample() -> WidgetSnapshot {
        WidgetSnapshot(generatedAt: Date(timeIntervalSince1970: 1_790_000_000), games: [
            .init(id: 1, name: "Attack Animals", ccu: 1_234, ccuChange: 0.1, robux24h: nil, isFavourite: true,
                  sparkline: [1, 2, 3], updatedAt: Date(timeIntervalSince1970: 1_790_000_000)),
        ], goals: [])
    }

    @Test func missingFileLoadsNil() {
        #expect(store.load() == nil)
    }

    @Test func saveThenLoadRoundTrips() throws {
        try store.save(sample())
        #expect(store.load() == sample())
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func corruptFileLoadsNil() throws {
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.fileURL)
        #expect(store.load() == nil)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func otherSchemaVersionLoadsNil() throws {
        var old = sample()
        old.version = WidgetSnapshot.currentVersion + 1
        try store.save(old)
        #expect(store.load() == nil)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func overwriteReplacesPreviousSnapshot() throws {
        try store.save(sample())
        var newer = sample()
        newer.games[0].ccu = 9_999
        try store.save(newer)
        #expect(store.load()?.games.first?.ccu == 9_999)
        try? FileManager.default.removeItem(at: directory)
    }
}
