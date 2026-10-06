import Foundation

/// A creator goal, e.g. "Reach 5K CCU on Attack Animals by 1 December".
public struct Goal: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var title: String
    /// The game the goal tracks. `nil` for portfolio-wide goals.
    public var gameID: Int64?
    public var metric: Metric
    /// Metric value when the goal was created.
    public var startValue: Double
    public var targetValue: Double
    public var createdAt: Date
    public var deadline: Date?
    public var tasks: [GoalTask]

    public init(
        id: UUID = UUID(),
        title: String,
        gameID: Int64? = nil,
        metric: Metric,
        startValue: Double,
        targetValue: Double,
        createdAt: Date,
        deadline: Date? = nil,
        tasks: [GoalTask] = []
    ) {
        self.id = id
        self.title = title
        self.gameID = gameID
        self.metric = metric
        self.startValue = startValue
        self.targetValue = targetValue
        self.createdAt = createdAt
        self.deadline = deadline
        self.tasks = tasks
    }
}

public struct GoalTask: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var isDone: Bool

    public init(id: UUID = UUID(), title: String, isDone: Bool = false) {
        self.id = id
        self.title = title
        self.isDone = isDone
    }
}
