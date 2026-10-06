import PeakKit
import SwiftUI

/// The full daily briefing: per-game facts (exact numbers), the AI summary when there is one, and actions.
struct BriefingView: View {
    @Environment(InsightsModel.self) private var insights

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch insights.briefing {
                case .loaded(let briefing):
                    content(briefing)
                case .failed(let message):
                    ErrorCard(message: message) { await insights.loadBriefing() }
                default:
                    LoadingCard(lines: 4)
                    LoadingCard()
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Briefing")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await insights.loadBriefing() }
    }

    @ViewBuilder
    private func content(_ briefing: Briefing) -> some View {
        BriefingCard(briefing: briefing)

        ForEach(briefing.games) { game in
            SectionHeader(title: LocalizedStringKey(game.name))
            VStack(alignment: .leading, spacing: 10) {
                if let summary = game.summary {
                    HStack(alignment: .top, spacing: 8) {
                        Text(summary)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        AIWrittenBadge()
                    }
                }
                ForEach(game.facts, id: \.self) { fact in
                    Label {
                        Text(fact.text)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: symbol(for: fact))
                            .foregroundStyle(colour(for: fact))
                    }
                }
            }
            .card()
        }

        Text(footnote(briefing))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private func footnote(_ briefing: Briefing) -> String {
        let base = "Facts come from your Roblox stats. Possible causes are suggestions to check, not confirmed."
        let writer = insights.settings?.providerName ?? "AI"
        return briefing.isAIWritten ? base + " Summaries marked AI were written by \(writer) from these facts and checked against them." : base
    }

    private func symbol(for fact: BriefFact) -> String {
        switch fact.isGoodNews {
        case true?: "arrow.up.right.circle.fill"
        case false?: "arrow.down.right.circle.fill"
        case nil: "circle.fill"
        }
    }

    private func colour(for fact: BriefFact) -> Color {
        switch fact.isGoodNews {
        case true?: .green
        case false?: .red
        case nil: Color.secondary.opacity(0.5)
        }
    }
}

#Preview {
    NavigationStack { BriefingView() }
        .environment(PreviewSupport.insights())
}
