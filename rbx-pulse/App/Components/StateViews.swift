import SwiftUI

/// Loading placeholder shaped like the content it replaces, so layout doesn't jump.
struct LoadingCard: View {
    var lines = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<lines, id: \.self) { index in
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(height: index == 0 ? 22 : 14)
                    .frame(maxWidth: index == lines - 1 ? 160 : .infinity, alignment: .leading)
            }
        }
        .card()
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}

struct EmptyStateView: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let systemImage: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
        .accessibilityIdentifier("emptyState")
    }
}

struct ErrorCard: View {
    let message: String
    let retry: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Couldn't load your stats", systemImage: "wifi.exclamationmark")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                Task { await retry() }
            } label: {
                Text("Try again").frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
        }
        .card()
        .accessibilityIdentifier("errorCard")
    }
}

/// Shown above content when a refresh failed but older data is still on screen.
struct StaleDataBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "clock.badge.exclamationmark")
            .font(.footnote)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
    }
}

struct SectionHeader: View {
    let title: LocalizedStringKey
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.medium))
                    .frame(minHeight: 44)
            }
        }
        .padding(.top, 8)
    }
}
