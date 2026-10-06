import Foundation
import PeakKit

/// The tools behind "Ask your analytics". All read-only and scoped to one user's granted universes. Values
/// are pre-formatted the way the app shows them ("4.8K", "+9.7%", "R$182.4K") so the answer can quote
/// them and pass the number check.
public struct InsightToolbox: AskToolbox {
    private let userID: UUID
    private let dashboard: DashboardBuilder
    private let insights: InsightBuilder
    private let now: @Sendable () -> Date

    public init(userID: UUID, dashboard: DashboardBuilder, insights: InsightBuilder, now: @escaping @Sendable () -> Date) {
        self.userID = userID
        self.dashboard = dashboard
        self.insights = insights
        self.now = now
    }

    static let gameIDSchema: JSONValue = ["type": "integer", "description": "Universe ID from list_games."]

    public var tools: [ClaudeRequest.Tool] {
        [
            .init(name: "list_games",
                  description: "The creator's games with current CCU, CCU change vs yesterday, revenue in the last 24 hours, and favourite status. Call this first to find game IDs.",
                  inputSchema: ["type": "object", "additionalProperties": false, "properties": [:], "required": []]),
            .init(name: "get_metric_history",
                  description: "Summary and a short history of one metric for one game: latest, lowest, highest, average and change over the range.",
                  inputSchema: ["type": "object", "additionalProperties": false, "required": ["game_id", "metric", "range"],
                                "properties": ["game_id": Self.gameIDSchema,
                                               "metric": ["type": "string", "enum": ["ccu", "robux", "visits", "favourites"]],
                                               "range": ["type": "string", "enum": ["24h", "7d", "30d"]]]]),
            .init(name: "get_alerts",
                  description: "Unusual changes right now across the creator's games, with possible causes (unconfirmed) and a suggested next step.",
                  inputSchema: ["type": "object", "additionalProperties": false, "properties": [:], "required": []]),
            .init(name: "get_update_impact",
                  description: "Before/after comparison around the game's latest update, with a verdict (improved, neutral, harmed or too early).",
                  inputSchema: ["type": "object", "additionalProperties": false, "required": ["game_id"],
                                "properties": ["game_id": Self.gameIDSchema]]),
            .init(name: "get_funnels",
                  description: "Funnels the game logs (for example Join → Tutorial → First Egg) for the last 7 days: players per step, the biggest drop and whether it got worse.",
                  inputSchema: ["type": "object", "additionalProperties": false, "required": ["game_id"],
                                "properties": ["game_id": Self.gameIDSchema]]),
            .init(name: "get_goals",
                  description: "The creator's goals with progress, time used and status.",
                  inputSchema: ["type": "object", "additionalProperties": false, "properties": [:], "required": []]),
            .init(name: "get_portfolio_health",
                  description: "Each game's health score (0-100) with its strongest and weakest areas.",
                  inputSchema: ["type": "object", "additionalProperties": false, "properties": [:], "required": []]),
        ]
    }

    public func run(name: String, input: JSONValue) async -> (content: String, isError: Bool) {
        do {
            let output: JSONValue = switch name {
            case "list_games": try await listGames()
            case "get_metric_history": try await metricHistory(input)
            case "get_alerts": try await alerts()
            case "get_update_impact": try await updateImpact(input)
            case "get_funnels": try await funnels(input)
            case "get_goals": try await goals()
            case "get_portfolio_health": try await portfolio()
            default: throw ToolError("Unknown tool \(name).")
            }
            return (output.jsonString(), false)
        } catch let error as ToolError {
            return (error.message, true)
        } catch APIFailure.notFound {
            return ("That game isn't one of the creator's games. Use list_games for valid IDs.", true)
        } catch {
            return ("The data couldn't be loaded right now.", true)
        }
    }

    struct ToolError: Error {
        var message: String
        init(_ message: String) { self.message = message }
    }

    private func gameID(_ input: JSONValue) throws -> Int64 {
        guard let raw = input["game_id"]?.doubleValue, raw > 0, raw == raw.rounded(), raw < 9e15 else {
            throw ToolError("game_id must be a universe ID from list_games.")
        }
        return Int64(raw)
    }

    private func listGames() async throws -> JSONValue {
        let board = try await dashboard.dashboard(userID: userID)
        return .array(board.games.map { game in
            var entry: [String: JSONValue] = [
                "game_id": .number(Double(game.id)), "name": .string(game.name),
                "ccu": .string(MetricFormatter.compact(game.stats.ccu)), "is_favourite": .bool(game.isFavourite),
            ]
            if let change = game.stats.ccuChange { entry["ccu_change_vs_yesterday"] = .string(MetricFormatter.percentChange(change)) }
            entry["revenue_24h"] = game.stats.robux24h.map { .string(MetricFormatter.robux($0)) } ?? "not available (needs the Analytics permission)"
            return .object(entry)
        })
    }

    private func metricHistory(_ input: JSONValue) async throws -> JSONValue {
        let game = try gameID(input)
        guard let metric = input["metric"]?.stringValue.flatMap(Metric.init(rawValue:)) else { throw ToolError("Unknown metric.") }
        guard let range = input["range"]?.stringValue.flatMap(TimeRange.init(rawValue:)) else { throw ToolError("Unknown range.") }
        let series = try await dashboard.series(userID: userID, universeID: game, metric: metric, range: range)
        let insight = metric.insightMetric
        guard let first = series.points.first, let last = series.latest else {
            return ["game_id": .number(Double(game)), "metric": .string(metric.rawValue), "range": .string(range.rawValue),
                    "data": "no samples recorded in this range"]
        }
        let values = series.points.map(\.value)
        let format = { (value: Double) in JSONValue.string(InsightText.value(value, metric: insight)) }
        var result: [String: JSONValue] = [
            "game_id": .number(Double(game)), "metric": .string(metric.rawValue), "range": .string(range.rawValue),
            "latest": format(last.value), "lowest": format(values.min()!), "highest": format(values.max()!),
            "average": format(values.reduce(0, +) / Double(values.count)),
            "history": .array(series.downsampled(to: 12).map { point in
                ["time": .string(ISO8601DateFormatter().string(from: point.date)), "value": format(point.value)]
            }),
        ]
        if first.value != 0 {
            result["change_over_range"] = .string(MetricFormatter.percentChange((last.value - first.value) / first.value))
        }
        return .object(result)
    }

    private func alerts() async throws -> JSONValue {
        let digests = try await insights.digests(userID: userID)
        guard digests.isEmpty == false else { return ["alerts": "nothing unusual right now"] }
        return .array(digests.map { digest in
            ["game": .string(digest.gameName), "what_happened": .string(digest.message),
             "possible_causes": .array(digest.causes.map { .string($0.evidence) }),
             "suggested_next_step": .string(digest.suggestedAction)]
        })
    }

    private func updateImpact(_ input: JSONValue) async throws -> JSONValue {
        let game = try gameID(input)
        guard let report = try await insights.updateImpact(userID: userID, universe: game) else {
            return ["game_id": .number(Double(game)), "update": "no update seen in the last 30 days"]
        }
        return [
            "game_id": .number(Double(game)), "update": .string(report.updateLabel), "verdict": .string(report.verdict.rawValue),
            "summary": .string(report.summary),
            "metrics": .array(report.metrics.map { impact in
                var entry: [String: JSONValue] = ["metric": .string(impact.metric.displayName), "verdict": .string(impact.verdict.rawValue)]
                if let before = impact.before { entry["before"] = .string(InsightText.value(before, metric: impact.metric)) }
                if let after = impact.after { entry["after"] = .string(InsightText.value(after, metric: impact.metric)) }
                if let change = impact.change { entry["change"] = .string(MetricFormatter.percentChange(change)) }
                return .object(entry)
            }),
            "caveats": .array(report.caveats.map { .string($0) }),
        ]
    }

    private func funnels(_ input: JSONValue) async throws -> JSONValue {
        let game = try gameID(input)
        let funnels = try await insights.funnels(userID: userID, universe: game)
        guard funnels.isEmpty == false else {
            return ["game_id": .number(Double(game)),
                    "funnels": "none logged (the game needs AnalyticsService:LogFunnelStepEvent)"]
        }
        return .array(funnels.map { funnel in
            ["name": .string(funnel.name), "summary": .string(funnel.report.summary),
             "steps": .array(funnel.steps.map { ["step": .string($0.name), "players": .string(MetricFormatter.compact($0.players))] }),
             "warnings": .array(funnel.report.warnings.map { .string($0) })]
        })
    }

    private func goals() async throws -> JSONValue {
        let board = try await dashboard.dashboard(userID: userID)
        let current = now()
        return .array(board.goals.map { goal in
            let game = board.games.first { $0.id == goal.gameID }
            let value: Double? = game.flatMap { game in
                switch goal.metric {
                case .ccu: Double(game.stats.ccu)
                case .visits: Double(game.stats.visits)
                case .favourites: Double(game.stats.favourites)
                case .robux: game.stats.robux24h.map(Double.init)
                }
            }
            var entry: [String: JSONValue] = ["title": .string(goal.title),
                                              "target": .string(InsightText.value(goal.targetValue, metric: goal.metric.insightMetric))]
            if let value {
                let evaluation = GoalEngine.evaluate(goal, currentValue: value, now: current)
                entry["status"] = .string(evaluation.status.rawValue)
                entry["progress"] = .string(InsightText.oneDecimal(evaluation.progress * 100) + "%")
                if let elapsed = evaluation.timeElapsed { entry["time_used"] = .string(InsightText.oneDecimal(elapsed * 100) + "%") }
            }
            return .object(entry)
        })
    }

    private func portfolio() async throws -> JSONValue {
        .array(try await insights.portfolio(userID: userID).map { health in
            ["game": .string(health.name), "score": .number(Double(health.score)), "summary": .string(health.headline),
             "needs_update": .bool(health.needsUpdate)]
        })
    }
}
