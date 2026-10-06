import Foundation

/// A suggestion for one campaign. Peak never changes budgets (decision 0007): the creator decides in Ads Manager.
public struct CampaignInsight: Hashable, Codable, Sendable, Identifiable {
    public enum Suggestion: String, Hashable, Codable, Sendable {
        case increase
        case maintain
        case reduce
        case pause
        case needsData
    }

    public var campaignID: String
    public var name: String
    public var suggestion: Suggestion
    public var summary: String

    public var id: String { campaignID }
}

/// Explains campaign numbers in plain language and suggests a budget direction by comparing campaigns with
/// each other (Roblox publishes no benchmark to compare with). A suggestion, never an action.
public enum CampaignAnalyst {
    /// Below this many impressions, rates are too noisy to act on.
    public static let minimumImpressions: Int64 = 1_000

    public static func analyze(_ campaigns: [Campaign]) -> [CampaignInsight] {
        // Benchmarks come from campaigns that are measurable and brought plays; a dud shouldn't lower the bar.
        let measured = campaigns.filter { $0.impressions >= minimumImpressions && $0.spentRobux > 0 && $0.plays > 0 }
        let medianCostPerPlay = Stats.median(measured.compactMap(\.costPerPlay))
        let medianCTR = Stats.median(measured.compactMap(\.clickThroughRate))
        let canCompare = measured.count >= 2

        return campaigns.map { campaign in
            var parts: [String] = []
            if let ctr = campaign.clickThroughRate {
                parts.append("CTR \(InsightText.oneDecimal(ctr * 100))%" + (canCompare ? medianCTR.map { " (median \(InsightText.oneDecimal($0 * 100))%)" } ?? "" : ""))
            }
            if let costPerPlay = campaign.costPerPlay {
                parts.append("\(InsightText.value(costPerPlay, metric: .revenuePerPlayer)) per play"
                             + (canCompare ? medianCostPerPlay.map { " (median \(InsightText.value($0, metric: .revenuePerPlayer)))" } ?? "" : ""))
            }
            let numbers = parts.isEmpty ? "" : parts.joined(separator: ", ") + ". "

            let suggestion: CampaignInsight.Suggestion
            let reason: String
            if campaign.impressions < minimumImpressions || campaign.spentRobux == 0 {
                suggestion = .needsData
                reason = "Not enough impressions yet to judge."
            } else if campaign.plays == 0 {
                suggestion = .pause
                reason = "It's spending without bringing any plays. Check the creative and targeting."
            } else if canCompare, let costPerPlay = campaign.costPerPlay, let ctr = campaign.clickThroughRate,
                      let medianCost = medianCostPerPlay, let medianRate = medianCTR {
                if costPerPlay <= medianCost * 0.8 && ctr >= medianRate {
                    suggestion = .increase
                    reason = "Cheaper plays than your other campaigns. A bigger budget is worth testing."
                } else if costPerPlay >= medianCost * 1.5 || ctr <= medianRate * 0.5 {
                    suggestion = .reduce
                    reason = "More expensive per play than your other campaigns. Try a new creative before spending more."
                } else {
                    suggestion = .maintain
                    reason = "In line with your other campaigns."
                }
            } else {
                suggestion = .maintain
                reason = "Import another campaign to compare against."
            }
            return CampaignInsight(campaignID: campaign.id, name: campaign.name, suggestion: suggestion, summary: numbers + reason)
        }
    }
}
