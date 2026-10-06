import Foundation
import Logging
import PeakKit

/// Smart alert prioritisation as notifications: one push per incident (headline change, where it was
/// concentrated, what moved with it and a next step) instead of one per metric. Only bad news of medium
/// severity or higher, detected recently, and at most once per game, metric and direction per cooldown.
public struct DigestNotifier: Sendable {
    public static let cooldown: TimeInterval = 6 * 3_600
    /// Only incidents this fresh are pushed; older ones are already visible in the app.
    public static let freshness: TimeInterval = 30 * 60

    let store: any Store
    let insights: InsightBuilder
    let push: any PushSender
    let now: @Sendable () -> Date

    public init(store: any Store, insights: InsightBuilder, push: any PushSender, now: @escaping @Sendable () -> Date) {
        self.store = store
        self.insights = insights
        self.push = push
        self.now = now
    }

    /// Returns the number of digests pushed.
    @discardableResult
    public func tick(logger: Logger) async throws -> Int {
        let current = now()
        var pushed = 0
        for grant in try await store.allGrants() {
            try Task.checkCancellation()
            let devices = try await store.devices(userID: grant.userID)
            guard devices.isEmpty == false else { continue }
            let digests: [AlertDigest]
            do {
                digests = try await insights.digests(userID: grant.userID)
            } catch {
                logger.warning("digests failed", metadata: ["user": "\(grant.userID)", "error": "\(error)"])
                continue
            }
            for digest in digests where Self.shouldPush(digest, now: current) {
                let key = "\(digest.gameID)-\(digest.headline.metric.rawValue)-\(digest.headline.direction.rawValue)"
                guard try await store.claimDigestPush(userID: grant.userID, key: key, at: current, cooldown: Self.cooldown) else { continue }
                let message = Self.message(for: digest)
                for device in devices where await push.send(message, to: device) == .unregistered {
                    try await store.deleteDevice(token: device.token)
                }
                pushed += 1
            }
        }
        if pushed > 0 { logger.info("digests pushed", metadata: ["count": "\(pushed)"]) }
        return pushed
    }

    static func shouldPush(_ digest: AlertDigest, now: Date) -> Bool {
        digest.headline.isGoodNews == false && digest.severity >= .medium
            && now.timeIntervalSince(digest.headline.detectedAt) <= freshness
    }

    static func message(for digest: AlertDigest) -> PushMessage {
        var body = digest.message + " " + digest.suggestedAction
        if body.count > 220 { body = String(body.prefix(219)) + "…" }
        return PushMessage(title: digest.gameName, body: body, url: Route.game(id: digest.gameID).url,
                           threadID: "game-\(digest.gameID)")
    }
}
