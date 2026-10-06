import Foundation

public enum GoalStatus: String, Hashable, Codable, Sendable {
    /// Target reached.
    case achieved
    /// No deadline, or progress is at or ahead of the linear pace.
    case onTrack
    /// Behind pace by no more than `GoalEngine.atRiskTolerance`.
    case atRisk
    /// Further behind pace than the tolerance.
    case behind
    /// Deadline passed without reaching the target.
    case missed
    /// The goal can't be evaluated (target equals start, non-finite values).
    case invalid
}

public struct GoalEvaluation: Hashable, Sendable {
    /// Fraction of the distance from start to target that has been covered, clamped to 0...1.
    public let progress: Double
    /// Fraction of the time from creation to deadline that has elapsed (0...1). `nil` without deadline.
    public let timeElapsed: Double?
    public let status: GoalStatus
    /// Projected date the target is reached at the current rate. `nil` when not computable
    /// (no history, flat or moving away from target, or already achieved).
    public let projectedCompletion: Date?
    /// Fraction of tasks done. `nil` when the goal has no tasks.
    public let taskCompletion: Double?
}

/// Pure goal maths. Works for increasing goals (reach 5K CCU) and decreasing goals
/// (cut churn to 20%), because progress is measured along the start→target direction.
public enum GoalEngine {
    /// How far behind linear pace (as a fraction of the whole goal) still counts as "at risk"
    /// rather than "behind".
    public static let atRiskTolerance = 0.10

    public static func evaluate(
        _ goal: Goal,
        currentValue: Double,
        history: [MetricPoint] = [],
        now: Date
    ) -> GoalEvaluation {
        let taskCompletion = taskCompletion(goal.tasks)
        let span = goal.targetValue - goal.startValue
        guard span != 0, span.isFinite, currentValue.isFinite else {
            return GoalEvaluation(progress: 0, timeElapsed: nil, status: .invalid,
                                  projectedCompletion: nil, taskCompletion: taskCompletion)
        }

        let progress = min(1, max(0, (currentValue - goal.startValue) / span))
        let timeElapsed = goal.deadline.map { elapsedFraction(start: goal.createdAt, end: $0, now: now) }

        let status: GoalStatus
        if progress >= 1 {
            status = .achieved
        } else if let deadline = goal.deadline, now >= deadline {
            status = .missed
        } else if let timeElapsed {
            let deficit = timeElapsed - progress
            if deficit <= 0 {
                status = .onTrack
            } else if deficit <= atRiskTolerance {
                status = .atRisk
            } else {
                status = .behind
            }
        } else {
            status = .onTrack
        }

        let projection = status == .achieved
            ? nil
            : projectedCompletion(target: goal.targetValue, span: span, history: history)

        return GoalEvaluation(progress: progress, timeElapsed: timeElapsed, status: status,
                              projectedCompletion: projection, taskCompletion: taskCompletion)
    }

    static func taskCompletion(_ tasks: [GoalTask]) -> Double? {
        guard tasks.isEmpty == false else { return nil }
        return Double(tasks.filter(\.isDone).count) / Double(tasks.count)
    }

    static func elapsedFraction(start: Date, end: Date, now: Date) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 1 }
        return min(1, max(0, now.timeIntervalSince(start) / total))
    }

    /// Least-squares linear fit over `history`, extrapolated to the target.
    static func projectedCompletion(target: Double, span: Double, history: [MetricPoint]) -> Date? {
        let points = history.sorted { $0.date < $1.date }
        guard points.count >= 2, let first = points.first, let last = points.last,
              last.date > first.date else { return nil }

        let origin = first.date.timeIntervalSinceReferenceDate
        let xs = points.map { $0.date.timeIntervalSinceReferenceDate - origin }
        let ys = points.map(\.value)
        let n = Double(points.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var covariance = 0.0
        var variance = 0.0
        for (x, y) in zip(xs, ys) {
            covariance += (x - meanX) * (y - meanY)
            variance += (x - meanX) * (x - meanX)
        }
        guard variance > 0 else { return nil }
        let slope = covariance / variance
        // Must be moving towards the target.
        guard slope != 0, slope.sign == span.sign else { return nil }

        let intercept = meanY - slope * meanX
        let secondsFromOrigin = (target - intercept) / slope
        guard secondsFromOrigin.isFinite else { return nil }
        let projected = Date(timeIntervalSinceReferenceDate: origin + secondsFromOrigin)
        // A projection in the past means the fit says we should already be there; report "now".
        return max(projected, last.date)
    }
}
