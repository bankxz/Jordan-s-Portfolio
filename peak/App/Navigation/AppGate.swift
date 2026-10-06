import PeakKit
import SwiftUI

/// Sign-in in front of the tabs. Also returns to sign-in when the session or the Roblox connection ends.
struct AppGate: View {
    @Environment(AccountModel.self) private var account
    @Environment(AppModel.self) private var model
    @Environment(InsightsModel.self) private var insights

    var body: some View {
        Group {
            switch account.state {
            case .checking:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedIn:
                RootView()
            case .signedOut, .signingIn:
                SignInView()
            }
        }
        .task { await account.load() }
        .task(id: model.sessionProblem) {
            guard let problem = model.sessionProblem else { return }
            await account.sessionEnded(reconnectOnly: problem == .reconnectRoblox)
        }
        .onChange(of: account.state) { _, state in
            // Don't leave one account's games on screen, or in memory, after signing out.
            if state == .signedOut {
                model.reset()
                insights.reset()
            }
        }
    }
}
