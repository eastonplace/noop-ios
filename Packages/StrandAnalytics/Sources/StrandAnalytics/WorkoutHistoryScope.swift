import Foundation
import WhoopStore

/// A presentation filter only. No records are deleted or moved.
public enum WorkoutHistoryScope: String, CaseIterable, Sendable {
    case current, archived

    public static func filter(_ rows: [WorkoutRow], scope: Self,
                              now: Date = Date(), calendar: Calendar = .current) -> [WorkoutRow] {
        guard let boundary = calendar.date(byAdding: .day, value: -90, to: calendar.startOfDay(for: now)) else { return rows }
        let cutoff = Int(boundary.timeIntervalSince1970)
        return rows.filter { scope == .current ? $0.startTs >= cutoff : $0.startTs < cutoff }
    }
}
