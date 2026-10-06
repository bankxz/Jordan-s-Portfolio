import Foundation
import Observation
import PeakKit

/// Whether the creator is signed in, and the sign-in / sign-out flow.
///
/// The web part (Roblox's consent page) is opened by the view through SwiftUI's `webAuthenticationSession`
/// and passed in as `authenticate`, so this model stays testable.
@MainActor
@Observable
final class AccountModel {
    enum State: Equatable {
        case checking
        case signedOut
        case signingIn
        case signedIn
    }

    private(set) var state: State = .checking
    /// Why the sign-in screen is showing, or what went wrong with the last attempt.
    private(set) var message: String?

    let service: any SignInService
    /// Demo mode has nothing to sign out of.
    let canSignOut: Bool

    init(service: any SignInService, canSignOut: Bool) {
        self.service = service
        self.canSignOut = canSignOut
    }

    func load() async {
        guard state == .checking else { return }
        state = await service.isSignedIn() ? .signedIn : .signedOut
    }

    func signIn(authenticate: @MainActor (URL) async throws -> URL) async {
        guard state != .signingIn else { return }
        state = .signingIn
        message = nil
        do {
            let page = try await service.authorizeURL()
            let callback: URL
            if service.usesWebSignIn {
                callback = try await authenticate(page)
            } else {
                callback = Route.authComplete(code: "demo").url
            }
            try await service.complete(callbackURL: callback)
            state = .signedIn
        } catch is CancellationError {
            state = .signedOut
        } catch {
            state = .signedOut
            message = Self.message(for: error)
        }
    }

    func signOut() async {
        await service.signOut()
        message = nil
        state = .signedOut
    }

    /// The dashboard reported that the session or the Roblox connection is gone.
    func sessionEnded(reconnectOnly: Bool) async {
        if reconnectOnly == false {
            await service.signOut()
        }
        message = reconnectOnly
            ? "Roblox disconnected Peak (the permission was removed or expired). Connect again to keep your stats updating."
            : "You were signed out. Sign in again to see your games."
        state = .signedOut
    }

    static func message(for error: any Error) -> String {
        switch error as? SignInError {
        case .denied?: return "Peak needs your permission on Roblox to show your games. Nothing was shared."
        case .failed?, .invalidCallback?: return "Roblox sign-in didn't finish. Try again."
        case nil: return AppModel.message(for: error)
        }
    }
}
