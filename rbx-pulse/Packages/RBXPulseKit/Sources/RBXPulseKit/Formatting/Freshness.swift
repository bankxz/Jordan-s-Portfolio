import Foundation

/// How fresh a cached value is. Widgets and cards show this so stale data is never
/// presented as live.
public struct Freshness: Hashable, Sendable {
    public enum Level: Sendable, Hashable {
        case live
        case recent
        case stale
    }

    public let age: TimeInterval
    public let level: Level

    /// Data older than this is labelled stale.
    public static let staleAfter: TimeInterval = 30 * 60
    /// Data newer than this counts as live.
    public static let liveWithin: TimeInterval = 2 * 60

    public init(updatedAt: Date, now: Date) {
        // Clock skew between server and device can produce future timestamps; treat as live.
        let age = max(0, now.timeIntervalSince(updatedAt))
        self.age = age
        if age <= Self.liveWithin {
            level = .live
        } else if age < Self.staleAfter {
            level = .recent
        } else {
            level = .stale
        }
    }

    /// "Updated just now", "Updated 5m ago", "Updated 3h ago", "Updated 2d ago".
    public var label: String {
        let minutes = Int(age / 60)
        switch minutes {
        case ..<1: return "Updated just now"
        case ..<60: return "Updated \(minutes)m ago"
        case ..<(60 * 24): return "Updated \(minutes / 60)h ago"
        default: return "Updated \(minutes / (60 * 24))d ago"
        }
    }
}
