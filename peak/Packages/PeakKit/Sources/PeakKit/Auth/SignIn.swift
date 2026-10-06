import Foundation

/// What the backend's OAuth redirect (`peakstats://auth/complete?…`) says happened.
public enum SignInCallback: Equatable, Sendable {
    case code(String)
    /// The stable error code from the backend (`access_denied`, `authorization_failed`, `invalid_state`…).
    case failure(String)

    /// `nil` for any URL that isn't a well-formed Peak sign-in callback.
    public init?(url: URL) {
        if case .authComplete(let code)? = Route(url: url) {
            self = .code(code)
            return
        }
        guard url.scheme?.lowercased() == Route.scheme, url.host?.lowercased() == "auth",
              url.pathComponents.filter({ $0 != "/" }) == ["complete"],
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let errors = items.filter { $0.name == "error" }.compactMap(\.value)
        // Only short, plain codes; anything else is reported generically rather than shown.
        guard errors.count == 1, let error = errors.first else { return nil }
        let isPlain = error.count <= 64 && error.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        self = .failure(isPlain ? error : "authorization_failed")
    }
}

public enum SignInError: Error, Equatable, Sendable {
    /// The creator said no on Roblox's consent screen.
    case denied
    /// Roblox or the backend couldn't complete the sign-in (expired attempt, bad state, upstream error).
    case failed(code: String)
    /// The browser returned something that isn't a Peak callback.
    case invalidCallback
}

/// Signs the creator in with Roblox through the backend (decision 0005): the backend runs OAuth with PKCE and
/// hands the app a one-time session code, which the app exchanges for Peak tokens.
public protocol SignInService: Sendable {
    /// `false` when no browser step is needed (demo mode).
    var usesWebSignIn: Bool { get }
    func isSignedIn() async -> Bool
    /// The Roblox consent page to open in a web authentication session.
    func authorizeURL() async throws -> URL
    /// Finishes sign-in with the URL the web session returned.
    func complete(callbackURL: URL) async throws
    func signOut() async
}

public struct RemoteSignInService: SignInService {
    private let client: APIClient
    private let session: AuthSessionCoordinator

    public init(client: APIClient, session: AuthSessionCoordinator) {
        self.client = client
        self.session = session
    }

    public var usesWebSignIn: Bool { true }

    public func isSignedIn() async -> Bool { await session.isSignedIn() }

    public func authorizeURL() async throws -> URL {
        let url = try await client.send(BackendAPI.startRobloxAuth()).authorizeURL
        // Only ever open https pages from the backend in the sign-in browser.
        guard url.scheme == "https" else { throw SignInError.failed(code: "invalid_authorize_url") }
        return url
    }

    public func complete(callbackURL: URL) async throws {
        switch SignInCallback(url: callbackURL) {
        case .code(let code)?:
            try await session.signIn(with: try await client.send(BackendAPI.exchangeSessionCode(code)))
        case .failure("access_denied")?:
            throw SignInError.denied
        case .failure(let code)?:
            throw SignInError.failed(code: code)
        case nil:
            throw SignInError.invalidCallback
        }
    }

    /// Ends this device's session on the backend too; local tokens are cleared even if that call fails.
    public func signOut() async {
        _ = try? await client.send(BackendAPI.logout())
        await session.signOut()
    }
}

/// Demo mode: signed in with sample data unless started signed out (to show the sign-in screen). Signing in
/// "succeeds" without a network call.
public actor DemoSignInService: SignInService {
    private var signedIn: Bool

    public init(signedIn: Bool = true) {
        self.signedIn = signedIn
    }

    public nonisolated var usesWebSignIn: Bool { false }
    public func isSignedIn() async -> Bool { signedIn }
    public func authorizeURL() async throws -> URL { URL(string: "https://apis.roblox.com/oauth/v1/authorize")! }
    public func complete(callbackURL: URL) async throws { signedIn = true }
    public func signOut() async { signedIn = false }
}
