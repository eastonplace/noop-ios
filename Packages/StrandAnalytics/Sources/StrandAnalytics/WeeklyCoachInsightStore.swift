import Foundation

// WeeklyCoachInsightStore.swift — the one-line weekly takeaway the on-device Coach writes
// and the Trends weekly readout reads. Foundation-only so both app targets share it.
// Keyed by the Trends week's Monday ("yyyy-MM-dd", same as `WeeklyDigest.weekStart`),
// so an insight is only ever shown against the week it was written for.

public struct WeeklyCoachInsight: Codable, Equatable, Sendable {
    public let weekStart: String
    public let text: String
    public let generatedAt: Date

    public init(weekStart: String, text: String, generatedAt: Date) {
        self.weekStart = weekStart
        self.text = text
        self.generatedAt = generatedAt
    }
}

public enum WeeklyCoachInsightStore {
    public static let maxLength = 220
    static let defaultsKey = "noop.weeklyCoachInsight.v1"

    /// Tidy raw model output into a short insight, or nil when there is nothing usable
    /// (empty, whitespace, or a refusal).
    public static func clean(_ raw: String) -> String? {
        var text = raw
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "#", with: "")
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " -*•\"“”"))
        guard !text.isEmpty else { return nil }
        let lowered = text.lowercased()
        let refusals = ["i can't", "i cannot", "i can’t", "i'm sorry", "i’m sorry", "sorry,",
                        "as an ai", "i'm unable", "i’m unable", "i am unable", "unable to"]
        if refusals.contains(where: { lowered.hasPrefix($0) }) { return nil }
        if text.count > maxLength {
            let head = String(text.prefix(maxLength))
            // Prefer ending on a full sentence, else on a word with an ellipsis.
            if let end = head.lastIndex(where: { ".!?".contains($0) }),
               head.distance(from: head.startIndex, to: end) >= maxLength / 3 {
                text = String(head[...end])
            } else if let space = head.lastIndex(of: " ") {
                text = String(head[..<space]) + "…"
            } else {
                text = head + "…"
            }
        }
        return text
    }

    @discardableResult
    public static func save(weekStart: String, rawText: String, now: Date = Date(),
                            defaults: UserDefaults = .standard) -> Bool {
        guard let text = clean(rawText), !weekStart.isEmpty else { return false }
        let value = WeeklyCoachInsight(weekStart: weekStart, text: text, generatedAt: now)
        guard let data = try? JSONEncoder().encode(value) else { return false }
        defaults.set(data, forKey: defaultsKey)
        return true
    }

    public static func load(defaults: UserDefaults = .standard) -> WeeklyCoachInsight? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(WeeklyCoachInsight.self, from: data)
    }

    /// The stored text, only when it belongs to `weekStart` and is non-empty.
    public static func text(forWeekStart weekStart: String, defaults: UserDefaults = .standard) -> String? {
        guard let value = load(defaults: defaults), value.weekStart == weekStart,
              !value.text.isEmpty else { return nil }
        return value.text
    }

    /// True when the Coach still needs to write this week's insight.
    public static func needsInsight(forWeekStart weekStart: String, defaults: UserDefaults = .standard) -> Bool {
        text(forWeekStart: weekStart, defaults: defaults) == nil
    }

    public static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
