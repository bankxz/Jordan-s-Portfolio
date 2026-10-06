import PeakKit
import SwiftUI

struct GamesListView: View {
    @Environment(AppModel.self) private var model
    @State private var searchText = ""

    var body: some View {
        Group {
            if let dashboard = model.dashboard {
                if dashboard.games.isEmpty {
                    EmptyStateView(title: "No games yet",
                                   message: "Games you own or collaborate on appear here once Roblox is connected.",
                                   systemImage: "gamecontroller")
                } else {
                    list(dashboard)
                }
            } else if case .failed(let message) = model.phase {
                ScrollView { ErrorCard(message: message) { await model.refresh() }.padding() }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Games")
        .background(Color(.systemGroupedBackground))
    }

    private func list(_ dashboard: Dashboard) -> some View {
        let games = filtered(dashboard.games)
        return List {
            if games.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
            ForEach(games) { game in
                NavigationLink(value: Destination.game(id: game.id)) {
                    GameListRow(game: game)
                }
                .accessibilityIdentifier("gameRow.\(game.id)")
                .swipeActions(edge: .leading) {
                    Button {
                        Task { await model.toggleFavourite(gameID: game.id) }
                    } label: {
                        Label(game.isFavourite ? "Unfavourite" : "Favourite",
                              systemImage: game.isFavourite ? "star.slash" : "star")
                    }
                    .tint(.yellow)
                }
                .contextMenu {
                    Button {
                        Task { await model.toggleFavourite(gameID: game.id) }
                    } label: {
                        Label(game.isFavourite ? "Remove from favourites" : "Add to favourites",
                              systemImage: game.isFavourite ? "star.slash" : "star")
                    }
                    Button {
                        Task { await model.toggleWorkingOn(gameID: game.id) }
                    } label: {
                        Label(game.isWorkingOn ? "Stop working on" : "Mark working on", systemImage: "hammer")
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search games")
        .refreshable { await model.refresh() }
    }

    /// Favourites first, then by live players.
    private func filtered(_ games: [Game]) -> [Game] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return games
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { lhs, rhs in
                if lhs.isFavourite != rhs.isFavourite { return lhs.isFavourite }
                return lhs.stats.ccu > rhs.stats.ccu
            }
    }
}

private struct GameListRow: View {
    let game: Game

    var body: some View {
        HStack(spacing: 12) {
            GameIcon(name: game.name)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(game.name).font(.headline).lineLimit(2)
                    if game.isFavourite {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                            .accessibilityLabel("Favourite")
                    }
                }
                Text("\(MetricFormatter.compact(game.stats.ccu)) playing · \(MetricFormatter.compact(game.stats.visits)) visits")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack { GamesListView() }
        .environment(PreviewSupport.model(.normal))
}
