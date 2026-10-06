import PeakKit
import SwiftUI

/// Models for SwiftUI previews. Each preview gets its own model so state doesn't leak between them.
@MainActor
enum PreviewSupport {
    static func model(_ mode: DemoDashboardService.Mode) -> AppModel {
        let model = AppModel(service: DemoDashboardService(mode: mode), snapshotStore: nil)
        Task { await model.refresh() }
        return model
    }

    static let notifications = NotificationController()

    static func account(signedIn: Bool = true) -> AccountModel {
        let model = AccountModel(service: DemoSignInService(signedIn: signedIn), canSignOut: true)
        Task { await model.load() }
        return model
    }

    static func insights(_ mode: DemoDashboardService.Mode = .normal, consented: Bool = false) -> InsightsModel {
        let model = InsightsModel(service: DemoInsightService(mode: mode, consented: consented))
        Task { await model.refresh() }
        return model
    }
}
