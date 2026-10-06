import PeakKit
import SwiftUI

struct AdsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if let dashboard = model.dashboard {
                    if dashboard.campaigns.isEmpty {
                        EmptyStateView(title: "No campaigns",
                                       message: "Sponsored experiences and ads you run on Roblox show up here.",
                                       systemImage: "megaphone")
                            .padding(.top, 40)
                    } else {
                        ForEach(dashboard.campaigns) { campaign in
                            NavigationLink(value: Destination.campaign(id: campaign.id)) {
                                CampaignCard(campaign: campaign, gameName: model.game(id: campaign.gameID)?.name)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("campaignCard.\(campaign.id)")
                        }
                    }
                } else if case .failed(let message) = model.phase {
                    ErrorCard(message: message) { await model.refresh() }
                } else {
                    LoadingCard()
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Ads")
        .refreshable { await model.refresh() }
    }
}

struct CampaignDetailView: View {
    let campaignID: String
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let campaign = model.campaign(id: campaignID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        CampaignCard(campaign: campaign, gameName: model.game(id: campaign.gameID)?.name)
                        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                            GridRow {
                                MetricCard(title: "Impressions", value: MetricFormatter.compact(campaign.impressions))
                                MetricCard(title: "Clicks", value: MetricFormatter.compact(campaign.clicks))
                            }
                            GridRow {
                                MetricCard(title: "Plays", value: MetricFormatter.compact(campaign.plays))
                                MetricCard(title: "Cost / 1K views",
                                           value: campaign.costPerMille.map { "R$" + MetricFormatter.decimal($0) } ?? "—")
                            }
                        }
                    }
                    .padding(16)
                }
                .navigationTitle(campaign.name)
            } else {
                EmptyStateView(title: "Campaign not found", message: "It may have ended or been removed.",
                               systemImage: "megaphone")
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AlertsView: View {
    @Environment(AppModel.self) private var model
    @Environment(InsightsModel.self) private var insights

    var body: some View {
        List {
            if let digests = insights.digests.value, digests.isEmpty == false {
                Section {
                    ForEach(digests) { digest in
                        DigestCard(digest: digest)
                            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    Text("Unusual now")
                        .accessibilityIdentifier("alertsUnusualHeader")
                } footer: {
                    Text("Peak compares each game with the same time in previous weeks. Causes are possibilities to check, not confirmed.")
                }
            }
            if let dashboard = model.dashboard {
                Section {
                    if dashboard.recentAlerts.isEmpty {
                        Text("No alerts yet. When a game crosses a threshold you set, it shows up here and as a notification.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(dashboard.recentAlerts.sorted { $0.firedAt > $1.firedAt }, id: \.self) { event in
                        NavigationLink(value: Destination.game(id: event.gameID)) {
                            AlertRow(event: event, gameName: model.game(id: event.gameID)?.name ?? "Unknown game",
                                     now: model.currentDate)
                        }
                    }
                } header: {
                    Text("Recent")
                        .accessibilityIdentifier("alertsRecentHeader")
                } footer: {
                    Text("Alerts are checked on our servers, so they arrive even when Peak is closed.")
                }
            } else if case .failed(let message) = model.phase {
                ErrorCard(message: message) { await model.refresh() }
                    .listRowInsets(EdgeInsets())
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Alerts")
        .refreshable {
            let model = model, insights = insights
            async let dashboard: Void = model.refresh()
            async let digests: Void = insights.loadDigests()
            _ = await (dashboard, digests)
        }
    }
}
