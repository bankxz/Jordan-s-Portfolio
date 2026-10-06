import Foundation

/// Deterministic wording for insights. These sentences are what every user sees with AI off, and the
/// numbers in them are the only numbers AI wording may use (see `NumberGrounding`).
public enum InsightText {
    /// Formats a metric value in its unit: "4.8K", "R$182.4K", "18.2%", "12.5 min".
    public static func value(_ value: Double, metric: InsightMetric) -> String {
        switch metric.unit {
        case .count:
            return MetricFormatter.compact(value)
        case .robux:
            // Small per-player amounts keep one decimal ("R$2.4"); totals use compact form.
            if abs(value) < 100, value != value.rounded() {
                return (value < 0 ? "-R$" : "R$") + oneDecimal(abs(value))
            }
            return MetricFormatter.robux(Int64(value.rounded()))
        case .fraction:
            return oneDecimal(value * 100) + "%"
        case .minutes:
            return oneDecimal(value) + " min"
        }
    }

    /// Unsigned percentage of a fractional change: -0.243 → "24.3%".
    public static func magnitude(_ change: Double) -> String {
        oneDecimal(abs(change) * 100) + "%"
    }

    /// "rose" / "fell" for a change.
    public static func verb(_ change: Double) -> String { change < 0 ? "fell" : "rose" }

    /// "45 min", "2 h", "1 day", "3 days".
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((max(0, seconds) / 60).rounded())
        switch minutes {
        case ..<60: return "\(max(1, minutes)) min"
        case ..<(48 * 60): return "\(Int((Double(minutes) / 60).rounded())) h"
        default:
            let days = Int((Double(minutes) / 1_440).rounded())
            return days == 1 ? "1 day" : "\(days) days"
        }
    }

    /// One decimal, dropped when it's .0: 18.25 → "18.3", 24.0 → "24".
    public static func oneDecimal(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int64(rounded)) }
        return String(format: "%.1f", rounded)
    }

    /// "CCU fell 24.3% below normal (3.6K vs 4.8K expected)."
    public static func sentence(for anomaly: Anomaly) -> String {
        let name = anomaly.metric.displayName
        let actual = value(anomaly.actual, metric: anomaly.metric)
        let expected = value(anomaly.expected, metric: anomaly.metric)
        guard let change = anomaly.change else {
            return "\(name) jumped to \(actual) from almost nothing."
        }
        let relation = change < 0 ? "below" : "above"
        return "\(name) is \(magnitude(change)) \(relation) normal (\(actual) vs \(expected) expected)."
    }
}

extension CauseCorrelator {
    static func evidence(for event: TimelineEvent, gap: TimeInterval, ongoing: Bool) -> String {
        let isSpan = event.endDate != nil
        let timing: String
        if isSpan {
            timing = ongoing ? "was ongoing when the change happened" : "ended \(InsightText.duration(gap)) before the change"
        } else {
            timing = gap < 60 ? "at the same time as the change" : "\(InsightText.duration(gap)) before the change"
        }
        switch event.kind {
        case .update: return "Update \(event.detail) went live \(timing)."
        case .campaignStarted: return "Campaign \u{201C}\(event.detail)\u{201D} started \(timing)."
        case .campaignStopped: return "Campaign \u{201C}\(event.detail)\u{201D} stopped \(timing)."
        case .campaignBudgetChanged: return "The budget of campaign \u{201C}\(event.detail)\u{201D} changed \(timing)."
        case .priceChanged: return "A price changed (\(event.detail)) \(timing)."
        case .thumbnailChanged: return "The thumbnail changed (\(event.detail)) \(timing)."
        case .serverProblem: return isSpan ? "A server problem (\(event.detail)) \(timing)." : "A server problem (\(event.detail)) started \(timing)."
        case .robloxOutage: return isSpan ? "A Roblox-wide incident (\(event.detail)) \(timing)." : "A Roblox-wide incident (\(event.detail)) started \(timing)."
        case .calendar: return isSpan ? "\(event.detail) \(timing)." : "\(event.detail) started \(timing)."
        }
    }
}
