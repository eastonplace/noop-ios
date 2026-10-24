import Foundation

/// A saved civil-time wake schedule. Firmware still receives only one nearest endpoint.
public struct WakeAlarm: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var enabled: Bool
    public var minutes: Int
    /// Empty means every day; Calendar weekday numbers are 1 = Sunday ... 7 = Saturday.
    public var weekdays: Set<Int>
    public var mode: SmartAlarmEvaluator.Mode

    public init(id: UUID = UUID(), enabled: Bool = true, minutes: Int = 420,
                weekdays: Set<Int> = [], mode: SmartAlarmEvaluator.Mode = .exactTime) {
        self.id = id
        self.enabled = enabled
        self.minutes = ((minutes % 1_440) + 1_440) % 1_440
        self.weekdays = weekdays
        self.mode = mode
    }

    public var normalized: Self {
        Self(id: id, enabled: enabled, minutes: minutes, weekdays: weekdays, mode: mode)
    }
}

public enum WakeAlarmPlan {
    /// At most 35 weekday requests, leaving room for the app's other reminders.
    public static let maximumAlarms = 5

    public struct Occurrence: Equatable, Sendable {
        public let alarm: WakeAlarm
        public let date: Date
    }

    public struct Backup: Equatable, Sendable {
        public let alarmID: UUID
        public let minutes: Int
        public let weekday: Int?
        public var suffix: String { "\(alarmID.uuidString.lowercased())-d\(weekday ?? 0)" }
    }

    public static func next(in alarms: [WakeAlarm], after now: Date = Date(),
                            calendar: Calendar = .current) -> Occurrence? {
        // Keep saved order for simultaneous alarms: one strap buzz represents that shared endpoint.
        alarms.filter(\.enabled).compactMap { alarm -> Occurrence? in
            SmartAlarmSchedule.nextDate(minutes: alarm.minutes, weekdays: alarm.weekdays,
                                        after: now, calendar: calendar)
                .map { Occurrence(alarm: alarm, date: $0) }
        }.min { $0.date < $1.date }
    }

    public static func backups(for alarms: [WakeAlarm]) -> [Backup] {
        alarms.prefix(maximumAlarms).filter(\.enabled).flatMap { alarm -> [Backup] in
            if alarm.weekdays.isEmpty {
                return [Backup(alarmID: alarm.id, minutes: alarm.minutes, weekday: nil)]
            }
            return alarm.weekdays.filter { (1...7).contains($0) }.sorted().map {
                Backup(alarmID: alarm.id, minutes: alarm.minutes, weekday: $0)
            }
        }
    }

    public static func normalized(_ alarms: [WakeAlarm]) -> [WakeAlarm] {
        var seen = Set<UUID>()
        return Array(alarms.filter { seen.insert($0.id).inserted }.prefix(maximumAlarms)).map(\.normalized)
    }
}

public enum WakeAlarmPersistence {
    public static let key = "behavior.wakeAlarms.v1"
    /// A stable identity lets existing background/evidence work recognize the migrated alarm.
    public static let legacyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    public static func load(from defaults: UserDefaults) -> [WakeAlarm] {
        if let data = defaults.data(forKey: key),
           let alarms = try? JSONDecoder().decode([WakeAlarm].self, from: data) {
            return WakeAlarmPlan.normalized(alarms)
        }
        let alarm = WakeAlarm(
            id: legacyID,
            enabled: defaults.object(forKey: "behavior.smartAlarmEnabled") as? Bool ?? false,
            minutes: defaults.object(forKey: "behavior.smartAlarmMinutes") as? Int ?? 420,
            weekdays: Set((defaults.array(forKey: "behavior.smartAlarmWeekdays") as? [Int] ?? [])
                .filter { (1...7).contains($0) }),
            mode: SmartAlarmEvaluator.Mode(rawValue: defaults.string(forKey: "behavior.smartAlarmMode") ?? "")
                ?? .exactTime
        )
        // Retain unreadable data for recovery until an explicit edit replaces it.
        if defaults.data(forKey: key) == nil { save([alarm], to: defaults) }
        return [alarm]
    }

    public static func save(_ alarms: [WakeAlarm], to defaults: UserDefaults) {
        let alarms = WakeAlarmPlan.normalized(alarms)
        guard let data = try? JSONEncoder().encode(alarms) else { return }
        defaults.set(data, forKey: key)
        // Keep the legacy preference surface readable, without allowing deletion to resurrect it.
        defaults.set(alarms.first?.enabled ?? false, forKey: "behavior.smartAlarmEnabled")
        if let first = alarms.first {
            defaults.set(first.minutes, forKey: "behavior.smartAlarmMinutes")
            defaults.set(first.weekdays.sorted(), forKey: "behavior.smartAlarmWeekdays")
            defaults.set(first.mode.rawValue, forKey: "behavior.smartAlarmMode")
        }
    }
}

/// Generation-scoped replacement of phone backups. Restore only times that still belong to the current
/// configuration, using the new generation's IDs so cancelled work can clean up its own requests safely.
public enum WakeAlarmBackupReplacement {
    public enum Outcome: Equatable, Sendable { case scheduled, insufficientCapacity, failed, superseded }

    @MainActor
    public static func replace<Request>(
        existing: [Request], proposed: [Request], otherCount: Int,
        identifier: (Request) -> String, matches: (Request, Request) -> Bool,
        isCurrent: () -> Bool, remove: ([String]) -> Void,
        add: (Request) async throws -> Void
    ) async -> Outcome {
        guard isCurrent() else { return .superseded }
        let proposedIDs = proposed.map(identifier)
        let compatible = existing.filter { old in proposed.contains { matches(old, $0) } }
        let obsolete = existing.filter { old in !proposed.contains { matches(old, $0) } }
        // A deleted or edited time must never remain as a surprising stale alarm, even on failure.
        remove(obsolete.map(identifier))
        guard otherCount + proposed.count <= 64 else { return .insufficientCapacity }

        let mustFreeCapacity = otherCount + compatible.count + proposed.count > 64
        if mustFreeCapacity { remove(compatible.map(identifier)) }
        do {
            for request in proposed {
                guard isCurrent() else { throw CancellationError() }
                try await add(request)
            }
            guard isCurrent() else { throw CancellationError() }
        } catch {
            remove(proposedIDs)
            guard isCurrent() else { return .superseded }
            if mustFreeCapacity {
                // Restore only compatible old times. Use the current generation's request values/IDs,
                // so a cancellation during a restore cannot clean up a successor's requests.
                for request in proposed where compatible.contains(where: { matches($0, request) }) {
                    guard isCurrent() else { remove(proposedIDs); return .superseded }
                    try? await add(request)
                    guard isCurrent() else { remove(proposedIDs); return .superseded }
                }
            }
            return .failed
        }
        remove(compatible.map(identifier))
        return .scheduled
    }
}
