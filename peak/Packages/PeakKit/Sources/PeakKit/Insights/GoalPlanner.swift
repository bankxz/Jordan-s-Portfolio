import Foundation

public struct WeeklyTarget: Hashable, Codable, Sendable {
    public var week: Int
    public var endDate: Date
    public var target: Double
}

public struct GoalPlan: Hashable, Codable, Sendable {
    public enum Ambition: String, Hashable, Codable, Sendable {
        case realistic
        case ambitious
        case veryAmbitious
    }

    public var metric: InsightMetric
    public var startValue: Double
    public var targetValue: Double
    public var startDate: Date
    public var deadline: Date
    public var weeks: [WeeklyTarget]
    /// Compound growth needed per week (0.12 == +12%/week). `nil` for linear plans (from or to zero).
    public var weeklyGrowth: Double?
    public var ambition: Ambition
    public var tasks: [String]
    public var summary: String

    /// The planned value at `date`, interpolated between weekly targets.
    public func expectedValue(at date: Date) -> Double {
        var previous = (date: startDate, value: startValue)
        for week in weeks {
            if date <= week.endDate {
                let span = week.endDate.timeIntervalSince(previous.date)
                guard span > 0 else { return week.target }
                let fraction = max(0, date.timeIntervalSince(previous.date)) / span
                return previous.value + (week.target - previous.value) * fraction
            }
            previous = (week.endDate, week.target)
        }
        return targetValue
    }
}

public struct GoalPlanCheck: Hashable, Codable, Sendable {
    public enum Status: String, Hashable, Codable, Sendable {
        case ahead
        case onTrack
        case behind
        case achieved
        case deadlinePassed
    }

    public var status: Status
    public var latestValue: Double
    public var expectedValue: Double
    /// A fresh plan from today's value when the old one no longer fits. `nil` when on track or ahead.
    public var revisedPlan: GoalPlan?
    public var summary: String
}

/// "Reach 1,000 CCU within 30 days" → weekly targets, tasks, and a revised plan as results come in.
/// Growth compounds (audiences grow multiplicatively), falling back to linear steps from or to zero.
public enum GoalPlanner {
    /// Within this fraction of the planned value counts as on track.
    public static let tolerance = 0.05

    public static func plan(metric: InsightMetric, current: Double, target: Double, start: Date,
                            deadline: Date) -> GoalPlan {
        let totalDays = max(1, Int((deadline.timeIntervalSince(start) / 86_400).rounded(.up)))
        let weekCount = max(1, Int((Double(totalDays) / 7).rounded(.up)))
        let increasing = target >= current
        let compounding = current > 0 && target > 0
        let weeklyGrowth: Double? = compounding ? pow(target / current, 1 / Double(weekCount)) - 1 : nil

        var weeks: [WeeklyTarget] = []
        for week in 1...weekCount {
            let endDate = week == weekCount ? deadline : min(deadline, start.addingTimeInterval(Double(week) * 7 * 86_400))
            let value: Double
            if week == weekCount {
                value = target
            } else if let weeklyGrowth {
                value = current * pow(1 + weeklyGrowth, Double(week))
            } else {
                value = current + (target - current) * Double(week) / Double(weekCount)
            }
            weeks.append(WeeklyTarget(week: week, endDate: endDate, target: rounded(value, metric: metric)))
        }

        let pace = abs(weeklyGrowth ?? ((target - current) / max(abs(current), metric.minimumVolume) / Double(weekCount)))
        let ambition: GoalPlan.Ambition = switch pace {
        case ...0.10: .realistic
        case ...0.25: .ambitious
        default: .veryAmbitious
        }

        let targetText = InsightText.value(target, metric: metric)
        let currentText = InsightText.value(current, metric: metric)
        var summary = "\(metric.displayName) \(currentText) \u{2192} \(targetText) in \(weekCount) week\(weekCount == 1 ? "" : "s")"
        if let weeklyGrowth {
            summary += ": about \(InsightText.magnitude(weeklyGrowth)) \(increasing ? "growth" : "decline") per week."
        } else {
            summary += "."
        }
        switch ambition {
        case .realistic: summary += " That's a realistic pace."
        case .ambitious: summary += " That's ambitious; it needs steady updates and promotion."
        case .veryAmbitious: summary += " That's very ambitious. Consider a later deadline or a smaller first milestone."
        }

        return GoalPlan(metric: metric, startValue: current, targetValue: target, startDate: start, deadline: deadline,
                        weeks: weeks, weeklyGrowth: weeklyGrowth, ambition: ambition,
                        tasks: tasks(for: metric, increasing: increasing), summary: summary)
    }

    /// Compares progress with the plan, and re-plans from today when behind.
    public static func check(_ plan: GoalPlan, latestValue: Double, now: Date) -> GoalPlanCheck {
        let increasing = plan.targetValue >= plan.startValue
        let expected = plan.expectedValue(at: now)
        let reached = increasing ? latestValue >= plan.targetValue : latestValue <= plan.targetValue
        if reached {
            return GoalPlanCheck(status: .achieved, latestValue: latestValue, expectedValue: expected, revisedPlan: nil,
                                 summary: "Goal reached: \(InsightText.value(latestValue, metric: plan.metric)).")
        }
        if now >= plan.deadline {
            return GoalPlanCheck(status: .deadlinePassed, latestValue: latestValue, expectedValue: expected, revisedPlan: nil,
                                 summary: "The deadline passed at \(InsightText.value(latestValue, metric: plan.metric)) of \(InsightText.value(plan.targetValue, metric: plan.metric)).")
        }

        let gap = increasing ? latestValue - expected : expected - latestValue
        let slack = max(abs(expected) * tolerance, plan.metric.minimumVolume / 10)
        let latestText = InsightText.value(latestValue, metric: plan.metric)
        let expectedText = InsightText.value(expected, metric: plan.metric)
        if gap > slack {
            return GoalPlanCheck(status: .ahead, latestValue: latestValue, expectedValue: expected, revisedPlan: nil,
                                 summary: "Ahead of plan: \(latestText) vs \(expectedText) planned for today.")
        }
        if gap >= -slack {
            return GoalPlanCheck(status: .onTrack, latestValue: latestValue, expectedValue: expected, revisedPlan: nil,
                                 summary: "On track: \(latestText) vs \(expectedText) planned for today.")
        }
        let revised = Self.plan(metric: plan.metric, current: latestValue, target: plan.targetValue, start: now,
                           deadline: plan.deadline)
        return GoalPlanCheck(status: .behind, latestValue: latestValue, expectedValue: expected, revisedPlan: revised,
                             summary: "Behind plan: \(latestText) vs \(expectedText) planned for today. Revised plan: \(revised.summary)")
    }

    static func rounded(_ value: Double, metric: InsightMetric) -> Double {
        switch metric.unit {
        case .count, .robux: value.rounded()
        case .fraction: (value * 1_000).rounded() / 1_000
        case .minutes: (value * 10).rounded() / 10
        }
    }

    /// Starting tasks by metric. AI can tailor them; these work without it.
    static func tasks(for metric: InsightMetric, increasing: Bool) -> [String] {
        switch metric {
        case .ccu, .visits:
            return ["Find and fix the biggest first-session funnel drop",
                    "Ship one content update a week and read its update report",
                    "Test a new thumbnail and keep the winner",
                    "Give players a reason to come back daily (streak or timed event)",
                    "Run a small ad test and compare cost per retained player"]
        case .revenue, .revenuePerPlayer, .payerConversion:
            return ["Review which items earn the most and which never sell",
                    "Offer a low-price first purchase",
                    "Test one price change at a time and compare a full week",
                    "Make paid items visible at the moment players want them"]
        case .d1Retention, .d7Retention, .newPlayerCompletion, .sessionLength:
            return ["Shorten the time to the first reward",
                    "Fix the biggest first-session funnel drop",
                    "Add a reason to return tomorrow (daily reward or event)",
                    "Check the mobile experience separately from desktop"]
        case .crashRate, .serverCrashes, .dataStoreErrors:
            return ["Group the errors by message and fix the most frequent first",
                    "Check memory use on low-end mobile devices",
                    "Add retries with backoff around DataStore calls",
                    "Compare error rates between the last two versions"]
        case .favourites:
            return ["Ask players to favourite at a high moment (after a win or unlock)",
                    "Ship regular updates so favouriters get notified",
                    "Test a new thumbnail and keep the winner"]
        }
    }
}
