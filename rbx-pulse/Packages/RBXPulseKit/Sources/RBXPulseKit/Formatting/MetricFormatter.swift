import Foundation

/// Locale-independent compact number formatting used on cards, widgets and charts.
///
/// Deterministic output on purpose: widgets, Live Activities and push payloads must render
/// the same string the app shows, and tests must not depend on the host locale.
public enum MetricFormatter {
    private static let units: [(threshold: Double, suffix: String)] = [
        (1_000_000_000_000, "T"),
        (1_000_000_000, "B"),
        (1_000_000, "M"),
        (1_000, "K"),
    ]

    /// `999` → "999", `1_250` → "1.3K", `999_950` → "1M", `-12_400` → "-12.4K".
    public static func compact(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let sign = value < 0 ? "-" : ""
        let magnitude = abs(value)

        // Walk units from smallest to largest so rounding can promote (999.95K → 1M).
        var scaled = magnitude
        var suffix = ""
        for unit in units.reversed() where magnitude >= unit.threshold {
            scaled = magnitude / unit.threshold
            suffix = unit.suffix
        }
        var rounded = roundToOneDecimal(scaled)
        if rounded >= 1000, let promoted = nextUnit(after: suffix) {
            rounded = roundToOneDecimal(rounded / 1000)
            suffix = promoted
        }
        if suffix.isEmpty {
            // Below 1K: whole numbers only.
            let whole = magnitude.rounded()
            if whole >= 1000 { return sign + "1K" }
            return whole == 0 ? "0" : sign + String(Int64(whole))
        }
        return sign + trimmed(rounded) + suffix
    }

    public static func compact(_ value: Int) -> String { compact(Double(value)) }
    public static func compact(_ value: Int64) -> String { compact(Double(value)) }

    /// Robux amount with the R$ prefix, e.g. "R$12.4K".
    public static func robux(_ value: Int64) -> String {
        value < 0 ? "-R$" + compact(-value) : "R$" + compact(value)
    }

    /// Signed percentage from a fraction: `0.253` → "+25.3%", `-0.5` → "-50%", `0` → "0%".
    public static func percentChange(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "—" }
        let percent = roundToOneDecimal(fraction * 100)
        if percent == 0 { return "0%" }
        let sign = percent > 0 ? "+" : "-"
        return sign + trimmed(abs(percent)) + "%"
    }

    private static func roundToOneDecimal(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private static func trimmed(_ value: Double) -> String {
        if value == value.rounded() {
            return String(Int64(value))
        }
        return String(format: "%.1f", value)
    }

    private static func nextUnit(after suffix: String) -> String? {
        switch suffix {
        case "K": "M"
        case "M": "B"
        case "B": "T"
        default: nil
        }
    }
}
