import Crypto
import Foundation

public struct PushMessage: Sendable, Hashable {
    public var title: String
    public var body: String
    /// Deep link opened when the notification is tapped (`Route` URL).
    public var url: URL
    /// Groups notifications per game in Notification Center.
    public var threadID: String
}

public enum PushResult: Sendable, Hashable {
    case delivered
    /// The token is no longer valid (app removed or token rotated): delete it.
    case unregistered
    case failed(status: Int)
}

public protocol PushSender: Sendable {
    func send(_ message: PushMessage, to device: DeviceRecord) async -> PushResult
}

/// Pushes disabled (no APNs key configured).
public struct DisabledPushSender: PushSender {
    public init() {}
    public func send(_ message: PushMessage, to device: DeviceRecord) async -> PushResult { .failed(status: 0) }
}

/// APNs over HTTP/2 with token-based (ES256 JWT) authentication.
public actor APNsSender: PushSender {
    private let config: ServerConfig.APNs
    private let key: P256.Signing.PrivateKey
    private let http: any HTTPExecutor
    private let now: @Sendable () -> Date
    private var cachedToken: (jwt: String, issuedAt: Date)?

    public init(config: ServerConfig.APNs, http: any HTTPExecutor, now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.config = config
        self.key = try P256.Signing.PrivateKey(pemRepresentation: config.privateKeyPEM)
        self.http = http
        self.now = now
    }

    /// Apple rejects tokens older than an hour and throttles refreshing more than every 20 minutes.
    func providerToken() throws -> String {
        let current = now()
        if let cachedToken, current.timeIntervalSince(cachedToken.issuedAt) < 50 * 60 {
            return cachedToken.jwt
        }
        let header = #"{"alg":"ES256","kid":"\#(config.keyID)"}"#
        let claims = #"{"iss":"\#(config.teamID)","iat":\#(Int(current.timeIntervalSince1970))}"#
        let signingInput = Data(header.utf8).base64URLEncodedString() + "." + Data(claims.utf8).base64URLEncodedString()
        let signature = try key.signature(for: Data(signingInput.utf8))
        let jwt = signingInput + "." + signature.rawRepresentation.base64URLEncodedString()
        cachedToken = (jwt, current)
        return jwt
    }

    public func send(_ message: PushMessage, to device: DeviceRecord) async -> PushResult {
        guard let jwt = try? providerToken() else { return .failed(status: 0) }
        let host = device.sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com"
        let payload: [String: Any] = [
            "aps": ["alert": ["title": message.title, "body": message.body], "sound": "default", "thread-id": message.threadID],
            "url": message.url.absoluteString,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let url = URL(string: "https://\(host)/3/device/\(device.token)") else { return .failed(status: 0) }
        let request = OutboundRequest(method: "POST", url: url, headers: [
            "authorization": "bearer \(jwt)",
            "apns-topic": config.bundleID,
            "apns-push-type": "alert",
            "apns-priority": "10",
            "content-type": "application/json",
        ], body: body)
        guard let response = try? await http.execute(request) else { return .failed(status: 0) }
        switch response.status {
        case 200: return .delivered
        case 410: return .unregistered
        case 400 where String(data: response.body, encoding: .utf8)?.contains("BadDeviceToken") == true: return .unregistered
        default: return .failed(status: response.status)
        }
    }
}
