import PeakKit
import SwiftUI

/// "Reach 1,000 CCU within 30 days" → weekly targets and starting tasks. Runs on the phone with
/// `GoalPlanner`, so it works offline and without AI.
struct GoalPlannerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var gameID: Int64?
    @State private var metric: Metric = .ccu
    @State private var targetText = ""
    @State private var days = 30

    var body: some View {
        NavigationStack {
            Form {
                Section("Goal") {
                    Picker("Game", selection: $gameID) {
                        ForEach(games) { game in
                            Text(game.name).tag(Optional(game.id))
                        }
                    }
                    Picker("Metric", selection: $metric) {
                        Text("Players (CCU)").tag(Metric.ccu)
                        Text("Visits").tag(Metric.visits)
                        Text("Favourites").tag(Metric.favourites)
                    }
                    LabeledContent("Target") {
                        TextField("Target", text: $targetText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("goalTargetField")
                    }
                    Stepper("Within \(days) days", value: $days, in: 7...180, step: 7)
                }

                if let plan {
                    Section {
                        Text(plan.summary)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("goalPlanSummary")
                    } header: {
                        Text("Plan")
                    } footer: {
                        Text("Growth compounds week to week, so early targets are smaller.")
                    }
                    Section("Weekly targets") {
                        ForEach(plan.weeks, id: \.week) { week in
                            HStack {
                                Text("Week \(week.week)")
                                Text(week.endDate.formatted(date: .abbreviated, time: .omitted))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(InsightText.value(week.target, metric: plan.metric))
                                    .monospacedDigit()
                            }
                        }
                    }
                    Section("Tasks to start with") {
                        ForEach(plan.tasks, id: \.self) { task in
                            Label(task, systemImage: "circle")
                        }
                    }
                    Section {
                        ShareLink(item: text(for: plan)) {
                            Label("Share plan", systemImage: "square.and.arrow.up")
                        }
                    }
                } else if currentValue != nil {
                    Section {
                        Text("Enter a target above the current value to see a weekly plan.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Plan a goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if gameID == nil { gameID = games.first?.id }
                if targetText.isEmpty, let current = currentValue {
                    // Suggest doubling, rounded to two significant digits, as a starting point.
                    targetText = String(Int64(Self.roundSignificant(max(current * 2, 100))))
                }
            }
        }
    }

    private var games: [Game] {
        (model.dashboard?.games ?? []).sorted { lhs, rhs in
            if lhs.isWorkingOn != rhs.isWorkingOn { return lhs.isWorkingOn }
            return lhs.stats.ccu > rhs.stats.ccu
        }
    }

    private var currentValue: Double? {
        guard let game = games.first(where: { $0.id == gameID }) else { return nil }
        return WidgetSnapshot.value(of: metric, in: game.stats)
    }

    private var plan: GoalPlan? {
        guard let current = currentValue, let target = Double(targetText.filter(\.isNumber)), target > current else { return nil }
        let start = model.currentDate
        return GoalPlanner.plan(metric: metric.insightMetric, current: current, target: target, start: start,
                                deadline: start.addingTimeInterval(Double(days) * 86_400))
    }

    private func text(for plan: GoalPlan) -> String {
        let name = games.first { $0.id == gameID }?.name ?? "My game"
        var lines = ["\(name): \(plan.summary)", ""]
        lines += plan.weeks.map { "Week \($0.week): \(InsightText.value($0.target, metric: plan.metric))" }
        lines += ["", "Tasks:"] + plan.tasks.map { "- \($0)" }
        return lines.joined(separator: "\n")
    }

    static func roundSignificant(_ value: Double) -> Double {
        guard value > 0 else { return value }
        let magnitude = pow(10, floor(log10(value)) - 1)
        return (value / magnitude).rounded() * magnitude
    }
}

#Preview {
    GoalPlannerView()
        .environment(PreviewSupport.model(.normal))
}
