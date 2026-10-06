import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PeakKit

/// A latch that holds async callers until opened. Lets concurrency tests create real overlap
/// deterministically instead of relying on sleeps.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// Counts refreshes and issues sequentially numbered tokens.
actor FakeRefresher: TokenRefresher {
    enum Behaviour: Sendable {
        case succeed
        case reject
        case fail(URLError.Code)
    }

    private(set) var callCount = 0
    private(set) var receivedRefreshTokens: [String] = []
    private let gate: Gate?
    private var behaviour: Behaviour
    private let expiresAt: Date

    init(behaviour: Behaviour = .succeed, gate: Gate? = nil, expiresAt: Date) {
        self.behaviour = behaviour
        self.gate = gate
        self.expiresAt = expiresAt
    }

    func setBehaviour(_ behaviour: Behaviour) {
        self.behaviour = behaviour
    }

    func refresh(using refreshToken: String) async throws -> AuthTokens {
        callCount += 1
        receivedRefreshTokens.append(refreshToken)
        let number = callCount
        await gate?.wait()
        switch behaviour {
        case .succeed:
            return AuthTokens(accessToken: "access-\(number)", refreshToken: "refresh-\(number)",
                              accessTokenExpiresAt: expiresAt)
        case .reject:
            throw RefreshTokenRejected()
        case .fail(let code):
            throw URLError(code)
        }
    }
}

/// Records saves and can be told to fail.
actor RecordingTokenStore: TokenStore {
    private(set) var tokens: AuthTokens?
    private(set) var saveCount = 0
    var failSaves = false

    init(tokens: AuthTokens?) {
        self.tokens = tokens
    }

    func setFailSaves(_ value: Bool) { failSaves = value }

    func load() async throws -> AuthTokens? { tokens }

    func save(_ tokens: AuthTokens) async throws {
        saveCount += 1
        if failSaves { throw URLError(.cannotWriteToFile) }
        self.tokens = tokens
    }

    func clear() async throws { tokens = nil }
}

/// Programmable HTTP transport.
actor FakeTransport: HTTPTransport {
    typealias Handler = @Sendable (URLRequest) async throws -> (Int, Data, [String: String])

    private let handler: Handler
    private(set) var requests: [URLRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, data, headers) = try await handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        return (data, response)
    }
}

enum Fixtures {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let baseURL = URL(string: "https://api.example.test/")!

    static func tokens(_ suffix: String, expiresIn: TimeInterval) -> AuthTokens {
        AuthTokens(accessToken: "access-\(suffix)", refreshToken: "refresh-\(suffix)",
                   accessTokenExpiresAt: now.addingTimeInterval(expiresIn))
    }
}
