import Foundation
import Testing
@testable import RBXPulseKit

struct MetricFormatterTests {
    @Test(arguments: [
        (0.0, "0"),
        (7, "7"),
        (999, "999"),
        (999.4, "999"),
        (999.6, "1K"),
        (1_000, "1K"),
        (1_049, "1K"),
        (1_050, "1.1K"),
        (1_250, "1.3K"),
        (12_400, "12.4K"),
        (999_949, "999.9K"),
        (999_950, "1M"),
        (1_000_000, "1M"),
        (2_345_678, "2.3M"),
        (999_999_999, "1B"),
        (1_500_000_000, "1.5B"),
        (4_200_000_000_000, "4.2T"),
    ])
    func compactPositive(value: Double, expected: String) {
        #expect(MetricFormatter.compact(value) == expected)
    }

    @Test(arguments: [
        (-1.0, "-1"),
        (-12_400, "-12.4K"),
        (-999_950, "-1M"),
    ])
    func compactNegative(value: Double, expected: String) {
        #expect(MetricFormatter.compact(value) == expected)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func compactNonFiniteRendersDash(value: Double) {
        #expect(MetricFormatter.compact(value) == "—")
    }

    @Test func compactHandlesInt64Extremes() {
        #expect(MetricFormatter.compact(Int64.max).hasSuffix("T"))
        #expect(MetricFormatter.compact(Int64.min).hasPrefix("-"))
    }

    @Test(arguments: [
        (Int64(0), "R$0"),
        (950, "R$950"),
        (12_400, "R$12.4K"),
        (-3_000, "-R$3K"),
    ])
    func robux(value: Int64, expected: String) {
        #expect(MetricFormatter.robux(value) == expected)
    }

    @Test(arguments: [
        (0.0, "0%"),
        (0.0004, "0%"),
        (0.253, "+25.3%"),
        (-0.5, "-50%"),
        (1.0, "+100%"),
        (12.345, "+1234.5%"),
        (-0.0004, "0%"),
    ])
    func percentChange(fraction: Double, expected: String) {
        #expect(MetricFormatter.percentChange(fraction) == expected)
    }

    @Test func percentChangeNonFinite() {
        #expect(MetricFormatter.percentChange(.nan) == "—")
    }
}

struct FreshnessTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static let cases: [(age: TimeInterval, level: Freshness.Level, label: String)] = [
        (0, .live, "Updated just now"),
        (59, .live, "Updated just now"),
        (120, .live, "Updated 2m ago"),
        (121, .recent, "Updated 2m ago"),
        (1_740, .recent, "Updated 29m ago"),
        (1_800, .stale, "Updated 30m ago"),
        (10_859, .stale, "Updated 3h ago"),
        (172_801, .stale, "Updated 2d ago"),
    ]

    @Test(arguments: cases)
    func levelsAndLabels(age: TimeInterval, level: Freshness.Level, label: String) {
        let freshness = Freshness(updatedAt: now.addingTimeInterval(-age), now: now)
        #expect(freshness.level == level)
        #expect(freshness.label == label)
    }

    @Test func futureTimestampFromClockSkewIsLive() {
        let freshness = Freshness(updatedAt: now.addingTimeInterval(300), now: now)
        #expect(freshness.age == 0)
        #expect(freshness.level == .live)
    }
}

struct MetricSeriesTests {
    let origin = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func series(_ values: [Double]) -> MetricSeries {
        MetricSeries(metric: .ccu, points: values.enumerated().map {
            MetricPoint(date: origin.addingTimeInterval(Double($0.offset) * 60), value: $0.element)
        })
    }

    @Test func pointsAreSortedOnInit() {
        let unsorted = MetricSeries(metric: .ccu, points: [
            MetricPoint(date: origin.addingTimeInterval(60), value: 2),
            MetricPoint(date: origin, value: 1),
        ])
        #expect(unsorted.points.map(\.value) == [1, 2])
        #expect(unsorted.latest?.value == 2)
    }

    @Test func peakAndEmpty() {
        #expect(series([3, 9, 4]).peak?.value == 9)
        #expect(series([]).peak == nil)
        #expect(series([]).latest == nil)
    }

    @Test func downsampleKeepsShortSeriesUntouched() {
        let short = series([1, 2, 3])
        #expect(short.downsampled(to: 10) == short.points)
    }

    @Test func downsampleAveragesBucketsAndKeepsLatestDate() throws {
        let long = series((0..<100).map(Double.init))
        let reduced = long.downsampled(to: 10)
        #expect(reduced.count == 10)
        #expect(reduced.first?.value == 4.5)
        let last = try #require(reduced.last)
        #expect(last.date == long.latest?.date)
        #expect(last.value == 94.5)
    }

    @Test(arguments: [0, -1])
    func downsampleToNonPositiveIsEmpty(maxPoints: Int) {
        #expect(series([1, 2, 3]).downsampled(to: maxPoints).isEmpty)
    }

    @Test func downsampleUnevenBucketsNeverExceedsLimit() {
        for count in [11, 37, 101, 1_000] {
            let reduced = series((0..<count).map(Double.init)).downsampled(to: 7)
            #expect(reduced.count <= 7)
            #expect(reduced.count > 0)
        }
    }
}
