import PeakKit
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(InsightsModel.self) private var insights
    @State private var isAsking = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Peak")
        .refreshable {
            let model = model, insights = insights
            async let dashboard: Void = model.refresh()
            async let briefing: Void = insights.refresh()
            _ = await (dashboard, briefing)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAsking = true
                } label: {
                    Label("Ask Peak", systemImage: "sparkles")
                }
                .accessibilityIdentifier("askButton")
            }
        }
        .sheet(isPresented: $isAsking) {
            AskView()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let dashboard = model.dashboard {
            if model.isShowingStaleData, case .failed(let message) = model.phase {
                StaleDataBanner(message: message)
            }
            if dashboard.games.isEmpty {
                EmptyStateView(title: "No games yet",
                               message: "Connect Roblox to see live players, revenue and goals for your experiences.",
                               systemImage: "gamecontroller")
                    .padding(.top, 40)
            } else {
                loadedContent(dashboard)
            }
        } else if case .failed(let message) = model.phase {
            ErrorCard(message: message) { await model.refresh() }
        } else {
            LoadingCard(lines: 4)
            LoadingCard()
            LoadingCard()
        }
    }

    @ViewBuilder
    private func loadedContent(_ dashboard: Dashboard) -> some View {
        LiveNowCard(totalCCU: dashboard.totalCCU, totalRobux: dashboard.totalRobux24h,
                         gameCount: dashboard.games.count, updatedAt: dashboard.generatedAt,
                         now: model.currentDate)

        briefingSection

        let focus = focusGames(dashboard)
        if focus.isEmpty == false {
            SectionHeader(title: "Your games", actionTitle: "See all") {
                model.selectedTab = .games
            }
            ForEach(focus) { game in
                NavigationLink(value: Destination.game(id: game.id)) {
                    GameCard(game: game, sparkline: dashboard.sparkline(for: game.id)?.downsampled(to: 24).map(\.value) ?? [])
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("gameCard.\(game.id)")
            }
        }

        let activeGoals = dashboard.goals.filter { model.evaluation(for: $0).status != .achieved }
        if activeGoals.isEmpty == false {
            SectionHeader(title: "Goals", actionTitle: "See all") {
                model.selectedTab = .goals
            }
            ForEach(activeGoals.prefix(2)) { goal in
                NavigationLink(value: Destination.goal(id: goal.id)) {
                    GoalCard(goal: goal, evaluation: model.evaluation(for: goal))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("goalCard.\(goal.id.uuidString)")
            }
        }

        if let alert = dashboard.recentAlerts.max(by: { $0.firedAt < $1.firedAt }) {
            SectionHeader(title: "Latest alert")
            AlertRow(event: alert, gameName: model.game(id: alert.gameID)?.name ?? "Unknown game",
                     now: model.currentDate)
                .card()
        }
    }

    @ViewBuilder
    private var briefingSection: some View {
        switch insights.briefing {
        case .loaded(let briefing):
            NavigationLink(value: Destination.briefing) {
                BriefingCard(briefing: briefing)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("briefingCard")
        case .failed:
            // The dashboard is still useful without the briefing; keep the error small.
            Label("Today's briefing couldn't load. Pull to refresh.", systemImage: "sun.max")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .card()
        default:
            LoadingCard(lines: 3)
        }
    }

    /// Favourites and games marked "Working on" first; otherwise the top games by CCU.
    private func focusGames(_ dashboard: Dashboard) -> [Game] {
        let pinned = dashboard.games.filter { $0.isFavourite || $0.isWorkingOn }
        let source = pinned.isEmpty ? dashboard.games : pinned
        return Array(source.sorted { $0.stats.ccu > $1.stats.ccu }.prefix(4))
    }
}

#Preview("Loaded") {
    NavigationStack { HomeView() }
        .environment(PreviewSupport.model(.normal))
        .environment(PreviewSupport.insights(.normal))
}

#Preview("Empty") {
    NavigationStack { HomeView() }
        .environment(PreviewSupport.model(.empty))
        .environment(PreviewSupport.insights(.empty))
}

#Preview("Error") {
    NavigationStack { HomeView() }
        .environment(PreviewSupport.model(.failing))
        .environment(PreviewSupport.insights(.failing))
}
