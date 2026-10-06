import PeakKit
import SwiftUI

struct GoalsListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if let dashboard = model.dashboard {
                    if dashboard.goals.isEmpty {
                        EmptyStateView(title: "No goals yet",
                                       message: "Set a target like \u{201C}Reach 5K CCU\u{201D} and Peak tracks your pace.",
                                       systemImage: "flag.checkered")
                            .padding(.top, 40)
                    } else {
                        ForEach(sorted(dashboard.goals)) { goal in
                            NavigationLink(value: Destination.goal(id: goal.id)) {
                                GoalCard(goal: goal, evaluation: model.evaluation(for: goal))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("goalCard.\(goal.id.uuidString)")
                        }
                    }
                } else if case .failed(let message) = model.phase {
                    ErrorCard(message: message) { await model.refresh() }
                } else {
                    LoadingCard()
                    LoadingCard()
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Goals")
        .refreshable { await model.refresh() }
    }

    /// Goals needing attention first.
    private func sorted(_ goals: [Goal]) -> [Goal] {
        func rank(_ status: GoalStatus) -> Int {
            switch status {
            case .behind: 0
            case .atRisk: 1
            case .onTrack: 2
            case .invalid: 3
            case .missed: 4
            case .achieved: 5
            }
        }
        return goals.sorted { rank(model.evaluation(for: $0).status) < rank(model.evaluation(for: $1).status) }
    }
}

struct GoalDetailView: View {
    let goalID: UUID
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let goal = model.goal(id: goalID) {
                detail(goal, evaluation: model.evaluation(for: goal))
            } else if model.dashboard == nil {
                ProgressView()
            } else {
                EmptyStateView(title: "Goal not found", message: "This goal may have been deleted.",
                               systemImage: "flag.slash")
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Goal")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detail(_ goal: Goal, evaluation: GoalEvaluation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GoalCard(goal: goal, evaluation: evaluation)

                VStack(alignment: .leading, spacing: 8) {
                    infoRow("Metric", goal.metric.title)
                    infoRow("Started at", MetricFormatter.compact(goal.startValue))
                    infoRow("Target", MetricFormatter.compact(goal.targetValue))
                    if let deadline = goal.deadline {
                        infoRow("Deadline", deadline.formatted(date: .abbreviated, time: .omitted))
                    }
                    if let projected = evaluation.projectedCompletion {
                        infoRow("Projected", projected.formatted(date: .abbreviated, time: .omitted))
                    }
                }
                .card()

                if goal.tasks.isEmpty == false {
                    SectionHeader(title: "Tasks")
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(goal.tasks) { task in
                            Label {
                                Text(task.title).strikethrough(task.isDone)
                            } icon: {
                                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(task.isDone ? Color.green : Color.secondary)
                            }
                            .frame(minHeight: 44)
                            .accessibilityValue(task.isDone ? "Done" : "Not done")
                        }
                    }
                    .card()
                }
            }
            .padding(16)
        }
    }

    private func infoRow(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.subheadline)
    }
}

#Preview {
    NavigationStack { GoalsListView() }
        .environment(PreviewSupport.model(.normal))
}
