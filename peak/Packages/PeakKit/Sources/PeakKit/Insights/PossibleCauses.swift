import Foundation

/// Something that happened around a game and might explain a change: an update, a campaign change, a price
/// change. Timeline events come from Roblox APIs (or imports) and are stored by the backend.
public struct TimelineEvent: Hashable, Codable, Sendable {
    public enum Kind: String, Hashable, Codable, Sendable {
        /// A new place version went live (exact version when known).
        case update
        case campaignStarted
        case campaignStopped
        case campaignBudgetChanged
        case priceChanged
        case thumbnailChanged
        /// Crashes, DataStore errors or frame-rate problems detected for the game.
        case serverProblem
        /// A Roblox-wide incident. `gameID` is nil.
        case robloxOutage
        /// A school break, holiday or event window the creator or server calendar knows about.
        case calendar
    }

    public var kind: Kind
    /// `nil` for platform-wide events (outages, calendar).
    public var gameID: Int64?
    public var date: Date
    /// When the event stops applying (end of an outage or holiday). `nil` for instant events.
    public var endDate: Date?
    /// Short human label, e.g. "v128", "VIP pass 399 → 499 R$", "Spring launch".
    public var detail: String

    public init(kind: Kind, gameID: Int64?, date: Date, endDate: Date? = nil, detail: String) {
        self.kind = kind
        self.gameID = gameID
        self.date = date
        self.endDate = endDate
        self.detail = detail
    }
}

/// A *possible* explanation. There is deliberately no "confirmed" level: correlation in time is evidence,
/// not proof, and the UI must always say "Possible cause".
public struct PossibleCause: Hashable, Codable, Sendable {
    public enum Likelihood: String, Hashable, Codable, Sendable, Comparable {
        case worthChecking
        case plausible

        public static func < (lhs: Likelihood, rhs: Likelihood) -> Bool {
            lhs == .worthChecking && rhs == .plausible
        }
    }

    public var kind: TimelineEvent.Kind?
    /// `true` for calendar effects derived from the date itself (weekend) rather than an event.
    public var isCalendarEffect: Bool
    public var likelihood: Likelihood
    /// One sentence of evidence, e.g. "Update v128 went live 2 h before the change."
    public var evidence: String
    public var eventDate: Date?

    public init(kind: TimelineEvent.Kind?, isCalendarEffect: Bool = false, likelihood: Likelihood,
                evidence: String, eventDate: Date?) {
        self.kind = kind
        self.isCalendarEffect = isCalendarEffect
        self.likelihood = likelihood
        self.evidence = evidence
        self.eventDate = eventDate
    }
}

/// Links an anomaly to things that happened shortly before (or during) it.
public enum CauseCorrelator {
    /// How long before the anomaly an instant event can still plausibly explain it.
    public static func lookback(for kind: TimelineEvent.Kind) -> TimeInterval {
        switch kind {
        case .update, .priceChanged, .thumbnailChanged: 24 * 3_600
        case .campaignStarted, .campaignStopped, .campaignBudgetChanged: 12 * 3_600
        case .serverProblem: 2 * 3_600
        case .robloxOutage, .calendar: 3_600
        }
    }

    public static func causes(
        for anomaly: Anomaly,
        events: [TimelineEvent],
        calendar: Calendar = .utc,
        limit: Int = 3
    ) -> [PossibleCause] {
        var found: [(cause: PossibleCause, distance: TimeInterval)] = []
        for event in events where event.gameID == nil || event.gameID == anomaly.gameID {
            guard relevant(event.kind, to: anomaly) else { continue }
            let end = event.endDate ?? event.date
            let isOngoing = event.date <= anomaly.detectedAt && end >= anomaly.detectedAt
            let gap = anomaly.detectedAt.timeIntervalSince(end)
            guard isOngoing || (gap >= 0 && gap <= lookback(for: event.kind)) else { continue }
            let distance = isOngoing ? 0 : gap
            // Close in time and a game-specific change: plausible. Otherwise worth checking.
            let likelihood: PossibleCause.Likelihood =
                (distance <= 6 * 3_600 && event.gameID != nil) || isOngoing ? .plausible : .worthChecking
            found.append((PossibleCause(kind: event.kind, likelihood: likelihood,
                                        evidence: evidence(for: event, gap: distance, ongoing: isOngoing),
                                        eventDate: event.date), distance))
        }

        // Same-time-last-week baselines already control for weekends. A daily baseline doesn't.
        if anomaly.baseline == .sameTimePreviousDays, anomaly.metric.unit != .fraction {
            let weekday = calendar.component(.weekday, from: anomaly.detectedAt)
            if weekday == 1 || weekday == 7 || weekday == 2 {
                let day = weekday == 2 ? "Monday after a weekend" : "a weekend"
                found.append((PossibleCause(kind: nil, isCalendarEffect: true, likelihood: .worthChecking,
                                            evidence: "It's \(day), and there isn't enough history to compare with the same day last week.",
                                            eventDate: nil), .infinity))
            }
        }

        return found
            .sorted { lhs, rhs in
                if lhs.cause.likelihood != rhs.cause.likelihood { return lhs.cause.likelihood > rhs.cause.likelihood }
                return lhs.distance < rhs.distance
            }
            .prefix(max(0, limit))
            .map(\.cause)
    }

    /// Filters out explanations that don't fit the direction of the change.
    static func relevant(_ kind: TimelineEvent.Kind, to anomaly: Anomaly) -> Bool {
        switch kind {
        case .campaignStarted:
            // A campaign starting explains more players or spend, not a drop.
            return anomaly.direction == .spike || anomaly.metric.higherIsBetter == false
        case .campaignStopped:
            return anomaly.direction == .drop
        case .serverProblem, .robloxOutage:
            // Problems explain bad news only.
            return anomaly.isGoodNews == false
        default:
            return true
        }
    }
}

public extension Calendar {
    /// Gregorian calendar in UTC: the insight engines' default, so results don't depend on the server's locale.
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}
