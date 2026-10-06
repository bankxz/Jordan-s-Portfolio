import Foundation

/// The pieces of a development prompt. Built from Peak's measured facts, so the prompt carries real
/// numbers and clearly separates what was measured from what is only suspected.
public struct DevPrompt: Hashable, Codable, Sendable {
    public var title: String
    public var gameName: String
    public var measured: [String]
    public var possibleCauses: [String]
    public var steps: [String]
    public var filesOrSearches: [String]
    public var tests: [String]

    public init(title: String, gameName: String, measured: [String], possibleCauses: [String] = [],
                steps: [String], filesOrSearches: [String], tests: [String]) {
        self.title = title
        self.gameName = gameName
        self.measured = measured
        self.possibleCauses = possibleCauses
        self.steps = steps
        self.filesOrSearches = filesOrSearches
        self.tests = tests
    }
}

/// Turns an analytics problem into a careful prompt for Claude (Claude Code or claude.ai) working on the
/// game's Luau code. Deterministic, so it works without AI and never invents numbers.
public enum ClaudePromptGenerator {
    /// Roblox engineering rules every prompt carries.
    public static let standardConstraints = [
        "Keep the server authoritative: validate on the server and never trust values sent through RemoteEvents.",
        "Don't change prices, DataStore keys or schemas, or economy values unless this task says so.",
        "Log AnalyticsService events only after the action succeeds, not when it's attempted.",
        "Make the smallest change that fixes the root cause, and explain any trade-off.",
    ]

    public static func prompt(for digest: AlertDigest, files: [String] = []) -> DevPrompt {
        let metric = digest.headline.metric
        let measured = [digest.message] + (digest.related.isEmpty ? [] : digest.related.map(InsightText.sentence(for:)))
        let searches: [String] = switch metric {
        case .crashRate, .serverCrashes: ["Search for: memory-heavy loops, Instance creation without Destroy, while true loops"]
        case .dataStoreErrors: ["Search for: GetAsync, SetAsync, UpdateAsync, and any DataStore call without pcall and retry"]
        case .newPlayerCompletion, .d1Retention: ["Search for: tutorial, onboarding, first-join and spawn code"]
        default: ["Search for the systems changed in the latest update"]
        }
        return DevPrompt(
            title: "Investigate: \(digest.message)",
            gameName: digest.gameName,
            measured: measured,
            possibleCauses: digest.causes.map(\.evidence),
            steps: ["Find the root cause before changing code. Say what you checked.",
                    "If a possible cause below is wrong, say so and why.",
                    "Fix the root cause with the smallest change."],
            filesOrSearches: files.isEmpty ? searches : files,
            tests: tests(for: metric))
    }

    public static func prompt(for funnel: FunnelReport, gameName: String, files: [String] = []) -> DevPrompt {
        let focus = funnel.focus
        return DevPrompt(
            title: focus.map { "Reduce the drop between \u{201C}\($0.from)\u{201D} and \u{201C}\($0.to)\u{201D}" } ?? "Review the funnel",
            gameName: gameName,
            measured: [funnel.summary] + funnel.warnings,
            steps: ["Play the steps as a new player and list everything that could stop someone continuing.",
                    "Propose at most three changes, smallest first, and implement the first.",
                    "Keep the funnel step logging intact so the effect can be measured."],
            filesOrSearches: files.isEmpty ? ["Search for: LogFunnelStepEvent and the code around \(focus.map { "\u{201C}\($0.to)\u{201D}" } ?? "each step")"] : files,
            tests: ["Run the flow in Studio with a fresh profile and confirm each funnel step logs exactly once.",
                    "Test on a phone-sized viewport as well as desktop."])
    }

    public static func prompt(for report: UpdateImpactReport, gameName: String, files: [String] = []) -> DevPrompt {
        let measured = [report.summary] + report.metrics.compactMap { impact in
            guard let before = impact.before, let after = impact.after, impact.verdict != .insufficientData else { return nil }
            return "\(impact.metric.displayName): \(InsightText.value(before, metric: impact.metric)) \u{2192} \(InsightText.value(after, metric: impact.metric)) (\(impact.verdict.rawValue))"
        }
        return DevPrompt(
            title: "Find what in \(report.updateLabel) caused these changes",
            gameName: gameName,
            measured: measured,
            possibleCauses: report.caveats,
            steps: ["List what changed in \(report.updateLabel) (diff against the previous version).",
                    "Match each harmed metric to the changes most likely to affect it.",
                    "Propose fixes for the harmed metrics without undoing what improved."],
            filesOrSearches: files.isEmpty ? ["The files changed in \(report.updateLabel)"] : files,
            tests: report.metrics.filter { $0.verdict == .harmed }.flatMap { tests(for: $0.metric) }.uniqued())
    }

    public static func prompt(for cluster: ErrorCluster, gameName: String, files: [String] = []) -> DevPrompt {
        let short = cluster.signature.count > 80 ? String(cluster.signature.prefix(79)) + "\u{2026}" : cluster.signature
        let searches = cluster.location.map { ["Open \($0.script) at line \($0.line)"] }
            ?? ["Search for the text of the error: \u{201C}\(cluster.example)\u{201D}"]
        var tests = ["Reproduce the error in Studio first, then confirm it no longer appears in the Output window after the fix."]
        if cluster.sources.contains("client") {
            tests.append("Test on a phone-sized device in Studio as well as desktop: this error happens on players' devices.")
        }
        return DevPrompt(
            title: "Fix the error \u{201C}\(short)\u{201D}",
            gameName: gameName,
            measured: [cluster.summary, "Example (player names, IDs and values removed): \(cluster.example)"],
            possibleCauses: cluster.isNewInLatestVersion
                ? ["It only appears in v\(cluster.versions.last ?? 0), so a change in that update may have introduced it."] : [],
            steps: ["Find the line from the example and explain why it errors.",
                    "Fix why the value is wrong, not just the symptom: a nil check alone can hide a real bug.",
                    "Make the smallest change that fixes it."],
            filesOrSearches: files.isEmpty ? searches : files,
            tests: tests)
    }

    /// Markdown ready to paste into Claude.
    public static func render(_ prompt: DevPrompt) -> String {
        var lines = ["# \(prompt.title)", "", "## Context",
                     "Game: \(prompt.gameName) (Roblox experience, Luau).", "", "Measured by Peak:"]
        lines += prompt.measured.map { "- \($0)" }
        if prompt.possibleCauses.isEmpty == false {
            lines += ["", "Possible causes (not confirmed; check them before acting):"]
            lines += prompt.possibleCauses.map { "- \($0)" }
        }
        lines += ["", "## What to do"]
        lines += prompt.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }
        lines += ["", "## Where to look"]
        lines += prompt.filesOrSearches.map { "- \($0)" }
        lines += ["", "## Constraints"]
        lines += standardConstraints.map { "- \($0)" }
        lines += ["", "## Tests to run"]
        lines += (prompt.tests.isEmpty ? ["Describe how you verified the fix."] : prompt.tests).map { "- \($0)" }
        lines += ["", "## When you're done",
                  "Report the root cause, the change, how you verified it, and anything you couldn't verify."]
        return lines.joined(separator: "\n")
    }

    static func tests(for metric: InsightMetric) -> [String] {
        switch metric {
        case .crashRate, .serverCrashes:
            ["Run a Studio test server with several players for 10+ minutes and watch memory in the Developer Console.",
             "Repeat on a low-end mobile device emulator."]
        case .dataStoreErrors:
            ["Simulate DataStore failures (wrap calls to fail randomly) and confirm data is never lost or overwritten.",
             "Check request counts stay under the DataStore limits for the server size."]
        case .newPlayerCompletion, .d1Retention, .d7Retention:
            ["Play the first session as a new player on phone and desktop and time how long the first reward takes."]
        case .revenue, .revenuePerPlayer, .payerConversion:
            ["Buy each affected product in a Studio test session and confirm it's granted once, including after a rejoin."]
        default:
            ["Play through the affected feature in Studio and describe what you checked."]
        }
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
