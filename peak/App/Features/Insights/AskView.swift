import PeakKit
import SwiftUI

/// "Ask Peak": questions about the creator's own games, answered from their data.
/// Shown as a sheet from Home. Needs AI consent first (decision 0007).
struct AskView: View {
    @Environment(InsightsModel.self) private var insights
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let settings = insights.settings {
                    if settings.available == false {
                        EmptyStateView(title: "AI isn't available",
                                       message: "Your briefing, alerts and update reports still work without it.",
                                       systemImage: "sparkles")
                    } else if settings.consented == false {
                        AIConsentView()
                    } else {
                        conversation(settings)
                    }
                } else if let error = insights.settingsError {
                    ErrorCard(message: error) { await insights.loadSettings() }
                        .padding()
                } else {
                    ProgressView()
                        .task { await insights.loadSettings() }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Ask Peak")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if insights.settings?.consented == true {
                    ToolbarItem(placement: .primaryAction) {
                        Menu("Options", systemImage: "ellipsis.circle") {
                            Button("Clear conversation", systemImage: "trash") { insights.clearConversation() }
                            Button("Turn off AI features", systemImage: "xmark.circle", role: .destructive) {
                                Task { await insights.setConsent(false) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func conversation(_ settings: BackendAPI.AISettings) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if insights.conversation.isEmpty {
                        Text("Ask about your games. Answers use only your Peak data, and every number is checked against it.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        ForEach(InsightsModel.suggestedQuestions, id: \.self) { suggestion in
                            Button {
                                Task { await insights.ask(suggestion) }
                            } label: {
                                Label(suggestion, systemImage: "text.bubble")
                                    .font(.subheadline)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                            .disabled(insights.isAsking)
                        }
                    }
                    ForEach(insights.conversation) { exchange in
                        ExchangeView(exchange: exchange)
                            .id(exchange.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: insights.conversation) {
                if let last = insights.conversation.last?.id {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .safeAreaInset(edge: .bottom) {
                inputBar(settings)
            }
        }
    }

    private func inputBar(_ settings: BackendAPI.AISettings) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                TextField("Ask about your games", text: $question, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .accessibilityIdentifier("askField")
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(canSend == false)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("sendButton")
            }
            Text("\(settings.asksRemainingToday) of \(settings.dailyAskLimit) questions left today")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var canSend: Bool {
        question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && insights.isAsking == false
    }

    private func send() {
        guard canSend else { return }
        let text = question
        question = ""
        Task { await insights.ask(text) }
    }
}

private struct ExchangeView: View {
    let exchange: InsightsModel.Exchange

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(exchange.question)
                .font(.subheadline.weight(.semibold))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 14))

            if let answer = exchange.answer {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        Text(answer.answer)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        if answer.isAIWritten { AIWrittenBadge() }
                    }
                    if answer.sources.isEmpty == false {
                        Text("Based on: " + answer.sources.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .card()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("askAnswer")
            } else if let error = exchange.error {
                Label(error, systemImage: "exclamationmark.bubble")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .card()
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Looking at your data…").font(.subheadline).foregroundStyle(.secondary)
                }
                .card()
            }
        }
    }
}

/// Explains what turning on AI sends where, before anything is sent (App Store 5.1.2(i); decision 0007).
struct AIConsentView: View {
    @Environment(InsightsModel.self) private var insights

    /// The server says which company it uses (Claude or DeepSeek); older servers only used Claude.
    private var providerName: String { insights.settings?.providerName ?? "Claude (Anthropic)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "sparkles")
                    .font(.largeTitle)
                    .foregroundStyle(.purple)
                    .accessibilityHidden(true)
                Text("Turn on AI features")
                    .font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Text("AI writes your daily briefing in plain English and answers questions about your games.")
                    .font(.body)

                VStack(alignment: .leading, spacing: 12) {
                    point("chart.bar", "What's sent",
                          "Stats for your games: names, player counts, revenue, changes and goals. Never player names or IDs.")
                    point("building.2", "Who processes it",
                          "Sent to \(providerName), only to write your briefing and answers. See Peak's privacy policy for details.")
                    point("checkmark.shield", "Numbers are checked",
                          "Any number not in your data is rejected, and Peak shows its own text instead.")
                    point("hand.raised", "You stay in control",
                          "AI never changes your games, prices, ads or groups. Turn it off any time from Ask Peak.")
                }
                .card()

                Button {
                    Task { await insights.setConsent(true) }
                } label: {
                    Group {
                        if insights.isChangingConsent { ProgressView() } else { Text("Turn on AI features") }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(insights.isChangingConsent)
                .accessibilityIdentifier("consentButton")

                if let error = insights.settingsError {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                }
            }
            .padding(16)
        }
    }

    private func point(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint)
        }
    }
}

#Preview("Consent") {
    AskView()
        .environment(PreviewSupport.insights())
}
