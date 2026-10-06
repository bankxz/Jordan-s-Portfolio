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

    public var id: String { signature }
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
        .sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.signature < rhs.signature
        }
        .prefix(max(0, limit))
        .map { $0 }
    }

    /// Normalises a message so the same bug with different values groups together.
    public static func signature(_ message: String) -> String {
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
        text = replace(#"\d+(\.\d+)?"#, in: text, with: "#")
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
