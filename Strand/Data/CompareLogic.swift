import Foundation
import StrandAnalytics
import StrandDesign

// MARK: - Compare: windows, lags and the readable result
//
// The arithmetic under the Compare screen, kept apart from the view so it can be tested without drawing. Series are
// (day key, value) rows, ascending. Every window and lag is read off the day keys as plain day numbers (`ExploreDayKey`),
// so it does not depend on the device's calendar, locale or time zone.

enum CompareLogic {
    typealias Row = (day: String, value: Double)

    /// The rows over the trailing `days` days, counted back from the series' own latest day (not from today), so a
    /// stale-but-present series still shows its window. nil `days` is everything. A row whose key is not a real day is
    /// dropped from a windowed slice.
    static func slice(_ rows: [Row], days: Int?) -> [Row] {
        guard let days else { return rows }
        guard let lastKey = rows.last?.day, let last = ExploreDayKey.dayNumber(for: lastKey) else { return [] }
        let cutoff = last - (days - 1)
        return rows.filter { row in ExploreDayKey.dayNumber(for: row.day).map { $0 >= cutoff } ?? false }
    }

    /// The reading on a day key, or nil when the series has none that day (the latest when a day repeats).
    static func value(in rows: [Row], onDay key: String) -> Double? {
        rows.last { $0.day == key }?.value
    }

    /// A's readings paired with B's `lagDays` later: 0 is the same day, 1 is A today against B the next morning. A day
    /// with a reading on only one side has no pair.
    static func lagPairs(_ a: [Row], _ b: [Row], lagDays: Int) -> [(x: Double, y: Double)] {
        var byDay: [Int: Double] = [:]
        for row in b {
            if let day = ExploreDayKey.dayNumber(for: row.day) { byDay[day] = row.value }
        }
        return a.compactMap { row in
            guard let day = ExploreDayKey.dayNumber(for: row.day), let y = byDay[day + lagDays] else { return nil }
            return (row.value, y)
        }
    }

    /// B's mean on the days A was at or above its own median, against its mean on the days A was below it. nil when
    /// either side is empty or there are fewer than two pairs.
    static func splitMeans(_ pairs: [(x: Double, y: Double)]) -> (high: Double, low: Double)? {
        guard pairs.count >= 2 else { return nil }
        let median = ComparisonEngine.stat(pairs.map(\.x)).median
        let high = pairs.filter { $0.x >= median }.map(\.y)
        let low = pairs.filter { $0.x < median }.map(\.y)
        guard !high.isEmpty, !low.isEmpty else { return nil }
        return (high.reduce(0, +) / Double(high.count), low.reduce(0, +) / Double(low.count))
    }

    /// Which way two series move together, in words the screen can localise. A relationship below "moderate" (the
    /// shared `CorrelationStrength` rule, applied to r as printed) is no link worth a sentence.
    enum Link: Equatable {
        case none
        case rises
        case falls

        init(r: Double) {
            guard CorrelationStrength(r: r).isNotable else { self = .none; return }
            self = r > 0 ? .rises : .falls
        }
    }

    /// The colours for a selection, in pick order: a metric with a canonical colour (Recovery blue, Sleep slate) keeps it
    /// unless an earlier metric with the same canonical colour already took it; every other metric takes the first colour
    /// of the palette no line has, so no two lines share one. The canonical colours are claimed first, so a metric that
    /// merely comes earlier in the list never takes Recovery's blue from Recovery.
    static func colorIndices(keys: [String], canonical: (String) -> Int?, paletteCount: Int) -> [Int] {
        var used = Set<Int>()
        var result = [Int?](repeating: nil, count: keys.count)
        for (index, key) in keys.enumerated() {
            if let wanted = canonical(key), (0..<paletteCount).contains(wanted), !used.contains(wanted) {
                used.insert(wanted)
                result[index] = wanted
            }
        }
        for index in keys.indices where result[index] == nil {
            let free = (0..<paletteCount).first { !used.contains($0) } ?? (index % max(paletteCount, 1))
            used.insert(free)
            result[index] = free
        }
        return result.map { $0 ?? 0 }
    }
}
