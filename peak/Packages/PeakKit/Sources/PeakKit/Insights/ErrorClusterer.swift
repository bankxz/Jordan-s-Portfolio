import Foundation

/// One error line from a game server log (Roblox Server Management API) or a forwarded client error.
public struct LogEntry: Hashable, Codable, Sendable {
    public var message: String
    public var timestamp: Date
    public var placeVersion: Int?

    public init(message: String, timestamp: Date, placeVersion: Int? = nil) {
        self.message = message
        self.timestamp = timestamp
        self.placeVersion = placeVersion
    }
}

public struct ErrorCluster: Hashable, Codable, Sendable, Identifiable {
    /// The message with variable parts (numbers, IDs, player names, quoted values) replaced.
    public var signature: String
    /// One real example, for context.
    public var example: String
    public var count: Int
    /// Share of all errors in the input (0...1).
    public var share: Double
    public var firstSeen: Date
    public var lastSeen: Date
    public var versions: [Int]
    /// Only seen in the newest version in the input, so likely introduced by it.
    public var isNewInLatestVersion: Bool
    /// Where it happened: "server", "client" (players' devices), or empty when unknown.
    public var sources: [String]

    public var id: String { signature }

    public init(signature: String, example: String, count: Int, share: Double, firstSeen: Date, lastSeen: Date,
                versions: [Int], isNewInLatestVersion: Bool, sources: [String] = []) {
        self.signature = signature
        self.example = example
        self.count = count
        self.share = share
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.versions = versions
        self.isNewInLatestVersion = isNewInLatestVersion
        self.sources = sources
    }
}

/// Already-grouped counts, as the in-game reporter sends them and the server stores them (one row per day,
/// signature, place version and source). Holds no raw message, only the redacted example.
public struct ErrorCount: Hashable, Codable, Sendable {
    public var signature: String
    public var example: String
    public var source: String
    public var placeVersion: Int?
    public var count: Int
    public var firstSeen: Date
    public var lastSeen: Date

    public init(signature: String, example: String, source: String, placeVersion: Int?, count: Int,
                firstSeen: Date, lastSeen: Date) {
        self.signature = signature
        self.example = example
        self.source = source
        self.placeVersion = placeVersion
        self.count = count
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

/// Groups thousands of similar error lines into a few issues, most frequent first.
public enum ErrorClusterer {
    public static func cluster(_ entries: [LogEntry], limit: Int = 10) -> [ErrorCluster] {
        guard entries.isEmpty == false else { return [] }
        let latestVersion = entries.compactMap(\.placeVersion).max()
        var groups: [String: [LogEntry]] = [:]
        for entry in entries {
            groups[signature(entry.message), default: []].append(entry)
        }
        let total = Double(entries.count)
        return groups.map { signature, group in
            let versions = Set(group.compactMap(\.placeVersion)).sorted()
            let isNew = latestVersion != nil && versions == [latestVersion!]
                && entries.contains { $0.placeVersion != nil && $0.placeVersion! < latestVersion! }
            let sorted = group.sorted { $0.timestamp < $1.timestamp }
            return ErrorCluster(signature: signature, example: sorted.last!.message, count: group.count,
                                share: Double(group.count) / total, firstSeen: sorted.first!.timestamp,
                                lastSeen: sorted.last!.timestamp, versions: versions, isNewInLatestVersion: isNew)
        }
        .sorted(by: mostFrequentFirst)
        .prefix(max(0, limit))
        .map { $0 }
    }

    /// The same grouping over stored counts.
    public static func cluster(counts: [ErrorCount], limit: Int = 10) -> [ErrorCluster] {
        let total = Double(counts.reduce(0) { $0 + max(0, $1.count) })
        guard total > 0 else { return [] }
        let latestVersion = counts.compactMap(\.placeVersion).max()
        let hasOlderVersion = latestVersion.map { latest in counts.contains { ($0.placeVersion ?? latest) < latest } } ?? false
        return Dictionary(grouping: counts.filter { $0.count > 0 }, by: \.signature).map { signature, group in
            let versions = Set(group.compactMap(\.placeVersion)).sorted()
            let count = group.reduce(0) { $0 + $1.count }
            let newest = group.max { $0.lastSeen < $1.lastSeen }!
            return ErrorCluster(signature: signature, example: newest.example, count: count, share: Double(count) / total,
                                firstSeen: group.map(\.firstSeen).min()!, lastSeen: newest.lastSeen, versions: versions,
                                isNewInLatestVersion: hasOlderVersion && versions == [latestVersion!],
                                sources: Set(group.map(\.source)).sorted())
        }
        .sorted(by: mostFrequentFirst)
        .prefix(max(0, limit))
        .map { $0 }
    }

    static func mostFrequentFirst(_ lhs: ErrorCluster, _ rhs: ErrorCluster) -> Bool {
        if lhs.count != rhs.count { return lhs.count > rhs.count }
        return lhs.signature < rhs.signature
    }

    /// Normalises a message so the same bug with different values groups together.
    public static func signature(_ message: String) -> String {
        normalise(message, keepLineNumbers: false)
    }

    /// A readable example that is safe to store: player names, IDs, quoted values and numbers are removed like in
    /// the signature, but script line numbers (`Script:42:`) are kept because they say where to look.
    public static func redacted(_ message: String) -> String {
        normalise(message, keepLineNumbers: true)
    }

    static func normalise(_ message: String, keepLineNumbers: Bool) -> String {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        // Player paths: Players.SomeName.Backpack → Players.<player>.Backpack
        text = replace(#"Players\.[A-Za-z0-9_]+"#, in: text, with: "Players.<player>")
        // GUIDs and long hex IDs.
        text = replace(#"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#, in: text, with: "<id>")
        text = replace(#"\b[0-9a-fA-F]{16,}\b"#, in: text, with: "<id>")
        // Quoted values.
        text = replace(#""[^"]*""#, in: text, with: "\"…\"")
        text = replace(#"'[^']*'"#, in: text, with: "'…'")
        // Remaining numbers (line numbers, amounts, user IDs).
        if keepLineNumbers {
            // A number between two colons is a line reference; any other number goes.
            text = replace(#"(?<![:\d.])\d+(\.\d+)?|\d+(\.\d+)?(?![:\d.])"#, in: text, with: "#")
        } else {
            text = replace(#"\d+(\.\d+)?"#, in: text, with: "#")
        }
        text = replace(#"\s+"#, in: text, with: " ")
        return text
    }

    static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range,
                                              withTemplate: NSRegularExpression.escapedTemplate(for: template))
    }
}

extension ErrorCluster {
    /// "Happened 1.8K times (79.1% of reported errors), on the server. Only seen in v128."
    public var summary: String {
        var text = "Happened \(MetricFormatter.compact(count)) \(count == 1 ? "time" : "times") "
            + "(\(InsightText.oneDecimal(share * 100))% of reported errors)"
        switch Set(sources) {
        case ["server"]: text += ", on the server."
        case ["client"]: text += ", on players' devices."
        case ["client", "server"]: text += ", on the server and on players' devices."
        default: text += "."
        }
        if isNewInLatestVersion, let version = versions.last {
            text += " Only seen in v\(version), so the latest update is a possible cause."
        }
        return text
    }

    /// Script path and line from the example, e.g. ("ServerScriptService.Pets", 42).
    public var location: (script: String, line: Int)? {
        guard let match = example.range(of: #"^[A-Za-z0-9_.<>]+:\d+:"#, options: .regularExpression) else { return nil }
        let parts = example[match].dropLast().split(separator: ":")
        guard parts.count == 2, let line = Int(parts[1]) else { return nil }
        return (String(parts[0]), line)
    }
}
