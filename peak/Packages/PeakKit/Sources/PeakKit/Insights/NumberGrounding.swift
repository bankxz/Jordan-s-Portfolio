import Foundation

/// Rejects AI wording that contains numbers the facts don't support.
///
/// Every number in the AI text must equal a number in the facts, allowing only for the rounding the AI
/// wrote ("24%" may stand for 24.3%, "4.8K" for 4,812). Small whole numbers (0–10) are allowed
/// for counting words ("3 games", "2 h"). Anything else, such as a new percentage or a made-up projection,
/// fails, and the deterministic text is used instead.
public enum NumberGrounding {
    public struct Number: Hashable, Sendable {
        public var value: Double
        public var isPercent: Bool
        /// Half a unit of the last written digit, scaled by any K/M/B suffix ("4.8K" → 50).
        public var precision: Double
        public var text: String
    }

    public static func check(_ text: String, against facts: [String]) -> [Number] {
        let allowed = facts.flatMap(numbers(in:))
        return numbers(in: text).filter { candidate in
            if candidate.isPercent == false, candidate.value == candidate.value.rounded(), abs(candidate.value) <= 10 {
                return false
            }
            return allowed.contains { fact in
                fact.isPercent == candidate.isPercent
                    && abs(abs(fact.value) - abs(candidate.value)) <= max(candidate.precision, abs(fact.value) * 0.005)
            } == false
        }
    }

    public static func isGrounded(_ text: String, facts: [String]) -> Bool {
        check(text, against: facts).isEmpty
    }

    /// Numbers in reading order. Digits glued to letters (D1, v128, x2) are part of a word and skipped.
    public static func numbers(in text: String) -> [Number] {
        let characters = Array(text)
        var result: [Number] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            guard character.isASCII, character.isNumber else { index += 1; continue }
            if index > 0, characters[index - 1].isLetter || characters[index - 1].isNumber || characters[index - 1] == "." {
                // Part of a word like "D1" or "v128", or a fragment of something already consumed.
                while index < characters.count, characters[index].isNumber || characters[index] == "." { index += 1 }
                continue
            }
            var digits = ""
            var decimals = 0
            var seenPoint = false
            var cursor = index
            while cursor < characters.count {
                let current = characters[cursor]
                if current.isASCII, current.isNumber {
                    digits.append(current)
                    if seenPoint { decimals += 1 }
                } else if current == ",", seenPoint == false, isThousandsGroup(characters, comma: cursor) {
                    // Thousands separator: "1,000".
                } else if current == ".", seenPoint == false, cursor + 1 < characters.count,
                          characters[cursor + 1].isASCII, characters[cursor + 1].isNumber {
                    seenPoint = true
                    digits.append(".")
                } else {
                    break
                }
                cursor += 1
            }
            guard var value = Double(digits) else { index = cursor; continue }
            var precision = 0.5 * pow(10, -Double(decimals))
            var isPercent = false
            var end = cursor
            if cursor < characters.count {
                let suffix = characters[cursor]
                let multiplier: Double? = switch suffix {
                case "K": 1_000
                case "M": 1_000_000
                case "B": 1_000_000_000
                case "T": 1_000_000_000_000
                default: nil
                }
                let suffixIsWordEnd = cursor + 1 >= characters.count || characters[cursor + 1].isLetter == false
                if let multiplier, suffixIsWordEnd {
                    value *= multiplier
                    precision *= multiplier
                    end = cursor + 1
                } else if suffix == "%" {
                    isPercent = true
                    end = cursor + 1
                }
            }
            result.append(Number(value: value, isPercent: isPercent, precision: precision,
                                 text: String(characters[index..<end])))
            index = end
        }
        return result
    }

    /// `true` when exactly three digits follow the comma ("1,000" but not "1,2" or "3, 4").
    static func isThousandsGroup(_ characters: [Character], comma: Int) -> Bool {
        let start = comma + 1
        let end = comma + 4
        guard end <= characters.count,
              characters[start..<end].allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        return end == characters.count || !(characters[end].isASCII && characters[end].isNumber)
    }
}
