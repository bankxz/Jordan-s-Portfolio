import AppIntents
import RBXPulseKit
import WidgetKit

/// A game the user can pick when configuring a widget. Backed by the cached snapshot only,
/// so configuration works offline and never triggers a network request from the extension.
struct GameEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Game"
    static let defaultQuery = GameEntityQuery()

    let id: Int64
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct GameEntityQuery: EntityQuery {
    func entities(for identifiers: [Int64]) async throws -> [GameEntity] {
        let games = WidgetData.loadSnapshot()?.games ?? []
        return identifiers.compactMap { id in
            games.first { $0.id == id }.map { GameEntity(id: $0.id, name: $0.name) }
        }
    }

    func suggestedEntities() async throws -> [GameEntity] {
        (WidgetData.loadSnapshot()?.games ?? []).map { GameEntity(id: $0.id, name: $0.name) }
    }

    func defaultResult() async -> GameEntity? {
        WidgetData.loadSnapshot()?.defaultGame.map { GameEntity(id: $0.id, name: $0.name) }
    }
}

struct SelectGameIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose game"
    static let description = IntentDescription("Pick which game this widget follows.")

    @Parameter(title: "Game")
    var game: GameEntity?

    init() {}

    init(game: GameEntity?) {
        self.game = game
    }
}

enum WidgetData {
    static func loadSnapshot() -> WidgetSnapshot? {
        SnapshotStore(appGroup: SharedConfiguration.appGroup)?.load()
    }
}
