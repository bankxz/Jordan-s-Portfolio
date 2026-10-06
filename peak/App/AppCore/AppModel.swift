import Foundation
import Observation
import PeakKit

/// App-wide state: the dashboard, navigation and widget snapshot publishing.
///
/// Main-actor isolated because SwiftUI reads it; network work happens in the `DashboardService`.
@MainActor
@Observable
final class AppModel {
    enum LoadPhase: Equatable {
        case idle
        case loading
        case loaded
        case failed(message: String)
    }

    private(set) var phase: LoadPhase = .idle
    /// Last successfully loaded dashboard. Kept when a refresh fails so screens show stale data
    /// with a banner instead of going blank.
    private(set) var dashboard: Dashboard?
    /// Message for the most recent failed action (favourite toggle etc.), shown as a transient banner.
    var actionError: String?

    var selectedTab: AppTab = .home
    var homePath: [Destination] = []
    var gamesPath: [Destination] = []
    var goalsPath: [Destination] = []
    var adsPath: [Destination] = []
    var alertsPath: [Destination] = []

    let service: any DashboardService
    private let snapshotStore: SnapshotStore?
    private let onSnapshotPublished: @MainActor () -> Void
    private let now: @Sendable () -> Date

    init(
        service: any DashboardService,
        snapshotStore: SnapshotStore?,
        onSnapshotPublished: @escaping @MainActor () -> Void = {},
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.snapshotStore = snapshotStore
        self.onSnapshotPublished = onSnapshotPublished
        self.now = now
    }

    var currentDate: Date { now() }

    // MARK: Loading

    /// Loads the dashboard. Safe to call repeatedly (pull to refresh, foregrounding); the caller's
    /// task owns cancellation (`.task` / `.refreshable`).
    func refresh() async {
        if dashboard == nil { phase = .loading }
        do {
            let fresh = try await service.dashboard()
            dashboard = fresh
            phase = .loaded
            publishSnapshot(for: fresh)
        } catch is CancellationError {
            if dashboard == nil { phase = .idle }
        } catch {
            phase = .failed(message: Self.message(for: error))
        }
    }

    /// True when we're showing an older dashboard because the latest refresh failed.
    var isShowingStaleData: Bool {
        if case .failed = phase, dashboard != nil { return true }
        return false
    }

    // MARK: Game flags (optimistic)

    func toggleFavourite(gameID: Int64) async {
        await updateGame(gameID, keyPath: \.isFavourite) { service, value in
            try await service.setFavourite(gameID: gameID, isFavourite: value)
        }
    }

    func toggleWorkingOn(gameID: Int64) async {
        await updateGame(gameID, keyPath: \.isWorkingOn) { service, value in
            try await service.setWorkingOn(gameID: gameID, isWorkingOn: value)
        }
    }

    private func updateGame(
        _ gameID: Int64,
        keyPath: WritableKeyPath<Game, Bool>,
        send: (any DashboardService, Bool) async throws -> Void
    ) async {
        guard var current = dashboard, let index = current.games.firstIndex(where: { $0.id == gameID }) else { return }
        let newValue = !current.games[index][keyPath: keyPath]
        current.games[index][keyPath: keyPath] = newValue
        dashboard = current
        do {
            try await send(service, newValue)
            if let dashboard { publishSnapshot(for: dashboard) }
        } catch {
            // Revert only our change: re-read the latest state, which may have been refreshed meanwhile.
            if var latest = dashboard, let latestIndex = latest.games.firstIndex(where: { $0.id == gameID }),
               latest.games[latestIndex][keyPath: keyPath] == newValue {
                latest.games[latestIndex][keyPath: keyPath] = !newValue
                dashboard = latest
            }
            if (error is CancellationError) == false {
                actionError = "Couldn't save that change. Check your connection and try again."
            }
        }
    }

    // MARK: Lookups

    func game(id: Int64) -> Game? { dashboard?.games.first { $0.id == id } }
    func goal(id: UUID) -> Goal? { dashboard?.goals.first { $0.id == id } }
    func campaign(id: String) -> Campaign? { dashboard?.campaigns.first { $0.id == id } }

    func evaluation(for goal: Goal) -> GoalEvaluation {
        let currentValue = goal.gameID.flatMap { game(id: $0) }.map { WidgetSnapshot.value(of: goal.metric, in: $0.stats) }
        return GoalEngine.evaluate(goal, currentValue: currentValue ?? goal.startValue,
                                   history: [], now: now())
    }

    // MARK: Deep links

    /// Routes an external URL (widget, notification, Live Activity). Returns false for URLs we don't handle.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard let route = Route(url: url) else { return false }
        switch route {
        case .home:
            selectedTab = .home
            homePath = []
        case .games:
            selectedTab = .games
            gamesPath = []
        case .game(let id):
            selectedTab = .games
            gamesPath = [.game(id: id)]
        case .goals:
            selectedTab = .goals
            goalsPath = []
        case .goal(let id):
            selectedTab = .goals
            goalsPath = [.goal(id: id)]
        case .alerts:
            selectedTab = .alerts
            alertsPath = []
        case .campaign(let id):
            selectedTab = .ads
            adsPath = [.campaign(id: id)]
        case .authComplete:
            // Session exchange lands with the backend integration (decision 0003). Ignore safely until then.
            return false
        }
        return true
    }

    // MARK: Widgets

    private func publishSnapshot(for dashboard: Dashboard) {
        guard let snapshotStore else { return }
        do {
            try snapshotStore.save(dashboard.widgetSnapshot)
            onSnapshotPublished()
        } catch {
            // A failed snapshot write only means widgets keep their previous data.
        }
    }

    static func message(for error: any Error) -> String {
        let reconnect = "Your Roblox connection expired. Reconnect to keep your stats updating."
        let generic = "Something went wrong loading your stats."
        if error is AuthError { return reconnect }
        if let apiError = error as? APIError {
            switch apiError {
            case .unauthorized, .reconnectRequired:
                return reconnect
            case .rateLimited:
                return "Roblox is busy right now. We'll try again shortly."
            case .server, .unexpectedStatus:
                return "Peak is having trouble right now. Try again in a moment."
            case .forbidden, .notFound, .decoding:
                return generic
            }
        }
        if error is URLError {
            return "You're offline. Check your connection and try again."
        }
        return generic
    }
}
