import Foundation

/// A deliberately small, local grammar. Suggestions are evidence for a review form, never writes.
/// Catalog keys remain opaque; narrative aliases use the original question, not a renamed label.
public enum JournalEntryParser {
    public static let maximumInputBytes = 4_000
    public static let maximumFields = 256

    public enum Kind: Equatable, Sendable {
        case boolean
        case quantity(unit: String?)
    }

    public struct Field: Equatable, Sendable, Identifiable {
        public let canonical: String
        public let display: String
        public let kind: Kind
        public var id: String { canonical }

        public init(canonical: String, display: String, kind: Kind) {
            self.canonical = canonical
            self.display = display
            self.kind = kind
        }
    }

    public enum Value: Equatable, Sendable {
        case boolean(Bool)
        case quantity(Double)
    }

    public struct Suggestion: Equatable, Sendable, Identifiable {
        public let canonical: String
        public var value: Value
        public let excerpt: String
        public var id: String { canonical }

        public init(canonical: String, value: Value, excerpt: String) {
            self.canonical = canonical
            self.value = value
            self.excerpt = excerpt
        }
    }

    public struct Draft: Equatable, Sendable {
        public let suggestions: [Suggestion]
        public let unmatched: [String]
        public let conflictingFields: [String]
        public let exceedsLimit: Bool
    }

    public static func parse(_ text: String, fields: [Field]) -> Draft {
        guard text.utf8.count <= maximumInputBytes, fields.count <= maximumFields else {
            return Draft(suggestions: [], unmatched: [text], conflictingFields: [], exceedsLimit: true)
        }
        var suggestions: [Suggestion] = []
        var unmatched: [String] = []
        var conflicting: [String] = []
        for clause in clauses(text) {
            let candidates = fields.compactMap { candidate(clause, field: $0) }
            // Multiple catalog items can describe the same habit. Never pick one by array order.
            guard candidates.count == 1, let candidate = candidates.first else {
                unmatched.append(clause)
                continue
            }
            let next = candidate.suggestion
            if conflicting.contains(next.canonical) {
                unmatched.append(clause)
            } else if let index = suggestions.firstIndex(where: { $0.canonical == next.canonical }) {
                if suggestions[index].value != next.value {
                    conflicting.append(next.canonical)
                    unmatched.append(suggestions.remove(at: index).excerpt)
                    unmatched.append(clause)
                } else if candidate.hasUnmatchedDetails {
                    unmatched.append(clause)
                }
            } else {
                suggestions.append(next)
                if candidate.hasUnmatchedDetails { unmatched.append(clause) }
            }
        }
        return Draft(suggestions: suggestions, unmatched: unmatched,
                     conflictingFields: conflicting, exceedsLimit: false)
    }

    private struct Candidate {
        let suggestion: Suggestion
        let hasUnmatchedDetails: Bool
    }

    private static func candidate(_ clause: String, field: Field) -> Candidate? {
        guard !field.canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let separator = clause.firstIndex(where: { $0 == ":" || $0 == "=" }) {
            let label = key(String(clause[..<separator]))
            let aliases = Set([key(field.canonical), key(field.display), labelWithoutUnit(field)])
            guard aliases.contains(label), !label.isEmpty else { return nil }
            let rawValue = String(clause[clause.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value: Value?
            switch field.kind {
            case .boolean:
                switch narrative(rawValue) {
                case "yes", "true": value = .boolean(true)
                case "no", "false": value = .boolean(false)
                default: value = nil
                }
            case .quantity(let unit):
                value = quantity(rawValue, unit: unit).map(Value.quantity)
            }
            return value.map { Candidate(suggestion: .init(canonical: field.canonical, value: $0, excerpt: clause), hasUnmatchedDetails: false) }
        }

        guard let concept = concept(for: field) else { return nil }
        let normalized = narrative(clause)
        switch field.kind {
        case .quantity(let unit):
            guard let raw = narrativeQuantity(normalized, concept: concept),
                  let value = quantity(raw, unit: unit) else { return nil }
            return Candidate(suggestion: .init(canonical: field.canonical, value: .quantity(value), excerpt: clause), hasUnmatchedDetails: false)
        case .boolean:
            if let yes = boolean(normalized, concept: concept) {
                return Candidate(suggestion: .init(canonical: field.canonical, value: .boolean(yes), excerpt: clause), hasUnmatchedDetails: false)
            }
            // Occurrence is supported, but duration / zone / distance has no journal-habit field.
            // Keep the original clause visible so those details cannot silently disappear.
            if concept == .workout,
               matches(normalized, #"^(?:i )?(?:ran|cycled|swam|walked|worked out|exercised|lifted weights) for \d+(?:\.\d+)? (?:minutes?|hours?)(?: in zone [1-5])?$"#) {
                return Candidate(suggestion: .init(canonical: field.canonical, value: .boolean(true), excerpt: clause), hasUnmatchedDetails: true)
            }
            return nil
        }
    }

    private enum Concept: String {
        case caffeine, lateCaffeine, creatine, magnesium, alcohol, workout, stress, sauna, screenInBed, lateMeal, sharedBed, sick, reading
    }

    private static func concept(for field: Field) -> Concept? {
        let canonical = labelWithoutUnit(field)
        switch canonical {
        case "caffeine", "coffee", "did you have caffeine", "did you consume caffeine", "did you drink coffee": return .caffeine
        case "did you have caffeine late in the day", "late caffeine", "caffeine late in the day": return .lateCaffeine
        case "creatine", "did you take creatine": return .creatine
        case "magnesium", "did you take magnesium": return .magnesium
        case "alcohol", "did you drink any alcohol", "did you drink alcohol": return .alcohol
        case "workout", "exercise", "did you exercise", "did you work out", "did you workout": return .workout
        case "stress", "did you feel stressed": return .stress
        case "sauna", "did you use a sauna": return .sauna
        case "did you view a screen in bed": return .screenInBed
        case "did you eat close to bedtime": return .lateMeal
        case "did you share your bed": return .sharedBed
        case "did you feel sick or ill": return .sick
        case "did you read before bed": return .reading
        default: return nil
        }
    }

    private static func boolean(_ text: String, concept: Concept) -> Bool? {
        let positive: String
        let negative: String
        switch concept {
        case .creatine, .magnesium:
            positive = #"(?:took|had) (?:my )?"# + concept.rawValue
            negative = #"(?:did not take|did not have|skipped) (?:my )?"# + concept.rawValue
        case .caffeine:
            positive = #"(?:had|drank|consumed) (?:some )?(?:caffeine|coffee)"#
            negative = #"(?:(?:had|drank|consumed) no|did not (?:have|drink|consume)) (?:caffeine|coffee)"#
        case .lateCaffeine:
            positive = #"(?:had|drank|consumed) (?:caffeine|coffee) late in the day"#
            negative = #"(?:(?:had|drank|consumed) no|did not (?:have|drink|consume)) (?:caffeine|coffee) late in the day"#
        case .alcohol:
            positive = #"(?:had|drank|consumed) (?:some )?alcohol"#
            negative = #"(?:(?:had|drank|consumed) no|did not (?:have|drink|consume)) alcohol"#
        case .workout:
            positive = #"(?:worked out|exercised|trained|ran|cycled|swam|lifted weights|went for a run|did a workout)"#
            negative = #"(?:did not (?:work out|exercise|train|run|cycle|swim)|skipped (?:my )?workout)"#
        case .stress:
            positive = #"(?:felt stressed|was stressed)"#
            negative = #"(?:did not feel stressed|was not stressed)"#
        case .sauna:
            positive = #"(?:used (?:a |the )?sauna|went to (?:a |the )?sauna)"#
            negative = #"did not use (?:a |the )?sauna"#
        case .screenInBed:
            positive = #"(?:viewed|used) (?:a |my )?screen in bed"#
            negative = #"did not (?:view|use) (?:a |my )?screen in bed"#
        case .lateMeal:
            positive = #"ate close to bedtime"#
            negative = #"did not eat close to bedtime"#
        case .sharedBed:
            positive = #"shared (?:my |a |the )?bed"#
            negative = #"did not share (?:my |a |the )?bed"#
        case .sick:
            positive = #"(?:felt|was) (?:sick|ill)"#
            negative = #"(?:did not feel|was not) (?:sick|ill)"#
        case .reading:
            positive = #"read before bed"#
            negative = #"did not read before bed"#
        }
        if matches(text, "^(?:i )?" + negative + "$") { return false }
        if matches(text, "^(?:i )?" + positive + "$") { return true }
        return nil
    }

    private static func narrativeQuantity(_ text: String, concept: Concept) -> String? {
        let substance: String
        let action: String
        switch concept {
        case .caffeine: substance = "(?:caffeine|coffee)"; action = "(?:had|drank|consumed)"
        case .creatine, .magnesium: substance = concept.rawValue; action = "(?:took|had)"
        case .alcohol: substance = "alcohol"; action = "(?:had|drank|consumed)"
        default: return nil
        }
        return captures(text, "^(?:i )?" + action + " (.+?) (?:of )?" + substance + "$")?.first
    }

    private static func quantity(_ text: String, unit expected: String?) -> Double? {
        guard let parts = captures(narrative(text), #"^(\d+(?:\.\d+)?|zero|one|two|three|four|five|six|seven|eight|nine|ten|half)\s*([a-z]+)?$"#) else { return nil }
        let words: [String: Double] = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "half": 0.5]
        guard let number = Double(parts[0]) ?? words[parts[0]], number.isFinite, number >= 0 else { return nil }
        let supplied = unit(parts.count > 1 ? parts[1] : "")
        let target = unit(expected ?? "")
        let value: Double
        if supplied == target { value = number }
        else {
            switch (supplied, target) {
            case ("g", "mg"): value = number * 1_000
            case ("mg", "g"): value = number / 1_000
            case ("l", "ml"): value = number * 1_000
            case ("ml", "l"): value = number / 1_000
            case ("hours", "minutes"): value = number * 60
            case ("minutes", "hours"): value = number / 60
            default: return nil
            }
        }
        return value.isFinite && value <= 1_000_000_000 ? value : nil
    }

    private static func unit(_ value: String) -> String {
        switch key(value) {
        case "milligram", "milligrams", "mg": return "mg"
        case "gram", "grams", "g": return "g"
        case "milliliter", "milliliters", "millilitre", "millilitres", "ml": return "ml"
        case "liter", "liters", "litre", "litres", "l": return "l"
        case "cup", "cups": return "cups"
        case "minute", "minutes", "min", "mins": return "minutes"
        case "hour", "hours", "hr", "hrs", "h": return "hours"
        case "unit", "units": return "units"
        default: return key(value)
        }
    }

    private static func labelWithoutUnit(_ field: Field) -> String {
        var label = field.canonical
        if case .quantity(let unit) = field.kind, let unit, !unit.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: unit)
            label = label.replacingOccurrences(of: "\\s*\\(\\s*" + escaped + "\\s*\\)\\s*$", with: "", options: [.regularExpression, .caseInsensitive])
            label = label.replacingOccurrences(of: "\\s+" + escaped + "\\s*$", with: "", options: [.regularExpression, .caseInsensitive])
        }
        return key(label)
    }

    private static func clauses(_ text: String) -> [String] {
        let separated = text.replacingOccurrences(
            of: #"[;\n,]+|(?<!\d)[.!](?!\d)|(?<=\d)[.!](?!\d)|\s+\b(?:and|but|then)\b\s+"#,
            with: "\n", options: [.regularExpression, .caseInsensitive])
        return separated.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func narrative(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "didn't", with: "did not")
            .replacingOccurrences(of: "wasn't", with: "was not")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func key(_ text: String) -> String {
        narrative(text).trimmingCharacters(in: CharacterSet(charactersIn: " ?.!"))
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func captures(_ text: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: text) else { return "" }
            return String(text[range])
        }
    }
}
