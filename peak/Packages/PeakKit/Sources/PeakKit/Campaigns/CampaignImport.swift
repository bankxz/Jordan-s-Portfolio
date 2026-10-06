import Foundation

/// Imports ad performance from an Ads Manager CSV export. Roblox's Ads Management API has campaigns and
/// budgets but no impressions, clicks, plays or spend (docs/ai/AI_FEATURES.md), so performance comes from the
/// file the creator downloads.
///
/// The export's exact column names aren't documented, so columns are matched by common names and the
/// result says which required ones were missing instead of guessing.
public enum CampaignImport {
    public enum Column: String, CaseIterable, Sendable, Hashable {
        case campaign, impressions, clicks, plays, spend, status, budget
    }

    public struct Result: Sendable, Hashable {
        public var campaigns: [Campaign]
        /// Which header each column was read from.
        public var mapping: [Column: String]
        public var missingRequired: [Column]
        public var skippedRows: Int
    }

    public enum Failure: Error, Equatable, Sendable {
        case empty
        case tooLarge
        case missingColumns([Column])
    }

    public static let required: [Column] = [.campaign, .impressions, .spend]
    public static let maxBytes = 1_000_000

    /// Normalised header names (lowercased, letters and digits only) for each column.
    static let aliases: [Column: [String]] = [
        .campaign: ["campaign", "campaignname", "adset", "adsetname", "adname", "name"],
        .impressions: ["impressions", "impr", "totalimpressions"],
        .clicks: ["clicks", "totalclicks", "linkclicks"],
        .plays: ["plays", "visits", "playsfromad", "attributedplays", "conversions"],
        .spend: ["spend", "spent", "cost", "amountspent", "robuxspent", "spendrobux", "costrobux", "totalspend"],
        .status: ["status", "deliverystatus", "campaignstatus"],
        .budget: ["budget", "totalbudget", "dailybudget", "budgetrobux"],
    ]

    public static func parse(csv: String, gameID: Int64) throws -> Result {
        guard csv.utf8.count <= maxBytes else { throw Failure.tooLarge }
        let rows = CSV.rows(csv).filter { $0.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty == false } }
        guard let header = rows.first, rows.count > 1 else { throw Failure.empty }

        var mapping: [Column: String] = [:]
        var index: [Column: Int] = [:]
        for (position, raw) in header.enumerated() {
            let key = raw.lowercased().filter { $0.isLetter || $0.isNumber }
            for column in Column.allCases where index[column] == nil && aliases[column]!.contains(key) {
                index[column] = position
                mapping[column] = raw.trimmingCharacters(in: .whitespaces)
                break
            }
        }
        let missing = required.filter { index[$0] == nil }
        guard missing.isEmpty else { throw Failure.missingColumns(missing) }

        // Several rows per campaign (one per day or ad) are summed.
        var totals: [String: (impressions: Int64, clicks: Int64, plays: Int64, spend: Int64, budget: Int64?, status: String?)] = [:]
        var order: [String] = []
        var skipped = 0
        for row in rows.dropFirst() {
            func field(_ column: Column) -> String? {
                guard let position = index[column], position < row.count else { return nil }
                let value = row[position].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
            guard let name = field(.campaign), name.lowercased() != "total",
                  let impressions = field(.impressions).flatMap(number), let spend = field(.spend).flatMap(number) else {
                skipped += 1
                continue
            }
            if totals[name] == nil { order.append(name) }
            var entry = totals[name] ?? (0, 0, 0, 0, nil, nil)
            entry.impressions += impressions
            entry.clicks += field(.clicks).flatMap(number) ?? 0
            entry.plays += field(.plays).flatMap(number) ?? 0
            entry.spend += spend
            if let budget = field(.budget).flatMap(number) { entry.budget = max(entry.budget ?? 0, budget) }
            entry.status = field(.status) ?? entry.status
            totals[name] = entry
        }

        let campaigns = order.map { name in
            let entry = totals[name]!
            return Campaign(id: "import-\(stableID(name))", name: name, gameID: gameID, status: status(entry.status),
                            spentRobux: entry.spend, budgetRobux: entry.budget, impressions: entry.impressions,
                            clicks: entry.clicks, plays: entry.plays)
        }
        return Result(campaigns: campaigns, mapping: mapping, missingRequired: [], skippedRows: skipped)
    }

    /// "1,234", "R$1,234", "1234.6", " 12 " → whole numbers. Negative or non-numeric → nil.
    static func number(_ raw: String) -> Int64? {
        let cleaned = raw.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "R$", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(cleaned), value.isFinite, value >= 0, value < 1e15 else { return nil }
        return Int64(value.rounded())
    }

    static func status(_ raw: String?) -> Campaign.Status {
        switch raw?.lowercased() ?? "" {
        case let text where text.contains("pause"): .paused
        case let text where text.contains("schedul") || text.contains("pending"): .scheduled
        case let text where text.contains("complete") || text.contains("end") || text.contains("cancel") || text.contains("stop"): .completed
        default: .running
        }
    }

    /// A short ID that's the same for the same name on every import (FNV-1a), so re-imports replace rather than duplicate.
    static func stableID(_ name: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

/// Minimal RFC 4180 CSV reader: quoted fields, escaped quotes, commas and newlines inside quotes.
enum CSV {
    static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.replacingOccurrences(of: "\r\n", with: "\n").makeIterator()
        var pending: Character?
        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"" where field.isEmpty: inQuotes = true
                case ",": row.append(field); field = ""
                case "\n", "\r": row.append(field); rows.append(row); row = []; field = ""
                default: field.append(character)
                }
            }
        }
        if field.isEmpty == false || row.isEmpty == false {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
