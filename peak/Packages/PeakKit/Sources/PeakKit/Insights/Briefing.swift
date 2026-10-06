import Foundation

public struct BriefingGameInput: Hashable, Sendable {
    public var game: Game
    /// Revenue in the 24 hours before the latest 24 (for the change). `nil` when unknown.
    public var revenuePrevious24h: Int64?
    public var d1Retention: Double?
    /// D1 retention averaged over the previous 7 days.
    public var d1RetentionPrevious: Double?
    public var latestUpdate: UpdateImpactReport?

    public init(game: Game, revenuePrevious24h: Int64? = nil, d1Retention: Double? = nil,
                d1RetentionPrevious: Double? = nil, latestUpdate: UpdateImpactReport? = nil) {
        self.game = game
        self.revenuePrevious24h = revenuePrevious24h
        self.d1Retention = d1Retention
        self.d1RetentionPrevious = d1RetentionPrevious
        self.latestUpdate = latestUpdate
    }
}

public struct BriefFact: Hashable, Codable, Sendable {
    public var metric: InsightMetric?
    public var text: String
    /// `nil` when the fact is neutral.
    public var isGoodNews: Bool?

    public init(metric: InsightMetric?, text: String, isGoodNews: Bool?) {
        self.metric = metric
        self.text = text
        self.isGoodNews = isGoodNews
    }
}

public struct GameBrief: Hashable, Codable, Sendable, Identifiable {
    public var gameID: Int64
    public var name: String
    public var facts: [BriefFact]
    /// One or two sentences written by AI from `facts`. `nil` with AI off.
    public var summary: String?

    public init(gameID: Int64, name: String, facts: [BriefFact], summary: String? = nil) {
        self.gameID = gameID
        self.name = name
        self.facts = facts
        self.summary = summary
    }

    public var id: Int64 { gameID }
}

public struct BriefingAction: Hashable, Codable, Sendable {
    public var title: String
    public var reason: String
    public var gameID: Int64?

    public init(title: String, reason: String, gameID: Int64?) {
        self.title = title
        self.reason = reason
        self.gameID = gameID
    }
}

public struct Briefing: Hashable, Codable, Sendable {
    public var generatedAt: Date
    public var headline: String
    public var games: [GameBrief]
    /// At most three, most important first.
    public var actions: [BriefingAction]
    /// `true` when the wording was written by AI from these facts (and passed the number check).
    public var isAIWritten: Bool

    public init(generatedAt: Date, headline: String, games: [GameBrief], actions: [BriefingAction], isAIWritten: Bool = false) {
        self.generatedAt = generatedAt
        self.headline = headline
        self.games = games
        self.actions = actions
        self.isAIWritten = isAIWritten
    }

    /// Every sentence in the briefing; the source of allowed numbers for AI wording.
    public var allText: [String] {
        [headline] + games.flatMap { $0.facts.map(\.text) } + actions.flatMap { [$0.title, $0.reason] }
    }
}

public struct GoalProgress: Hashable, Sendable {
    public var goal: Goal
    public var evaluation: GoalEvaluation

    public init(goal: Goal, evaluation: GoalEvaluation) {
        self.goal = goal
        self.evaluation = evaluation
    }
}

/// Builds the daily briefing from facts. Deterministic: this is the briefing every user gets, and the input
/// AI rewrites into friendlier prose.
public enum BriefingBuilder {
    public static let maximumActions = 3

    public static func build(
        games: [BriefingGameInput],
        digests: [AlertDigest] = [],
        goals: [GoalProgress] = [],
        campaigns: [Campaign] = [],
        now: Date
    ) -> Briefing {
        let briefs = games.map { input in
            GameBrief(gameID: input.game.id, name: input.game.name,
                      facts: facts(for: input, digests: digests.filter { $0.gameID == input.game.id },
                                   campaigns: campaigns.filter { $0.gameID == input.game.id && $0.status == .running }))
        }
        let names = Dictionary(games.map { ($0.game.id, $0.game.name) }, uniquingKeysWith: { first, _ in first })
        let actions = rankedActions(games: games, digests: digests, goals: goals, campaigns: campaigns, names: names)

        let urgent = digests.filter { !$0.headline.isGoodNews && $0.severity >= .medium }.count
        let good = digests.filter(\.headline.isGoodNews).count
        let headline: String
        if urgent > 0 {
            headline = urgent == 1 ? "1 thing needs your attention today." : "\(urgent) things need your attention today."
        } else if good > 0 {
            headline = "Good news overnight, and nothing urgent."
        } else if games.isEmpty {
            headline = "Favourite a game to get a daily briefing."
        } else {
            headline = "All quiet: no unusual changes overnight."
        }
        return Briefing(generatedAt: now, headline: headline, games: briefs, actions: actions)
    }

    static func facts(for input: BriefingGameInput, digests: [AlertDigest], campaigns: [Campaign]) -> [BriefFact] {
        var facts: [BriefFact] = []
        let stats = input.game.stats
        if let change = stats.ccuChange {
            facts.append(BriefFact(metric: .ccu,
                                   text: "CCU \(MetricFormatter.compact(stats.ccu)), \(MetricFormatter.percentChange(change)) vs yesterday.",
                                   isGoodNews: abs(change) < 0.05 ? nil : change > 0))
        } else {
            facts.append(BriefFact(metric: .ccu, text: "CCU \(MetricFormatter.compact(stats.ccu)).", isGoodNews: nil))
        }
        if let revenue = stats.robux24h {
            if let previous = input.revenuePrevious24h, let change = Stats.change(from: Double(previous), to: Double(revenue)) {
                facts.append(BriefFact(metric: .revenue,
                                       text: "Revenue \(MetricFormatter.robux(revenue)) in 24 h, \(MetricFormatter.percentChange(change)) vs the day before.",
                                       isGoodNews: abs(change) < 0.05 ? nil : change > 0))
            } else {
                facts.append(BriefFact(metric: .revenue, text: "Revenue \(MetricFormatter.robux(revenue)) in 24 h.", isGoodNews: nil))
            }
        }
        if let d1 = input.d1Retention {
            if let previous = input.d1RetentionPrevious {
                let difference = d1 - previous
                facts.append(BriefFact(metric: .d1Retention,
                                       text: "D1 retention \(InsightText.value(d1, metric: .d1Retention)) (7-day average \(InsightText.value(previous, metric: .d1Retention))).",
                                       isGoodNews: abs(difference) < 0.005 ? nil : difference > 0))
            } else {
                facts.append(BriefFact(metric: .d1Retention, text: "D1 retention \(InsightText.value(d1, metric: .d1Retention)).", isGoodNews: nil))
            }
        }
        for digest in digests {
            facts.append(BriefFact(metric: digest.headline.metric, text: digest.message, isGoodNews: digest.headline.isGoodNews))
        }
        if let update = input.latestUpdate, update.verdict != .tooEarly {
            facts.append(BriefFact(metric: nil, text: update.summary,
                                   isGoodNews: update.verdict == .neutral ? nil : update.verdict == .improved))
        }
        for campaign in campaigns {
            var text = "Ad \u{201C}\(campaign.name)\u{201D}: \(MetricFormatter.robux(campaign.spentRobux)) spent"
            if let costPerPlay = campaign.costPerPlay {
                text += ", \(InsightText.value(costPerPlay, metric: .revenuePerPlayer)) per play"
            }
            facts.append(BriefFact(metric: nil, text: text + ".", isGoodNews: nil))
        }
        return facts
    }

    static func rankedActions(games: [BriefingGameInput], digests: [AlertDigest], goals: [GoalProgress],
                              campaigns: [Campaign], names: [Int64: String]) -> [BriefingAction] {
        var candidates: [(priority: Int, action: BriefingAction)] = []

        for digest in digests where digest.headline.isGoodNews == false {
            candidates.append((100 + digest.severity.rawValue * 10,
                               BriefingAction(title: digest.suggestedAction,
                                              reason: "\(digest.gameName): \(digest.message)", gameID: digest.gameID)))
        }
        for input in games {
            guard let update = input.latestUpdate else { continue }
            switch update.verdict {
            case .harmed:
                candidates.append((90, BriefingAction(title: "Review \(update.updateLabel) on \(input.game.name)",
                                                      reason: update.summary, gameID: input.game.id)))
            case .improved:
                candidates.append((30, BriefingAction(title: "Build on what worked in \(update.updateLabel)",
                                                      reason: update.summary, gameID: input.game.id)))
            default:
                break
            }
        }
        for progress in goals {
            let status = progress.evaluation.status
            guard status == .behind || status == .atRisk else { continue }
            let done = InsightText.oneDecimal(progress.evaluation.progress * 100)
            let elapsed = progress.evaluation.timeElapsed.map { " with \(InsightText.oneDecimal($0 * 100))% of the time used" } ?? ""
            var reason = "\(done)% done\(elapsed)."
            if let next = progress.goal.tasks.first(where: { !$0.isDone }) {
                reason += " Next task: \(next.title)."
            }
            candidates.append((status == .behind ? 70 : 60,
                               BriefingAction(title: "Catch up on \u{201C}\(progress.goal.title)\u{201D}", reason: reason,
                                              gameID: progress.goal.gameID)))
        }
        for campaign in campaigns where campaign.status == .running {
            guard let used = campaign.budgetUsed, used >= 0.9 else { continue }
            candidates.append((50, BriefingAction(
                title: "Decide whether to extend \u{201C}\(campaign.name)\u{201D}",
                reason: "\(InsightText.oneDecimal(used * 100))% of its budget is spent.", gameID: campaign.gameID)))
        }
        for digest in digests where digest.headline.isGoodNews {
            candidates.append((40, BriefingAction(title: "Find what drove the jump on \(digest.gameName)",
                                                  reason: digest.message, gameID: digest.gameID)))
        }
        if candidates.isEmpty, let top = games.max(by: { $0.game.stats.ccu < $1.game.stats.ccu }) {
            candidates.append((0, BriefingAction(title: "Spend today on the next update for \(top.game.name)",
                                                 reason: "Nothing urgent. It's your biggest game right now.",
                                                 gameID: top.game.id)))
        }

        var seen = Set<String>()
        return candidates
            .sorted { $0.priority > $1.priority }
            .map(\.action)
            .filter { seen.insert($0.title).inserted }
            .prefix(maximumActions)
            .map { $0 }
    }
}
