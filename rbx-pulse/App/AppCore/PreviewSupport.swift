import RBXPulseKit
import SwiftUI

/// Models for SwiftUI previews. Each preview gets its own model so state doesn't leak between them.
@MainActor
enum PreviewSupport {
    static func model(_ mode: DemoDashboardService.Mode) -> AppModel {
        let model = AppModel(service: DemoDashboardService(mode: mode), snapshotStore: nil)
        Task { await model.refresh() }
        return model
    }
}
