import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PeakKit

@Suite("Sign in with Roblox")
struct SignInTests {
    @Test(arguments: [
        ("peakstats://auth/complete?code=pk_sc_abc", SignInCallback.code("pk_sc_abc")),
        ("peakstats://auth/complete?error=access_denied", .failure("access_denied")),
        ("peakstats://auth/complete?error=invalid_state", .failure("invalid_state")),
        ("peakstats://auth/complete?error=%3Cscript%3E", .failure("authorization_failed")),
    ])
    func parsesCallbacks(url: String, expected: SignInCallback) {
        #expect(SignInCallback(url: URL(string: url)!) == expected)
    }

    @Test(arguments: [
        "peakstats://auth/complete",
        "peakstats://auth/complete?error=a&error=b",
        "peakstats://auth/other?error=access_denied",
        "https://auth/complete?code=x",
        "peakstats://game/1",
    ])
    func rejectsOtherURLs(url: String) {
        #expect(SignInCallback(url: URL(string: url)!) == nil)
    }

    func makeService(store: RecordingTokenStore, handler: @escaping FakeTransport.Handler) -> (RemoteSignInService, FakeTransport, AuthSessionCoordinator) {
        let transport = FakeTransport(handler: handler)
        let session = AuthSessionCoordinator(store: store, refresher: FakeRefresher(expiresAt: Fixtures.now),
                                             now: { Fixtures.now })
        let client = APIClient(baseURL: Fixtures.baseURL, transport: transport, auth: session)
        return (RemoteSignInService(client: client, session: session), transport, session)
    }

    @Test func fullSignInAndOut() async throws {
        let tokens = AuthTokens(accessToken: "access-new", refreshToken: "refresh-new",
                                accessTokenExpiresAt: Fixtures.now.addingTimeInterval(900))
        let store = RecordingTokenStore(tokens: nil)
        let (service, transport, session) = makeService(store: store) { request in
            switch request.url!.path {
            case "/v1/auth/roblox/start":
                return (200, Data(#"{"authorizeURL":"https://apis.roblox.com/oauth/v1/authorize?state=s"}"#.utf8), [:])
            case "/v1/auth/session":
                #expect(String(data: request.httpBody ?? Data(), encoding: .utf8)?.contains("pk_sc_abc") == true)
                return (200, try JSONCoding.makeEncoder().encode(tokens), [:])
            case "/v1/auth/logout":
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-new")
                return (204, Data(), [:])
            default:
                return (404, Data(), [:])
            }
        }
        #expect(await service.isSignedIn() == false)
        #expect(try await service.authorizeURL().host == "apis.roblox.com")
        try await service.complete(callbackURL: URL(string: "peakstats://auth/complete?code=pk_sc_abc")!)
        #expect(await service.isSignedIn())
        #expect(await store.tokens == tokens)

        await service.signOut()
        #expect(await session.isSignedIn() == false)
        #expect(await store.tokens == nil)
        #expect(await transport.requests.map { $0.url!.path } == ["/v1/auth/roblox/start", "/v1/auth/session", "/v1/auth/logout"])
    }

    @Test func refusalsAndBadCallbacksDontSignIn() async throws {
        let store = RecordingTokenStore(tokens: nil)
        let (service, transport, _) = makeService(store: store) { _ in (500, Data(), [:]) }
        await #expect(throws: SignInError.denied) {
            try await service.complete(callbackURL: URL(string: "peakstats://auth/complete?error=access_denied")!)
        }
        await #expect(throws: SignInError.failed(code: "invalid_state")) {
            try await service.complete(callbackURL: URL(string: "peakstats://auth/complete?error=invalid_state")!)
        }
        await #expect(throws: SignInError.invalidCallback) {
            try await service.complete(callbackURL: URL(string: "peakstats://game/1")!)
        }
        #expect(await transport.requests.isEmpty, "no exchange without a code")
        #expect(await service.isSignedIn() == false)
    }

    @Test func onlyHttpsAuthorizePagesAreOpened() async throws {
        let (service, _, _) = makeService(store: RecordingTokenStore(tokens: nil)) { _ in
            (200, Data(#"{"authorizeURL":"http://evil.example/login"}"#.utf8), [:])
        }
        await #expect(throws: SignInError.failed(code: "invalid_authorize_url")) {
            _ = try await service.authorizeURL()
        }
    }

    @Test func signOutClearsTokensEvenIfTheServerIsDown() async throws {
        let tokens = AuthTokens(accessToken: "a", refreshToken: "r", accessTokenExpiresAt: Fixtures.now.addingTimeInterval(900))
        let store = RecordingTokenStore(tokens: tokens)
        let (service, _, _) = makeService(store: store) { _ in throw URLError(.notConnectedToInternet) }
        #expect(await service.isSignedIn())
        await service.signOut()
        #expect(await service.isSignedIn() == false)
        #expect(await store.tokens == nil)
    }
}
