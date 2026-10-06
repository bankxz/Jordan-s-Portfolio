import Foundation

/// One step of a funnel logged by the game with `AnalyticsService:LogFunnelStepEvent`.
public struct FunnelStep: Hashable, Codable, Sendable {
    public var name: String
    /// Players who reached this step in the period.
    public var players: Int
    /// Same, for the previous period. Lets the report point out regressions.
    public var previousPlayers: Int?

    public init(name: String, players: Int, previousPlayers: Int? = nil) {
        self.name = name
        self.players = players
        self.previousPlayers = previousPlayers
    }
}

public struct FunnelStepReport: Hashable, Codable, Sendable {
    public var from: String
    public var to: String
    /// Share of players who made it from the previous step to this one (0...1).
    public var conversion: Double
    public var playersLost: Int
    /// Conversion in the previous period, when known.
    public var previousConversion: Double?
}

public struct FunnelReport: Hashable, Codable, Sendable {
    public var transitions: [FunnelStepReport]
    /// Share of players reaching the last step from the first.
    public var overallConversion: Double?
    /// The transition to look at first. `nil` without enough players.
    public var focus: FunnelStepReport?
    public var summary: String
    /// Data problems worth knowing (counts going up between steps, tiny samples).
    public var warnings: [String]
}

/// Finds where players quit. The focus is the transition that loses the most players, adjusted so a large
/// early drop doesn't always beat a catastrophic late one: lost players weighted by how bad the conversion is.
public enum FunnelAnalyzer {
    public static let minimumPlayers = 50

    public static func analyze(_ steps: [FunnelStep]) -> FunnelReport {
        var warnings: [String] = []
        guard steps.count >= 2 else {
            return FunnelReport(transitions: [], overallConversion: nil, focus: nil,
                                summary: "A funnel needs at least two steps.", warnings: [])
        }
        var transitions: [FunnelStepReport] = []
        for (previous, step) in zip(steps, steps.dropFirst()) {
            let reached = max(0, step.players)
            let started = max(0, previous.players)
            if reached > started {
                // Roblox back-fills skipped steps, so this usually means a logging bug in the game.
                warnings.append("More players reached \u{201C}\(step.name)\u{201D} than \u{201C}\(previous.name)\u{201D}. Check that both steps are logged the same way.")
            }
            let conversion = started > 0 ? min(1, Double(reached) / Double(started)) : 0
            var previousConversion: Double?
            if let before = previous.previousPlayers, let after = step.previousPlayers, before > 0 {
                previousConversion = min(1, Double(max(0, after)) / Double(before))
            }
            transitions.append(FunnelStepReport(from: previous.name, to: step.name, conversion: conversion,
                                                playersLost: max(0, started - reached),
                                                previousConversion: previousConversion))
        }

        let first = max(0, steps[0].players)
        let overall = first > 0 ? min(1, Double(max(0, steps[steps.count - 1].players)) / Double(first)) : nil
        guard first >= minimumPlayers else {
            warnings.append("Only \(first) players entered the funnel. Wait for at least \(minimumPlayers) before drawing conclusions.")
            return FunnelReport(transitions: transitions, overallConversion: overall, focus: nil,
                                summary: "Not enough players in this funnel yet.", warnings: warnings)
        }

        let focus = transitions
            .filter { $0.playersLost > 0 }
            .max { score($0) < score($1) }
        let summary: String
        if let focus {
            var text = "The biggest drop is \u{201C}\(focus.from)\u{201D} \u{2192} \u{201C}\(focus.to)\u{201D}: "
                + "only \(InsightText.oneDecimal(focus.conversion * 100))% continue "
                + "(\(MetricFormatter.compact(focus.playersLost)) players lost)."
            if let previous = focus.previousConversion, previous - focus.conversion >= 0.05 {
                text += " It was \(InsightText.oneDecimal(previous * 100))% last period, so this step got worse."
            }
            summary = text + " Fix this step first."
        } else {
            summary = "No step loses players."
        }
        return FunnelReport(transitions: transitions, overallConversion: overall, focus: focus,
                            summary: summary, warnings: warnings)
    }

    /// Lost players, scaled up when the step's conversion is poor.
    static func score(_ transition: FunnelStepReport) -> Double {
        Double(transition.playersLost) * (1.5 - transition.conversion)
    }
}

/// A funnel the game logs, with its latest period's counts and analysis. The `/v1/games/{id}/funnels` payload.
public struct NamedFunnel: Hashable, Codable, Sendable, Identifiable {
    public var name: String
    public var steps: [FunnelStep]
    public var report: FunnelReport
    /// End of the period the counts cover (exclusive).
    public var periodEnd: Date

    public init(name: String, steps: [FunnelStep], periodEnd: Date) {
        self.name = name
        self.steps = steps
        self.report = FunnelAnalyzer.analyze(steps)
        self.periodEnd = periodEnd
    }

    public var id: String { name }
}
