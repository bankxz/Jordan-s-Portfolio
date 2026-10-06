import Foundation

/// The change of the headline metric within one slice of players, e.g. Mobile -31%.
public struct DimensionChange: Hashable, Codable, Sendable {
    public var dimension: String
    public var change: Double

    public init(dimension: String, change: Double) {
        self.dimension = dimension
        self.change = change
    }
}

/// One notification instead of many: the headline change, what moved with it, where it was concentrated,
/// possible causes and one suggested next step.
public struct AlertDigest: Hashable, Codable, Sendable, Identifiable {
    public var gameID: Int64
    public var gameName: String
    public var headline: Anomaly
    public var related: [Anomaly]
    public var concentratedIn: DimensionChange?
    public var causes: [PossibleCause]
    public var message: String
    public var suggestedAction: String

    public var id: String { headline.id }
    public var severity: Anomaly.Severity { ([headline] + related).map(\.severity).max() ?? headline.severity }
}

public enum AlertPrioritizer {
    /// Anomalies of the same game closer together than this are one incident.
    public static let incidentWindow: TimeInterval = 2 * 3_600

    public static func digests(
        anomalies: [Anomaly],
        gameNames: [Int64: String],
        breakdowns: [String: [DimensionChange]] = [:],
        events: [TimelineEvent] = [],
        calendar: Calendar = .utc
    ) -> [AlertDigest] {
        var digests: [AlertDigest] = []
        let byGame = Dictionary(grouping: anomalies, by: \.gameID)
        for (gameID, gameAnomalies) in byGame {
            for incident in incidents(gameAnomalies.sorted { $0.detectedAt < $1.detectedAt }) {
                let ordered = incident.sorted { lhs, rhs in
                    if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
                    return lhs.metric.priority < rhs.metric.priority
                }
                let headline = ordered[0]
                let related = Array(ordered.dropFirst())
                let concentrated = concentration(for: headline, breakdown: breakdowns[headline.id] ?? [])
                let causes = CauseCorrelator.causes(for: headline, events: events, calendar: calendar)
                digests.append(AlertDigest(
                    gameID: gameID,
                    gameName: gameNames[gameID] ?? "Game \(gameID)",
                    headline: headline,
                    related: related,
                    concentratedIn: concentrated,
                    causes: causes,
                    message: message(headline: headline, related: related, concentrated: concentrated),
                    suggestedAction: action(headline: headline, related: related, concentrated: concentrated, causes: causes)
                ))
            }
        }
        return digests.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            if lhs.headline.isGoodNews != rhs.headline.isGoodNews { return lhs.headline.isGoodNews == false }
            return lhs.headline.detectedAt > rhs.headline.detectedAt
        }
    }

    /// Splits a game's anomalies (sorted by date) into incidents: runs with gaps shorter than the window.
    static func incidents(_ sorted: [Anomaly]) -> [[Anomaly]] {
        var result: [[Anomaly]] = []
        for anomaly in sorted {
            if let last = result.last?.last, anomaly.detectedAt.timeIntervalSince(last.detectedAt) <= incidentWindow {
                result[result.count - 1].append(anomaly)
            } else {
                result.append([anomaly])
            }
        }
        return result
    }

    /// The slice that moved most in the headline's direction, if it moved clearly more than the whole.
    static func concentration(for headline: Anomaly, breakdown: [DimensionChange]) -> DimensionChange? {
        guard let overall = headline.change else { return nil }
        let sameDirection = breakdown.filter { $0.change.isFinite && ($0.change < 0) == (overall < 0) }
        guard let strongest = sameDirection.max(by: { abs($0.change) < abs($1.change) }),
              abs(strongest.change) >= abs(overall) * 1.2 else { return nil }
        return strongest
    }

    static func message(headline: Anomaly, related: [Anomaly], concentrated: DimensionChange?) -> String {
        var sentences: [String] = []
        if let change = headline.change {
            sentences.append("\(headline.metric.displayName) \(InsightText.verb(change)) \(InsightText.magnitude(change)).")
        } else {
            sentences.append(InsightText.sentence(for: headline))
        }
        if let concentrated {
            sentences.append("The largest change was on \(concentrated.dimension) (\(MetricFormatter.percentChange(concentrated.change))).")
        }
        let moved = related.compactMap { anomaly -> String? in
            guard let change = anomaly.change else { return "\(anomaly.metric.displayName) jumped from almost nothing" }
            return "\(anomaly.metric.displayName) \(InsightText.verb(change)) \(InsightText.magnitude(change))"
        }
        if moved.isEmpty == false {
            sentences.append("Also: " + moved.prefix(3).joined(separator: ", ") + ".")
        }
        return sentences.joined(separator: " ")
    }

    static func action(headline: Anomaly, related: [Anomaly], concentrated: DimensionChange?,
                       causes: [PossibleCause]) -> String {
        let all = [headline] + related
        if all.contains(where: { [.crashRate, .serverCrashes, .dataStoreErrors].contains($0.metric) && !$0.isGoodNews }) {
            return "Check the error logs for the latest version before changing anything else."
        }
        let onboardingFell = all.contains { $0.metric == .newPlayerCompletion && $0.direction == .drop }
        let mobile = concentrated.map { ["mobile", "phone", "tablet", "ios", "android"].contains(where: $0.dimension.lowercased().contains) } ?? false
        if onboardingFell && mobile {
            return "Check the mobile tutorial before changing your ads."
        }
        if onboardingFell {
            return "Check the first-session flow (tutorial) before changing your ads."
        }
        if headline.isGoodNews {
            return "Find what drove this and do more of it."
        }
        switch causes.first?.kind {
        case .robloxOutage:
            return "This looks Roblox-wide. Wait for it to recover before changing anything."
        case .campaignStopped:
            return "This may just be a campaign ending, not a problem with the game."
        case .update:
            return "Compare against the previous version. If it keeps falling, consider rolling back."
        case .priceChanged:
            return "Watch purchases closely; the price change may be the cause."
        default:
            return "Watch the next hour. If it doesn't recover, check what changed recently."
        }
    }
}
