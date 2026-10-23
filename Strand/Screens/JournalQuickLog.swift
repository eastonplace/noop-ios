import Foundation
import SwiftUI
import WhoopStore

/// The rules of the one-page Journal's grid, kept apart from the views so each can be tested on its own:
/// what a tap does, how an amount reads, which answers "Mark the rest No" writes, and how an imported
/// answer and a native tap combine into the one answer the page shows.
enum JournalQuickLog {
    // MARK: Values

    /// One day's answers: yes/no per question, plus the amount for the questions that carry one.
    struct DayValues: Equatable {
        var answers: [String: Bool]
        var numeric: [String: Double]

        init(answers: [String: Bool] = [:], numeric: [String: Double] = [:]) {
            self.answers = answers
            self.numeric = numeric
        }

        func isAnswered(_ question: String) -> Bool {
            answers[question] != nil || numeric[question] != nil
        }
    }

    /// The answers on `day` from a list of journal rows (imported or native).
    static func values(from entries: [JournalEntry], day: String) -> DayValues {
        var values = DayValues()
        for entry in entries where entry.day == day {
            values.answers[entry.question] = entry.answeredYes
            if let amount = entry.numericValue { values.numeric[entry.question] = amount }
        }
        return values
    }

    /// What the page shows and counts. An imported answer counts as answered and shows its value; a tap made
    /// here replaces it, question by question, exactly as the stored journal merges them (`Repository.mergeJournal`).
    static func merged(native: DayValues, imported: DayValues) -> DayValues {
        var result = imported
        for question in Set(native.answers.keys).union(native.numeric.keys) {
            result.answers[question] = native.answers[question]
            result.numeric[question] = native.numeric[question]
        }
        return result
    }

    // MARK: Tile state

    enum TileState: Equatable {
        case unanswered
        case yes
        case no
        case amount(Double)

        var isAnswered: Bool { self != .unanswered }
    }

    /// A counted question reads from its amount (a zero is an explicit No, and a No saved elsewhere reads as 0).
    /// A plain question reads from its answer.
    static func state(of question: String, hasAmount: Bool, in values: DayValues) -> TileState {
        if hasAmount {
            if let amount = values.numeric[question] ?? (values.answers[question] == false ? 0 : nil) {
                return amount > 0 ? .amount(amount) : .no
            }
            return values.answers[question] == true ? .yes : .unanswered
        }
        if let answer = values.answers[question] { return answer ? .yes : .no }
        if let amount = values.numeric[question] { return amount > 0 ? .yes : .no }
        return .unanswered
    }

    // MARK: Taps

    /// Yes, then No, then Yes again. A tap never returns a question to blank; that is the menu's "Clear".
    static func tapped(_ current: Bool?) -> Bool { current != true }

    /// One tap on a counted question adds one step.
    static func stepUp(_ current: Double?, step: Double) -> Double { max(0, current ?? 0) + step }

    /// The minus glyph takes one step off, down to 0 (an explicit No). nil when there is nothing to take off.
    static func stepDown(_ current: Double?, step: Double) -> Double? {
        guard let current, current > 0 else { return nil }
        return max(0, current - step)
    }

    // MARK: Amounts

    struct Unit: Equatable {
        let singular: String
        let plural: String
    }

    /// A counted question: how much one tap adds, and what it is counted in.
    struct Amount: Equatable {
        let step: Double
        let unit: Unit
    }

    /// "2", "2.5". Whole amounts never carry a decimal.
    static func formatAmount(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// "1 drink", "2 drinks", "20 min": the unit agrees with the amount.
    static func amountText(_ value: Double, unit: Unit) -> String {
        "\(formatAmount(value)) \(abs(value - 1) < 0.0001 ? unit.singular : unit.plural)"
    }

    /// A unit that reads the same either way ("min", "mg").
    static func fixedUnit(_ label: String) -> Unit { Unit(singular: label, plural: label) }

    /// Catalog unit labels come written in the plural ("units", "servings"). Known ones get a singular for an
    /// amount of 1; anything else (a custom "mg", "kcal") is shown as written.
    static func catalogUnit(_ label: String) -> Unit {
        let singulars = ["units": "unit", "servings": "serving", "drinks": "drink", "doses": "dose",
                         "cups": "cup", "glasses": "glass", "pills": "pill", "tablets": "tablet",
                         "capsules": "capsule", "hours": "hour", "sessions": "session"]
        guard let singular = singulars[label.lowercased()] else { return fixedUnit(label) }
        return Unit(singular: singular, plural: label)
    }

    /// The line under a tile's name: empty until answered, then "Yes", "No" or the amount.
    static func stateText(_ state: TileState, unit: Unit?) -> String {
        switch state {
        case .unanswered: return ""
        case .yes: return String(localized: "Yes")
        case .no: return String(localized: "No")
        case .amount(let value):
            guard let unit else { return String(localized: "Yes") }
            return amountText(value, unit: unit)
        }
    }

    // MARK: Writes

    /// One answer to store: a yes/no, or an amount (whose zero is an explicit No).
    enum Write: Equatable {
        case answer(question: String, yes: Bool)
        case amount(question: String, value: Double)

        var question: String {
            switch self {
            case .answer(let question, _), .amount(let question, _): return question
            }
        }
    }

    /// A question as the rules see it: its key, and whether it counts an amount.
    struct Target: Equatable {
        let question: String
        let hasAmount: Bool
    }

    /// "Mark the rest No": every question still blank becomes No, and a counted one becomes 0.
    static func markRest(_ targets: [Target], in values: DayValues) -> [Write] {
        targets.compactMap { target in
            guard state(of: target.question, hasAmount: target.hasAmount, in: values) == .unanswered else { return nil }
            return target.hasAmount ? .amount(question: target.question, value: 0)
                                    : .answer(question: target.question, yes: false)
        }
    }

    /// "Same as yesterday": the blanks that the earlier day answered, copied as they were. Nothing already
    /// answered is touched.
    static func copyFromEarlier(_ targets: [Target], current: DayValues, earlier: DayValues) -> [Write] {
        targets.compactMap { target in
            guard !current.isAnswered(target.question) else { return nil }
            if let value = earlier.numeric[target.question] {
                return .amount(question: target.question, value: value)
            }
            if let answer = earlier.answers[target.question] {
                return .answer(question: target.question, yes: answer)
            }
            return nil
        }
    }

    /// The count of answered questions, for "4 of 10".
    static func answeredCount(_ targets: [Target], in values: DayValues) -> Int {
        targets.filter { state(of: $0.question, hasAmount: $0.hasAmount, in: values).isAnswered }.count
    }

    /// The days with an answer, with the open day counted from what is on screen right now (a tap logs it, and
    /// clearing the last answer unlogs it) rather than from the last read.
    static func loggedDays(_ base: Set<String>, day: String, values: DayValues?) -> Set<String> {
        guard let values else { return base }
        var days = base
        if values.answers.isEmpty && values.numeric.isEmpty { days.remove(day) } else { days.insert(day) }
        return days
    }

    /// The line under a stack's name: "Log magnesium and sauna together". nil for a stack with nothing in it.
    static func stackSubtitle(names: [String]) -> String? {
        let lowered = names.map { $0.lowercased() }
        guard !lowered.isEmpty else { return nil }
        let list = ListFormatter.localizedString(byJoining: lowered)
        return lowered.count == 1 ? String(localized: "Log \(list)") : String(localized: "Log \(list) together")
    }

    /// The streak sentence under a finished day: "9 days in a row", or nothing for a first day.
    static func streakText(_ days: Int) -> String? {
        days > 1 ? String(localized: "\(days) days in a row") : nil
    }
}

// MARK: - Tiles

/// One question as a grid tile: its short name, its symbol and colour, and the amount it counts, if any.
struct JournalQuickLogTile: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: String
    let tint: Color
    let amount: JournalQuickLog.Amount?

    var target: JournalQuickLog.Target { .init(question: id, hasAmount: amount != nil) }

    init(item: JournalCatalogItem) {
        id = item.canonical
        name = coachingShortDisplayName(for: item)
        icon = coachingIcon(for: item)
        tint = coachingTint(for: item)
        amount = coachingQuantity(for: item)
    }

    /// The grid in one run: the active questions, in the order the groups always had (sleep, fuel, training,
    /// recovery, supplements), each group by its own sort order. The groups themselves are no longer shown.
    static func tiles(from items: [JournalCatalogItem], active: Set<String>) -> [JournalQuickLogTile] {
        let visible = active.isEmpty ? items : items.filter { active.contains($0.canonical) }
        let order = CoachingCheckInGroup.allCases
        return visible
            .sorted {
                let left = order.firstIndex(of: coachingPresentationGroup(for: $0)) ?? 0
                let right = order.firstIndex(of: coachingPresentationGroup(for: $1)) ?? 0
                return (left, $0.sortIndex, $0.display) < (right, $1.sortIndex, $1.display)
            }
            .map(JournalQuickLogTile.init(item:))
    }
}
