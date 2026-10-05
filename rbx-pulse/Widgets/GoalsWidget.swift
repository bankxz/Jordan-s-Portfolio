import AppIntents
import RBXPulseKit
import SwiftUI
import WidgetKit

struct GoalsEntry: TimelineEntry {
    let date: Date
    let goals: [WidgetSnapshot.GoalEntry]
}

/// No options yet; using the App Intent provider keeps the async API (no completion handlers).
struct GoalsWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Goals"
    static let description = IntentDescription("Shows progress on your active goals.")
}

struct GoalsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> GoalsEntry {
        GoalsEntry(date: .now, goals: Self.sample)
    }

    func snapshot(for configuration: GoalsWidgetIntent, in context: Context) async -> GoalsEntry {
        let goals = WidgetData.loadSnapshot()?.goals ?? []
        return GoalsEntry(date: .now, goals: goals.isEmpty && context.isPreview ? Self.sample : goals)
    }

    func timeline(for configuration: GoalsWidgetIntent, in context: Context) async -> Timeline<GoalsEntry> {
        let entry = GoalsEntry(date: .now, goals: WidgetData.loadSnapshot()?.goals ?? [])
        return Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(60 * 60)))
    }

    static let sample: [WidgetSnapshot.GoalEntry] = [
        .init(id: UUID(), title: "Hit 6K CCU", progress: 0.62, status: .onTrack),
        .init(id: UUID(), title: "100K favourites", progress: 0.41, status: .atRisk),
        .init(id: UUID(), title: "First 100 players", progress: 0.1, status: .behind),
    ]
}

struct GoalsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: SharedConfiguration.goalsWidgetKind, intent: GoalsWidgetIntent.self,
                               provider: GoalsProvider()) { entry in
            GoalsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Goals")
        .description("Progress on your active goals.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct GoalsWidgetView: View {
    let entry: GoalsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let active = entry.goals.filter { $0.status != .achieved }
        let shown = Array(active.prefix(family == .systemSmall ? 2 : 3))
        VStack(alignment: .leading, spacing: 8) {
            Label("Goals", systemImage: "flag.checkered")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
            if shown.isEmpty {
                Text(entry.goals.isEmpty ? "Set a goal in RBX Pulse" : "All goals achieved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(shown) { goal in
                Link(destination: Route.goal(id: goal.id).url) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(goal.title).font(.caption).lineLimit(1)
                        ProgressView(value: goal.progress)
                            .tint(goal.status == .onTrack ? Color.accentColor
                                  : (goal.status == .atRisk ? Color.orange : Color.red))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(Route.goals.url)
    }
}
