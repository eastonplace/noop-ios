#if DEBUG
import Foundation
import WhoopStore

/// DEBUG-only demo journal answers. Explicit Yes and No answers across the last weeks of the demo history, laid out
/// against the seeded recovery so Coach's journal comparisons have enough matched days to render: low-recovery days
/// carry more "Yes" for alcohol and late caffeine. A few days are left unlogged on purpose, so "not logged" is
/// visible too. Pure and deterministic; it draws no random numbers, so the rest of the seed is unchanged.
enum AppleDemoJournalFixture {
    static let alcohol = "Did you drink any alcohol?"
    static let caffeine = "Did you have caffeine late in the day?"
    static let stress = "Did you feel stressed?"

    static func entries(days: [(day: String, recovery: Double)], window: Int = 40) -> [JournalEntry] {
        let recent = Array(days.sorted { $0.day < $1.day }.suffix(window))
        guard !recent.isEmpty else { return [] }
        let count = recent.count
        // Rank 0 is the lowest recovery. Ties break on the date, so the layout never depends on the sort's stability.
        let ranked = recent.indices.sorted {
            (recent[$0].recovery, recent[$0].day) < (recent[$1].recovery, recent[$1].day)
        }
        var rank: [Int: Int] = [:]
        for (position, index) in ranked.enumerated() { rank[index] = position }

        var rows: [JournalEntry] = []
        for (index, entry) in recent.enumerated() {
            if index % 9 == 4 { continue }   // left unlogged
            let p = rank[index] ?? 0
            let low = Double(p) < Double(count) * 0.4
            let alcoholYes = low ? p % 3 == 0 : (p >= count / 2 && p % 10 == 5)
            let caffeineYes = Double(p) < Double(count) * 0.6 ? p % 3 == 1 : p % 7 == 0
            let stressYes = Double(p) < Double(count) * 0.7 && p % 4 == 2
            rows.append(JournalEntry(day: entry.day, question: alcohol, answeredYes: alcoholYes, notes: nil))
            rows.append(JournalEntry(day: entry.day, question: caffeine, answeredYes: caffeineYes, notes: nil))
            rows.append(JournalEntry(day: entry.day, question: stress, answeredYes: stressYes, notes: nil))
        }
        return rows
    }
}
#endif
