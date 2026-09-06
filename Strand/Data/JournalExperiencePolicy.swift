import Foundation

enum JournalAnswer: Equatable, Sendable {
    case boolean(Bool)
    case number(Double)

    var isValid: Bool {
        switch self {
        case .boolean: true
        case .number(let number): number.isFinite && number >= 0 && number <= JournalNumberInput.maximum
        }
    }
}

/// The day and original answers belong to this editing session, even across midnight or a parent refresh.
struct JournalDraft: Equatable, Sendable {
    let day: String
    private(set) var baseline: [String: JournalAnswer]
    private(set) var answers: [String: JournalAnswer]

    init(day: String, answers: [String: JournalAnswer]) {
        self.day = day
        let valid = answers.filter { $0.value.isValid }
        self.baseline = valid
        self.answers = valid
    }

    var changedKeys: [String] {
        Set(baseline.keys).union(answers.keys).filter { baseline[$0] != answers[$0] }.sorted()
    }

    mutating func set(_ value: JournalAnswer?, for key: String) {
        guard !key.isEmpty, value?.isValid != false else { return }
        answers[key] = value
    }

    @discardableResult
    mutating func copyMissing(from previous: [String: JournalAnswer], activeKeys: Set<String>) -> Int {
        var count = 0
        for key in activeKeys.sorted() where answers[key] == nil {
            if let value = previous[key], value.isValid {
                answers[key] = value
                count += 1
            }
        }
        return count
    }

    mutating func acceptSavedAnswers(_ values: [String: JournalAnswer]) {
        let valid = values.filter { $0.value.isValid }
        baseline = valid
        answers = valid
    }
}

enum JournalNumberInput {
    static let maximum = 1_000_000_000.0
    enum Result: Equatable { case empty, value(Double), invalid }

    /// Decimal-pad input has no grouping or exponent syntax. Ambiguous separators fail visibly.
    static func parse(_ text: String, locale: Locale = .current) -> Result {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }
        let separator = locale.decimalSeparator ?? "."
        let pieces = text.components(separatedBy: separator)
        guard pieces.count <= 2, pieces.contains(where: { !$0.isEmpty }) else { return .invalid }
        var normalized: [String] = []
        for piece in pieces {
            var digits = ""
            for character in piece {
                guard let digit = character.wholeNumberValue, (0...9).contains(digit) else { return .invalid }
                digits.append(String(digit))
            }
            normalized.append(digits)
        }
        guard let number = Double(normalized.joined(separator: ".")), number.isFinite,
              number >= 0, number <= maximum else { return .invalid }
        return .value(number)
    }

    static func format(_ value: Double, locale: Locale = .current) -> String {
        guard value.isFinite else { return "" }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 12
        return formatter.string(from: NSNumber(value: value)) ?? ""
    }
}

enum JournalExperiencePolicy {
    static func visibleKeys(catalogKeys: [String], activeKeys: Set<String>) -> [String] {
        catalogKeys.filter { activeKeys.contains($0) }
    }

    static func day(offset: Int, from date: Date = .now, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -offset, to: date) ?? date
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let components = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 1970, components.month ?? 1, components.day ?? 1)
    }
}
