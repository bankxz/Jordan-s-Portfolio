import Foundation
import PeakKit
import Testing
@testable import Peak

/// Scripted sign-in service.
actor ScriptedSignIn: SignInService {
    var signedIn: Bool
    var completeError: (any Error)?
    private(set) var completedWith: [URL] = []
    private(set) var signOutCount = 0

    nonisolated var usesWebSignIn: Bool { true }

    init(signedIn: Bool, completeError: (any Error)? = nil) {
        self.signedIn = signedIn
        self.completeError = completeError
    }

    func isSignedIn() async -> Bool { signedIn }
    func authorizeURL() async throws -> URL { URL(string: "https://apis.roblox.com/oauth/v1/authorize?state=s")! }
    func complete(callbackURL: URL) async throws {
        completedWith.append(callbackURL)
        if let completeError { throw completeError }
        signedIn = true
    }
    func signOut() async {
        signOutCount += 1
        signedIn = false
    }
}

@MainActor
struct AccountModelTests {
    static let callback = URL(string: "peakstats://auth/complete?code=pk_sc_1")!

    @Test func signsInThroughTheWebPageAndOut() async {
        let service = ScriptedSignIn(signedIn: false)
        let account = AccountModel(service: service, canSignOut: true)
        await account.load()
        #expect(account.state == .signedOut)

        var opened: URL?
        await account.signIn { url in
            opened = url
            return Self.callback
        }
        #expect(opened?.host == "apis.roblox.com")
        #expect(account.state == .signedIn)
        #expect(await service.completedWith == [Self.callback])

        await account.signOut()
        #expect(account.state == .signedOut)
        #expect(await service.signOutCount == 1)
    }

    @Test func cancellingIsQuietAndRefusalExplains() async {
        let account = AccountModel(service: ScriptedSignIn(signedIn: false), canSignOut: true)
        await account.load()
        await account.signIn { _ in throw CancellationError() }
        #expect(account.state == .signedOut)
        #expect(account.message == nil)

        let refused = AccountModel(service: ScriptedSignIn(signedIn: false, completeError: SignInError.denied), canSignOut: true)
        await refused.load()
        await refused.signIn { _ in Self.callback }
        #expect(refused.state == .signedOut)
        #expect(refused.message?.contains("permission") == true)
    }

    @Test func endedSessionsReturnToSignIn() async {
        let service = ScriptedSignIn(signedIn: true)
        let account = AccountModel(service: service, canSignOut: true)
        await account.load()
        #expect(account.state == .signedIn)

        await account.sessionEnded(reconnectOnly: true)
        #expect(account.state == .signedOut)
        #expect(account.message?.contains("Roblox disconnected") == true)
        #expect(await service.signOutCount == 0, "a Roblox reconnect keeps the Peak session")

        await account.sessionEnded(reconnectOnly: false)
        #expect(await service.signOutCount == 1)
    }

    @Test func dashboardErrorsMapToSessionProblems() {
        #expect(AppModel.sessionProblem(for: AuthError.sessionExpired) == .signedOut)
        #expect(AppModel.sessionProblem(for: APIError.unauthorized) == .signedOut)
        #expect(AppModel.sessionProblem(for: APIError.reconnectRequired) == .reconnectRoblox)
        #expect(AppModel.sessionProblem(for: APIError.server(status: 500)) == nil)
        #expect(AppModel.sessionProblem(for: URLError(.notConnectedToInternet)) == nil)
    }

    @Test func resetForgetsTheAccount() async {
        let model = AppModel(service: DemoDashboardService(mode: .normal), snapshotStore: nil)
        await model.refresh()
        model.selectedTab = .ads
        model.gamesPath = [.game(id: 1)]
        model.reset()
        #expect(model.dashboard == nil)
        #expect(model.selectedTab == .home)
        #expect(model.gamesPath.isEmpty)
    }
}
