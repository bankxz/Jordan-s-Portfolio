import Foundation

/// Sends this device's APNs token to the backend so alerts, unusual-change digests and the morning briefing
/// can reach it.
public protocol PushRegistrationService: Sendable {
    func register(apnsToken: Data, sandbox: Bool, timeZone: String) async throws
}

public struct RemotePushRegistration: PushRegistrationService {
    private let client: APIClient

    public init(client: APIClient) {
        self.client = client
    }

    public func register(apnsToken: Data, sandbox: Bool, timeZone: String) async throws {
        _ = try await client.send(BackendAPI.registerDevice(
            BackendAPI.DeviceBody(apnsToken: PushPayload.hex(apnsToken), sandbox: sandbox, timeZone: timeZone)))
    }
}

/// Demo mode has no backend: registration succeeds and does nothing.
public struct DemoPushRegistration: PushRegistrationService {
    public init() {}
    public func register(apnsToken: Data, sandbox: Bool, timeZone: String) async throws {}
}

/// Reading what the server sends (`{"aps": …, "url": "peakstats://game/123"}`).
public enum PushPayload {
    /// Lowercase hex, the form APNs and the backend use.
    public static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    /// The deep link to open, only if it's one of Peak's own routes (never an arbitrary URL from a payload).
    public static func route(from userInfo: [AnyHashable: Any]) -> URL? {
        guard let raw = userInfo["url"] as? String, let url = URL(string: raw), Route(url: url) != nil else { return nil }
        return url
    }
}
