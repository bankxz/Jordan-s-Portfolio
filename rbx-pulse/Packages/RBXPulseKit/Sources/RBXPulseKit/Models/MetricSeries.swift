import Foundation

public enum Metric: String, Codable, Sendable, CaseIterable {
    case ccu
    case visits
    case favourites
    case robux
}

public struct MetricPoint: Hashable, Codable, Sendable {
    public var date: Date
    public var value: Double

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

/// A time series for one metric of one game. Points are kept sorted by date.
public struct MetricSeries: Hashable, Codable, Sendable {
    public var metric: Metric
    public private(set) var points: [MetricPoint]

    public init(metric: Metric, points: [MetricPoint]) {
        self.metric = metric
        self.points = points.sorted { $0.date < $1.date }
    }

    public var latest: MetricPoint? { points.last }

    public var peak: MetricPoint? { points.max { $0.value < $1.value } }

    /// Points whose date falls in `[start, end]`.
    public func points(from start: Date, to end: Date) -> [MetricPoint] {
        points.filter { $0.date >= start && $0.date <= end }
    }

    /// Reduces the series to at most `maxPoints` by averaging consecutive buckets.
    /// Charts and widget sparklines stay cheap to render regardless of history length.
    public func downsampled(to maxPoints: Int) -> [MetricPoint] {
        guard maxPoints > 0 else { return [] }
        guard points.count > maxPoints else { return points }
        let bucketSize = Double(points.count) / Double(maxPoints)
        var result: [MetricPoint] = []
        result.reserveCapacity(maxPoints)
        for bucket in 0..<maxPoints {
            let lower = Int((Double(bucket) * bucketSize).rounded(.down))
            let upper = min(points.count, Int((Double(bucket + 1) * bucketSize).rounded(.down)))
            guard lower < upper else { continue }
            let slice = points[lower..<upper]
            let mean = slice.reduce(0) { $0 + $1.value } / Double(slice.count)
            // Keep the last date in the bucket so the final point stays the true latest.
            result.append(MetricPoint(date: slice.last!.date, value: mean))
        }
        return result
    }
}
