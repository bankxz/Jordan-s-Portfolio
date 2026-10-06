import Foundation

/// Small, robust statistics used by the insight engines. Robust (median/MAD) rather than mean/stddev so
/// a single spike in the history doesn't hide the next one.
enum Stats {
    static func mean(_ values: [Double]) -> Double? {
        let finite = values.filter(\.isFinite)
        guard finite.isEmpty == false else { return nil }
        return finite.reduce(0, +) / Double(finite.count)
    }

    static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard sorted.isEmpty == false else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// Median absolute deviation, scaled to be comparable with a standard deviation for normal data.
    static func scaledMAD(_ values: [Double]) -> Double? {
        guard let centre = median(values) else { return nil }
        return median(values.map { abs($0 - centre) }).map { $0 * 1.4826 }
    }

    /// Sample standard deviation. `nil` for fewer than two values.
    static func standardDeviation(_ values: [Double]) -> Double? {
        let finite = values.filter(\.isFinite)
        guard finite.count >= 2, let mean = mean(finite) else { return nil }
        let variance = finite.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(finite.count - 1)
        return variance.squareRoot()
    }

    /// Fractional change from `old` to `new` (0.25 == +25%). `nil` when `old` is zero or not finite.
    static func change(from old: Double, to new: Double) -> Double? {
        guard old != 0, old.isFinite, new.isFinite else { return nil }
        return (new - old) / abs(old)
    }

    /// The point closest to `date`, if one lies within `tolerance`.
    static func value(near date: Date, in points: [MetricPoint], tolerance: TimeInterval) -> Double? {
        var best: (distance: TimeInterval, value: Double)?
        for point in points {
            let distance = abs(point.date.timeIntervalSince(date))
            guard distance <= tolerance else { continue }
            if best == nil || distance < best!.distance { best = (distance, point.value) }
        }
        return best?.value
    }
}
