import PeakKit
import SwiftUI

// Insight components. One definition per idea (swiftui-ui-patterns); screens reuse these.

/// Small "AI" marker for text written by AI from Peak's facts.
struct AIWrittenBadge: View {
    var body: some View {
        Label("AI", systemImage: "sparkles")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.purple.opacity(0.14), in: .capsule)
            .foregroundStyle(.purple)
            .accessibilityLabel("Written by AI from your stats")
    }
}

/// Possible causes are always labelled as such (decision 0007): never stated as fact.
struct PossibleCauseList: View {
    let causes: [PossibleCause]

    var body: some View {
        if causes.isEmpty == false {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(causes, id: \.self) { cause in
                    Label {
                        Text("Possible cause: ").fontWeight(.semibold) + Text(cause.evidence)
                    } icon: {
                        Image(systemName: "questionmark.circle")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// An unusual change: what happened, possible causes, one next step, and a Claude prompt to share.
struct DigestCard: View {
    let digest: AlertDigest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: digest.headline.isGoodNews ? "arrow.up.right.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(digest.headline.isGoodNews ? Color.green : Color.orange)
                    .accessibilityHidden(true)
                Text(digest.gameName)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                Text(digest.headline.detectedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(digest.message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            PossibleCauseList(causes: digest.causes)
            (Text("Next step: ").fontWeight(.semibold) + Text(digest.suggestedAction))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            ShareLink(item: ClaudePromptGenerator.render(ClaudePromptGenerator.prompt(for: digest)),
                      subject: Text("Peak: \(digest.gameName)"),
                      preview: SharePreview("Claude prompt for \(digest.gameName)")) {
                Label("Claude prompt", systemImage: "square.and.arrow.up")
                    .font(.footnote.weight(.medium))
                    .frame(minHeight: 44)
            }
            .accessibilityHint("Shares a prompt with these facts for Claude to investigate the code")
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("digest.\(digest.gameID)")
    }
}

/// "Improved", "Neutral", "Harmed" or "Too early", with a symbol so colour isn't the only signal.
struct VerdictBadge: View {
    let verdict: UpdateImpactReport.Verdict

    private var style: (title: LocalizedStringKey, symbol: String, colour: Color) {
        switch verdict {
        case .improved: ("Improved", "arrow.up.right", .green)
        case .neutral: ("Neutral", "equal", .secondary)
        case .harmed: ("Harmed", "arrow.down.right", .red)
        case .tooEarly: ("Too early", "hourglass", .secondary)
        }
    }

    var body: some View {
        let (title, symbol, colour) = style
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(colour.opacity(0.14), in: .capsule)
            .foregroundStyle(colour)
    }
}

/// Before/after comparison around the latest update.
struct UpdateImpactCard: View {
    let report: UpdateImpactReport
    let gameName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Latest update: \(report.updateLabel)")
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                VerdictBadge(verdict: report.verdict)
            }
            Text(report.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(report.metrics.filter { $0.verdict != .insufficientData }, id: \.metric) { impact in
                ImpactRow(impact: impact)
            }
            if report.caveats.isEmpty == false {
                ForEach(report.caveats, id: \.self) { caveat in
                    Label(caveat, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if report.verdict != .tooEarly {
                ShareLink(item: ClaudePromptGenerator.render(ClaudePromptGenerator.prompt(for: report, gameName: gameName)),
                          preview: SharePreview("Claude prompt for \(report.updateLabel)")) {
                    Label("Claude prompt", systemImage: "square.and.arrow.up")
                        .font(.footnote.weight(.medium))
                        .frame(minHeight: 44)
                }
            }
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("updateImpactCard")
    }
}

private struct ImpactRow: View {
    let impact: MetricImpact
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let before = impact.before.map { InsightText.value($0, metric: impact.metric) } ?? "—"
        let after = impact.after.map { InsightText.value($0, metric: impact.metric) } ?? "—"
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                                                  : AnyLayout(HStackLayout(spacing: 8))
        layout {
            Text(impact.metric.displayName)
                .font(.subheadline)
            if typeSize.isAccessibilitySize == false { Spacer() }
            Text("\(before) \u{2192} \(after)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            Image(systemName: symbol)
                .foregroundStyle(colour)
                .accessibilityLabel(impact.verdict.rawValue)
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch impact.verdict {
        case .improved: "checkmark.circle.fill"
        case .harmed: "xmark.circle.fill"
        default: "minus.circle"
        }
    }

    private var colour: Color {
        switch impact.verdict {
        case .improved: .green
        case .harmed: .red
        default: .secondary
        }
    }
}

/// Games ranked by health, with the weakest area spelled out.
struct PortfolioHealthCard: View {
    let ranking: [GameHealth]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Portfolio health", systemImage: "heart.text.square")
                .font(.headline)
            ForEach(ranking.prefix(5)) { health in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(health.score)")
                        .font(.headline.monospacedDigit())
                        .frame(minWidth: 44, minHeight: 32)
                        .background(colour(for: health.score).opacity(0.15), in: .rect(cornerRadius: 8))
                        .foregroundStyle(colour(for: health.score))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(health.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                            if health.needsUpdate {
                                Text("Needs update")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.15), in: .capsule)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Text(health.headline)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(health.name), health \(health.score) out of 100. \(health.headline)")
            }
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("portfolioCard")
    }

    private func colour(for score: Int) -> Color {
        switch score {
        case 70...: .green
        case 45..<70: .orange
        default: .red
        }
    }
}

/// Today's briefing on Home: headline and up to three actions.
struct BriefingCard: View {
    let briefing: Briefing

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Today's briefing", systemImage: "sun.max")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
                Spacer()
                if briefing.isAIWritten { AIWrittenBadge() }
            }
            Text(briefing.headline)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(briefing.actions.enumerated()), id: \.offset) { index, action in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .frame(width: 22, height: 22)
                        .background(Color.accentColor.opacity(0.15), in: .circle)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.title)
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(action.reason)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Action \(index + 1): \(action.title). \(action.reason)")
            }
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("briefingCard")
    }
}

/// A funnel the game logs: conversion per step as bars, the step to fix first highlighted, and a Claude prompt.
struct FunnelCard: View {
    let funnel: NamedFunnel
    let gameName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Funnel: \(funnel.name)", systemImage: "line.3.horizontal.decrease")
                .font(.headline)
            if let first = funnel.steps.first?.players, first > 0 {
                ForEach(Array(funnel.steps.enumerated()), id: \.offset) { index, step in
                    let isFocus = funnel.report.focus?.to == step.name && index > 0
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(step.name)
                                .font(.subheadline.weight(isFocus ? .semibold : .regular))
                            Spacer()
                            Text(MetricFormatter.compact(step.players))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        GeometryReader { proxy in
                            let share = min(1, Double(max(0, step.players)) / Double(first))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(isFocus ? Color.orange : Color.accentColor.opacity(0.6))
                                .frame(width: max(4, proxy.size.width * share))
                        }
                        .frame(height: 8)
                        .accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(step.name): \(MetricFormatter.compact(step.players)) players\(isFocus ? ", biggest drop" : "")")
                }
            }
            Text(funnel.report.summary)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(funnel.report.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if funnel.report.focus != nil {
                ShareLink(item: ClaudePromptGenerator.render(ClaudePromptGenerator.prompt(for: funnel.report, gameName: gameName)),
                          preview: SharePreview("Claude prompt for \(funnel.name)")) {
                    Label("Claude prompt", systemImage: "square.and.arrow.up")
                        .font(.footnote.weight(.medium))
                        .frame(minHeight: 44)
                }
            }
            Text("Last 7 days, from the funnel steps your game logs with AnalyticsService.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("funnelCard")
    }
}
