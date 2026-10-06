import Foundation
import Logging
import PeakKit

/// Sends the daily briefing as a notification at 8:00 in the user's time zone (from their most recently
/// registered device). Once per user per local day, claimed atomically, and only for users with favourite games.
/// AI wording is used when the user opted in (`AIService.narrate` handles consent and budget).
public struct BriefingNotifier: Sendable {
    public static let localHour = 8

    let store: any Store
    let insights: InsightBuilder
    let ai: AIService
    let push: any PushSender
    let now: @Sendable () -> Date

    public init(store: any Store, insights: InsightBuilder, ai: AIService, push: any PushSender,
                now: @escaping @Sendable () -> Date) {
        self.store = store
        self.insights = insights
        self.ai = ai
        self.push = push
        self.now = now
    }

    @discardableResult
    public func tick(logger: Logger) async throws -> Int {
        let current = now()
        var sent = 0
        for grant in try await store.allGrants() {
            try Task.checkCancellation()
            let devices = try await store.devices(userID: grant.userID)
            guard let zoneID = devices.max(by: { $0.updatedAt < $1.updatedAt })?.timeZone,
                  let zone = TimeZone(identifier: zoneID) else { continue }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            guard calendar.component(.hour, from: current) == Self.localHour else { continue }

            let day = calendar.dateComponents([.year, .month, .day], from: current)
            let key = "briefing-\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)"
            do {
                let briefing = try await insights.briefing(userID: grant.userID)
                guard briefing.games.isEmpty == false else { continue }
                guard try await store.claimDigestPush(userID: grant.userID, key: key, at: current, cooldown: 20 * 3_600) else { continue }
                let message = Self.message(for: await ai.narrate(briefing, userID: grant.userID))
                for device in devices where await push.send(message, to: device) == .unregistered {
                    try await store.deleteDevice(token: device.token)
                }
                sent += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.warning("briefing push failed", metadata: ["user": "\(grant.userID)", "error": "\(error)"])
            }
        }
        if sent > 0 { logger.info("briefings pushed", metadata: ["count": "\(sent)"]) }
        return sent
    }

    static func message(for briefing: Briefing) -> PushMessage {
        var body = briefing.headline
        if let first = briefing.actions.first { body += " First: " + first.title }
        if body.count > 220 { body = String(body.prefix(219)) + "…" }
        return PushMessage(title: "Today's briefing", body: body, url: Route.home.url, threadID: "briefing")
    }
}
