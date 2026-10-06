import SwiftUI

/// Five tabs: the HIG maximum for an iPhone tab bar.
enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case home, games, goals, ads, alerts

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .home: "Home"
        case .games: "Games"
        case .goals: "Goals"
        case .ads: "Ads"
        case .alerts: "Alerts"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "waveform.path.ecg"
        case .games: "gamecontroller"
        case .goals: "flag.checkered"
        case .ads: "megaphone"
        case .alerts: "bell"
        }
    }
}

/// Pushed destinations, shared by every tab's NavigationStack.
enum Destination: Hashable {
    case game(id: Int64)
    case goal(id: UUID)
    case campaign(id: String)
    case briefing
}
