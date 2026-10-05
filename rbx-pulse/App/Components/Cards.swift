import RBXPulseKit
import SwiftUI

// One definition per card idea (swiftui-ui-patterns): every screen reuses these.

/// Shared card chrome.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

/// A single headline number with an optional change indicator.
struct MetricCard: View {
    let title: LocalizedStringKey
    let value: String
    var change: Double?
    var systemImage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(title)
            } icon: {
                if let systemImage { Image(systemName: systemImage) }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)

            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            if let change {
                ChangeBadge(change: change)
            }
        }
        .card()
        .accessibilityElement(children: .combine)
    }
}

/// "+12.4%" in green / "-3%" in red, with an arrow so colour isn't the only signal.
struct ChangeBadge: View {
    let change: Double

    var body: some View {
        let isUp = change > 0
        let isFlat = MetricFormatter.percentChange(change) == "0%"
        Label(MetricFormatter.percentChange(change),
              systemImage: isFlat ? "arrow.right" : (isUp ? "arrow.up.right" : "arrow.down.right"))
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(isFlat ? Color.secondary : (isUp ? Color.green : Color.red))
            .accessibilityLabel(Text("\(MetricFormatter.percentChange(change)) versus yesterday"))
    }
}

/// Hero card at the top of Home: total live players across all games.
struct CreatorPulseCard: View {
    let totalCCU: Int
    let totalRobux: Int64?
    let gameCount: Int
    let updatedAt: Date
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Live now", systemImage: "dot.radiowaves.left.and.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
                Spacer()
                FreshnessLabel(updatedAt: updatedAt, now: now)
            }
            Text(MetricFormatter.compact(totalCCU))
                .font(.system(.largeTitle, design: .rounded, weight: .heavy).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
            Text("players across \(gameCount) games")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let totalRobux {
                Label(MetricFormatter.robux(totalRobux) + " today", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.subheadline.weight(.medium))
            }
        }
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("creatorPulseCard")
    }
}

struct FreshnessLabel: View {
    let updatedAt: Date
    let now: Date

    var body: some View {
        let freshness = Freshness(updatedAt: updatedAt, now: now)
        Text(freshness.label)
            .font(.caption)
            .foregroundStyle(freshness.level == .stale ? Color.orange : Color.secondary)
    }
}

/// A game row/card: name, live CCU, change and sparkline.
struct GameCard: View {
    let game: Game
    var sparkline: [Double] = []

    var body: some View {
        HStack(spacing: 14) {
            GameIcon(name: game.name)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(game.name)
                        .font(.headline)
                        .lineLimit(2)
                    if game.isFavourite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Favourite")
                    }
                }
                HStack(spacing: 8) {
                    Text("\(MetricFormatter.compact(game.stats.ccu)) playing")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let change = game.stats.ccuChange {
                        ChangeBadge(change: change)
                    }
                }
                if game.isWorkingOn {
                    Text("Working on")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15), in: .capsule)
                        .foregroundStyle(.tint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if sparkline.count > 1 {
                Sparkline(values: sparkline)
                    .frame(width: 64, height: 32)
                    .accessibilityHidden(true)
            }
        }
        .card()
        .contentShape(.rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }
}

/// Placeholder icon until game thumbnails are loaded from the backend: first letter on a tinted tile.
struct GameIcon: View {
    let name: String

    var body: some View {
        let letter = name.first.map { String($0).uppercased() } ?? "?"
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.accentColor.opacity(0.18))
            .frame(width: 48, height: 48)
            .overlay {
                Text(letter)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.tint)
            }
            .accessibilityHidden(true)
    }
}

struct GoalCard: View {
    let goal: Goal
    let evaluation: GoalEvaluation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(goal.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 8)
                GoalStatusBadge(status: evaluation.status)
            }
            ProgressView(value: evaluation.progress)
                .tint(evaluation.status.tint)
            HStack {
                Text("\(Int((evaluation.progress * 100).rounded()))% · \(MetricFormatter.compact(goal.targetValue)) target")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if goal.tasks.isEmpty == false {
                    Label("\(goal.tasks.filter(\.isDone).count)/\(goal.tasks.count)", systemImage: "checklist")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .card()
        .accessibilityElement(children: .combine)
    }
}

struct GoalStatusBadge: View {
    let status: GoalStatus

    var body: some View {
        Text(status.title)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(status.tint.opacity(0.15), in: .capsule)
            .foregroundStyle(status.tint)
    }
}

extension GoalStatus {
    var title: LocalizedStringKey {
        switch self {
        case .achieved: "Achieved"
        case .onTrack: "On track"
        case .atRisk: "At risk"
        case .behind: "Behind"
        case .missed: "Missed"
        case .invalid: "Check goal"
        }
    }

    var tint: Color {
        switch self {
        case .achieved: .green
        case .onTrack: .accentColor
        case .atRisk: .orange
        case .behind, .missed: .red
        case .invalid: .gray
        }
    }
}

struct CampaignCard: View {
    let campaign: Campaign
    let gameName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(campaign.name).font(.headline).lineLimit(2)
                    if let gameName {
                        Text(gameName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(campaign.status.title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                stat("Spent", MetricFormatter.robux(campaign.spentRobux))
                stat("CTR", campaign.clickThroughRate.map { MetricFormatter.percent($0) } ?? "—")
                stat("Per play", campaign.costPerPlay.map { "R$" + MetricFormatter.decimal($0) } ?? "—")
            }
            if let used = campaign.budgetUsed {
                ProgressView(value: used) {
                    Text("Budget \(Int((used * 100).rounded()))% used").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .card()
        .accessibilityElement(children: .combine)
    }

    private func stat(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Campaign.Status {
    var title: LocalizedStringKey {
        switch self {
        case .scheduled: "Scheduled"
        case .running: "Running"
        case .paused: "Paused"
        case .completed: "Completed"
        }
    }
}

struct AlertRow: View {
    let event: AlertEvent
    let gameName: String
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bell.badge.fill")
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(gameName).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(event.metric.title) reached \(MetricFormatter.compact(event.value))")
                    .font(.subheadline)
                Text(Freshness(updatedAt: event.firedAt, now: now).label.replacingOccurrences(of: "Updated ", with: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension Metric {
    var title: String {
        switch self {
        case .ccu: "CCU"
        case .visits: "Visits"
        case .favourites: "Favourites"
        case .robux: "Robux"
        }
    }
}

extension MetricFormatter {
    /// 0.0123 → "1.2%".
    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "—" }
        let value = (fraction * 1000).rounded() / 10
        return value == value.rounded() ? "\(Int(value))%" : String(format: "%.1f%%", value)
    }

    /// 2.2222 → "2.22", 120 → "120".
    static func decimal(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value >= 100 { return compact(value) }
        return String(format: "%.2f", value)
    }
}
