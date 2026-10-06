import AppIntents
import PeakKit
import SwiftUI
import WidgetKit

struct GameWidgetEntry: TimelineEntry {
    let date: Date
    /// `nil` when the app hasn't written a snapshot yet or the chosen game is gone.
    let game: WidgetSnapshot.GameEntry?
    let isPlaceholder: Bool
}

/// Widgets are cached snapshots, not live mini-apps: entries come from the file the app writes after
/// each refresh, and the app asks WidgetKit to reload when that file changes.
struct GameTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> GameWidgetEntry {
        GameWidgetEntry(date: .now, game: Self.sample, isPlaceholder: true)
    }

    func snapshot(for configuration: SelectGameIntent, in context: Context) async -> GameWidgetEntry {
        if context.isPreview, WidgetData.loadSnapshot() == nil {
            return GameWidgetEntry(date: .now, game: Self.sample, isPlaceholder: false)
        }
        return entry(for: configuration, at: .now)
    }

    func timeline(for configuration: SelectGameIntent, in context: Context) async -> Timeline<GameWidgetEntry> {
        let now = Date.now
        let current = entry(for: configuration, at: now)
        var entries = [current]
        // Add an entry for the moment the data turns stale, so the widget visibly flags it even if
        // the app hasn't refreshed. The relative "updated" text keeps ticking on its own.
        if let updatedAt = current.game?.updatedAt {
            let staleAt = updatedAt.addingTimeInterval(Freshness.staleAfter)
            if staleAt > now {
                entries.append(GameWidgetEntry(date: staleAt, game: current.game, isPlaceholder: false))
            }
        }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60)))
    }

    private func entry(for configuration: SelectGameIntent, at date: Date) -> GameWidgetEntry {
        let snapshot = WidgetData.loadSnapshot()
        let game = configuration.game?.universeID.flatMap { snapshot?.game(id: $0) } ?? snapshot?.defaultGame
        return GameWidgetEntry(date: date, game: game, isPlaceholder: false)
    }

    static let sample = WidgetSnapshot.GameEntry(
        id: 920_587_237, name: "Attack Animals", ccu: 4_820, ccuChange: 0.124, robux24h: 182_400,
        isFavourite: true, sparkline: [3, 4, 3.5, 5, 6, 5.5, 7, 8, 7.2, 9], updatedAt: .now)
}

struct FavouriteGameWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: SharedConfiguration.favouriteGameWidgetKind,
                               intent: SelectGameIntent.self,
                               provider: GameTimelineProvider()) { entry in
            GameWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Live Players")
        .description("Live players for one of your games.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct GameWidgetView: View {
    let entry: GameWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let game = entry.game {
            content(game)
                .widgetURL(Route.game(id: game.id).url)
                .redacted(reason: entry.isPlaceholder ? .placeholder : [])
        } else {
            emptyState
                .widgetURL(Route.home.url)
        }
    }

    @ViewBuilder
    private func content(_ game: WidgetSnapshot.GameEntry) -> some View {
        let isStale = Freshness(updatedAt: game.updatedAt, now: entry.date).level == .stale
        switch family {
        case .accessoryInline:
            Text("\(game.name): \(MetricFormatter.compact(game.ccu)) playing")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(game.name).font(.headline).lineLimit(1)
                Text("\(MetricFormatter.compact(game.ccu)) playing").font(.body.monospacedDigit())
                updatedText(game, isStale: isStale).font(.caption2)
            }
        case .systemMedium:
            HStack(alignment: .top, spacing: 16) {
                summary(game, isStale: isStale)
                VStack(alignment: .trailing, spacing: 6) {
                    if game.sparkline.count > 1 {
                        Sparkline(values: game.sparkline)
                            .accessibilityHidden(true)
                    }
                    if let robux = game.robux24h {
                        Text(MetricFormatter.robux(robux) + " today")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        default:
            summary(game, isStale: isStale)
        }
    }

    private func summary(_ game: WidgetSnapshot.GameEntry, isStale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(game.name)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
            Spacer(minLength: 0)
            Text(MetricFormatter.compact(game.ccu))
                .font(.system(.title, design: .rounded, weight: .heavy).monospacedDigit())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(.tint)
            Text("playing")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let change = game.ccuChange {
                Text(MetricFormatter.percentChange(change))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(change >= 0 ? Color.green : Color.red)
            }
            updatedText(game, isStale: isStale)
                .font(.caption2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func updatedText(_ game: WidgetSnapshot.GameEntry, isStale: Bool) -> some View {
        Text(game.updatedAt, style: .relative)
            .foregroundStyle(isStale ? Color.orange : Color.secondary)
            .lineLimit(1)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "waveform.path.ecg").foregroundStyle(.tint)
            Text("Open Peak to load your games")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview(as: .systemSmall) {
    FavouriteGameWidget()
} timeline: {
    GameWidgetEntry(date: .now, game: GameTimelineProvider.sample, isPlaceholder: false)
    GameWidgetEntry(date: .now, game: nil, isPlaceholder: false)
}
