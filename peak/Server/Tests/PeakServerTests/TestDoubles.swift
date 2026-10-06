import Foundation
@testable import PeakServerCore

/// Latch for deterministic concurrency tests (no sleeps).
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// Mutable clock for tests.
final class TestClock: @unchecked Sendable {
    // Guarded by `lock`; tests advance time between awaits.
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_790_000_000)) { current = start }

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    var function: @Sendable () -> Date { { [self] in self.now } }
}

/// Programmable Roblox OAuth server.
actor FakeRobloxOAuth: RobloxOAuth {
    nonisolated let base = URL(string: "https://apis.roblox.com/oauth/v1/authorize")!
    var robloxUserID = "1516563360"
    var universes: [Int64] = [3_828_411_582]
    var refreshBehaviour: Result<Void, RobloxAPIError> = .success(())
    private(set) var exchangeCalls: [(code: String, verifier: String)] = []
    private(set) var refreshCalls: [String] = []
    private(set) var revoked: [String] = []
    private var issued = 0
    var refreshGate: Gate?

    func setRefreshBehaviour(_ behaviour: Result<Void, RobloxAPIError>) { refreshBehaviour = behaviour }
    func setRefreshGate(_ gate: Gate?) { refreshGate = gate }
    func setUniverses(_ ids: [Int64]) { universes = ids }
    func setRobloxUserID(_ id: String) { robloxUserID = id }

    nonisolated func authorizeURL(state: String, codeChallenge: String) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "state", value: state),
                                 URLQueryItem(name: "code_challenge", value: codeChallenge)]
        return components.url!
    }

    private func nextTokens() -> RobloxTokenSet {
        issued += 1
        return RobloxTokenSet(accessToken: "roblox-at-\(issued)", refreshToken: "roblox-rt-\(issued)",
                              expiresIn: 899, scope: "openid profile universe.analytics:read")
    }

    func exchange(code: String, codeVerifier: String) async throws -> RobloxTokenSet {
        exchangeCalls.append((code, codeVerifier))
        guard code == "good-code" else { throw RobloxAPIError.invalidGrant }
        return nextTokens()
    }

    func refresh(refreshToken: String) async throws -> RobloxTokenSet {
        refreshCalls.append(refreshToken)
        await refreshGate?.wait()
        if case .failure(let error) = refreshBehaviour { throw error }
        return nextTokens()
    }

    func revoke(refreshToken: String) async throws { revoked.append(refreshToken) }

    func userInfo(accessToken: String) async throws -> RobloxUserInfo {
        RobloxUserInfo(sub: robloxUserID, name: "Creator", preferredUsername: "creator")
    }

    func grantedUniverseIDs(accessToken: String) async throws -> [Int64] { universes }
}

/// Replays canned HTTP responses and records requests.
actor FakeHTTP: HTTPExecutor {
    typealias Handler = @Sendable (OutboundRequest) throws -> OutboundResponse
    private let handler: Handler
    private(set) var requests: [OutboundRequest] = []

    init(_ handler: @escaping Handler) { self.handler = handler }

    func execute(_ request: OutboundRequest) async throws -> OutboundResponse {
        requests.append(request)
        return try handler(request)
    }
}

extension OutboundRequest {
    /// Form body as a dictionary (for assertions).
    var formFields: [String: String] {
        guard let body, let text = String(data: body, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if parts.count == 2 { result[parts[0]] = parts[1] }
        }
        return result
    }
}

enum TestKeys {
    static let box = try! SecretBox(key: Data(repeating: 9, count: 32))
}
