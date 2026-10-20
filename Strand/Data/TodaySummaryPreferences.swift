import Foundation

/// The existing Today scores. Selection changes presentation only; score calculation and storage stay unchanged.
enum TodaySummaryMetric: String, CaseIterable, Identifiable {
    case recovery, strain, sleep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recovery: String(localized: "Recovery")
        case .strain: String(localized: "Strain")
        case .sleep: String(localized: "Sleep")
        }
    }
}

enum TodaySummaryPreferences {
    /// Separate from the retired Key Metrics layout and the Health Monitor selection.
    static let selectionKey = "today.summaryMetrics"
    static let defaultSelection: [TodaySummaryMetric] = [.recovery, .strain, .sleep]

    static func decodeEnabled(_ raw: String) -> [TodaySummaryMetric] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultSelection }
        let ids: [String]
        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            ids = decoded
        } else {
            ids = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        var seen = Set<TodaySummaryMetric>()
        let selection = ids.compactMap(TodaySummaryMetric.init(rawValue:)).filter { seen.insert($0).inserted }
        // Corrupt or empty stored selection must leave at least one real score visible.
        return selection.isEmpty ? [.recovery] : selection
    }

    static func encode(_ metrics: [TodaySummaryMetric]) -> String {
        var seen = Set<TodaySummaryMetric>()
        let selection = metrics.filter { seen.insert($0).inserted }
        let ids = (selection.isEmpty ? [.recovery] : selection).map(\.rawValue)
        guard let data = try? JSONEncoder().encode(ids), let raw = String(data: data, encoding: .utf8) else {
            return ids.joined(separator: ",")
        }
        return raw
    }

    /// Select the already-built values by stable identity. Values, missing states, and provenance pass through intact.
    static func orderedValues<Value>(_ values: [Value], raw: String, id: (Value) -> String) -> [Value] {
        decodeEnabled(raw).compactMap { metric in values.first { id($0) == metric.rawValue } }
    }
}
