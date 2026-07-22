import Foundation

/// The single scheduling authority for the alarm UI and actuation path.
public enum SmartAlarmSchedule {
    public static func nextDate(
        minutes: Int,
        weekdays: Set<Int>,
        after now: Date = Date(),
        calendar inputCalendar: Calendar = .current
    ) -> Date? {
        let calendar = inputCalendar
        let valid = weekdays.filter { (1...7).contains($0) }
        guard weekdays.isEmpty || !valid.isEmpty else { return nil }

        let normalized = ((minutes % 1_440) + 1_440) % 1_440
        let hour = normalized / 60
        let minute = normalized % 60

        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now),
                  let searchStart = calendar.date(byAdding: .second, value: -1, to: calendar.startOfDay(for: day)),
                  let candidate = calendar.nextDate(
                    after: searchStart,
                    matching: DateComponents(hour: hour, minute: minute, second: 0),
                    matchingPolicy: .nextTime,
                    repeatedTimePolicy: .first,
                    direction: .forward
                  ),
                  calendar.isDate(candidate, inSameDayAs: day),
                  candidate > now
            else { continue }

            if weekdays.isEmpty || valid.contains(calendar.component(.weekday, from: candidate)) {
                return candidate
            }
        }
        return nil
    }
}
