import RBXPulseKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            tab(.home, path: $model.homePath) { HomeView() }
            tab(.games, path: $model.gamesPath) { GamesListView() }
            tab(.goals, path: $model.goalsPath) { GoalsListView() }
            tab(.ads, path: $model.adsPath) { AdsView() }
            tab(.alerts, path: $model.alertsPath) { AlertsView() }
        }
        // Refresh on launch and whenever the app returns to the foreground. `.task(id:)` cancels the
        // previous load if the phase flips again, so there's never more than one refresh per scene.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.refresh()
        }
        .overlay(alignment: .top) {
            if let message = model.actionError {
                ActionErrorBanner(message: message) { model.actionError = nil }
                    .padding(.horizontal)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.actionError)
    }

    private func tab<Content: View>(_ tab: AppTab, path: Binding<[Destination]>,
                                    @ViewBuilder content: () -> Content) -> some View {
        NavigationStack(path: path) {
            content()
                .navigationDestination(for: Destination.self) { destination in
                    DestinationView(destination: destination)
                }
        }
        .tabItem { Label(tab.title, systemImage: tab.systemImage) }
        .tag(tab)
    }
}

private struct DestinationView: View {
    let destination: Destination

    var body: some View {
        switch destination {
        case .game(let id): GameDetailView(gameID: id)
        case .goal(let id): GoalDetailView(goalID: id)
        case .campaign(let id): CampaignDetailView(campaignID: id)
        }
    }
}

private struct ActionErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.leading, 14)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .task {
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled == false { dismiss() }
        }
    }
}
