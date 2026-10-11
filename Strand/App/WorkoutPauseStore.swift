import Foundation
import StrandAnalytics
import WhoopStore

// MARK: - Pause persistence
//
// A paused workout has two lives, and each keeps its pauses in a small on-device store of its own, the way a recorded
// route does. Neither touches the workout database, so there is no schema change:
//
//   • `ActiveWorkoutPauseStore` holds the pauses of the workout in flight. It is written on every Pause and Resume, so a
//     workout paused when iOS ends the app is still paused, with its timer still frozen, when NOOP opens again.
//   • `WorkoutPauseStore` holds the pauses of a finished workout, keyed by the same natural key as its route
//     (start second + sport). The detail screen, the rescore pass and the Health write-back read it so a saved workout
//     keeps leaving its paused time out of its heart-rate numbers.

/// The pauses of the workout that is still running.
enum ActiveWorkoutPauseStore {
    static let defaultsKey = "noop.activeWorkout.pause"

    private struct Record: Codable {
        let sessionID: UUID
        let ledger: WorkoutPauseLedger
    }

    /// Persist the ledger for `sessionID`. Called on every toggle, which is rare, so it is written at once.
    static func store(_ ledger: WorkoutPauseLedger, sessionID: UUID, in defaults: UserDefaults = .standard) {
        guard ledger.hasPauses else {
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(Record(sessionID: sessionID, ledger: ledger)) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// The stored ledger when it belongs to `sessionID`; a ledger left by another session is ignored.
    static func load(sessionID: UUID, from defaults: UserDefaults = .standard) -> WorkoutPauseLedger? {
        guard let data = defaults.data(forKey: defaultsKey),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.sessionID == sessionID else { return nil }
        return record.ledger
    }

    static func clear(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}

/// The pauses of finished workouts, keyed like `RouteStore`.
enum WorkoutPauseStore {
    static let defaultsKey = "noop.workoutPauses"
    /// Newest kept, oldest evicted: keys lead with the start second.
    static let maxEntries = 400

    static func key(startTs: Int, sport: String) -> String { RouteStore.key(startTs: startTs, sport: sport) }

    static func encodeMap(_ map: [String: [WorkoutPauseLedger.Interval]]) -> Data? {
        try? JSONEncoder().encode(map)
    }

    /// A persisted map is untrusted: each entry goes back through the ledger so overlaps and bad numbers are dropped.
    static func decodeMap(_ data: Data?) -> [String: [WorkoutPauseLedger.Interval]] {
        guard let data, !data.isEmpty,
              let raw = try? JSONDecoder().decode([String: [WorkoutPauseLedger.Interval]].self, from: data) else {
            return [:]
        }
        return raw.compactMapValues { intervals in
            let clean = WorkoutPauseLedger(intervals: intervals).intervals
            return clean.isEmpty ? nil : clean
        }
    }

    static func loadMap(from defaults: UserDefaults = .standard) -> [String: [WorkoutPauseLedger.Interval]] {
        decodeMap(defaults.data(forKey: defaultsKey))
    }

    /// The pauses of the workout saved under this natural key, or nil when it had none.
    static func load(startTs: Int, sport: String, from defaults: UserDefaults = .standard) -> WorkoutPauseLedger? {
        loadMap(from: defaults)[key(startTs: startTs, sport: sport)].map { WorkoutPauseLedger(intervals: $0) }
    }

    /// The pauses of the workout that started at `startTs`, whatever its sport. For readers that hold only a time
    /// window (the heart-rate curve, the zone minutes); two workouts never share a start second in practice.
    static func load(startTs: Int, from defaults: UserDefaults = .standard) -> WorkoutPauseLedger? {
        let prefix = "\(startTs)|"
        guard let entry = loadMap(from: defaults).first(where: { $0.key.hasPrefix(prefix) }) else { return nil }
        return WorkoutPauseLedger(intervals: entry.value)
    }

    /// Keep a finished workout's pauses. A workout that was never paused stores nothing.
    static func store(_ ledger: WorkoutPauseLedger, startTs: Int, sport: String,
                      into defaults: UserDefaults = .standard) {
        guard !ledger.intervals.isEmpty else { return }
        var map = loadMap(from: defaults)
        map[key(startTs: startTs, sport: sport)] = ledger.intervals
        if map.count > maxEntries {
            let ordered = map.keys.sorted { lhs, rhs in
                (Int(lhs.split(separator: "|").first ?? "") ?? 0) < (Int(rhs.split(separator: "|").first ?? "") ?? 0)
            }
            for stale in ordered.prefix(map.count - maxEntries) { map.removeValue(forKey: stale) }
        }
        guard let data = encodeMap(map) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func remove(startTs: Int, sport: String, from defaults: UserDefaults = .standard) {
        var map = loadMap(from: defaults)
        guard map.removeValue(forKey: key(startTs: startTs, sport: sport)) != nil,
              let data = encodeMap(map) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// Follow a workout that was edited. The pauses keep their place in the workout: a start moved by some seconds moves
    /// them by the same seconds (a pause 20 minutes in is still 20 minutes in), and whatever then falls outside the new
    /// window (the duration was cut short, or the window no longer reaches a pause) is clipped or dropped, so what is
    /// stored is exactly what the window holds. Re-keyed by sport or start, the entry moves to its new key.
    static func follow(fromStartTs: Int, fromSport: String, to row: WorkoutRow, in defaults: UserDefaults = .standard) {
        guard let ledger = load(startTs: fromStartTs, sport: fromSport, from: defaults) else { return }
        let followed = ledger
            .shifted(by: Double(row.startTs - fromStartTs))
            .clipped(from: Double(row.startTs), to: Double(row.endTs))
        if key(startTs: fromStartTs, sport: fromSport) != key(startTs: row.startTs, sport: row.sport) {
            remove(startTs: fromStartTs, sport: fromSport, from: defaults)
        }
        if followed.intervals.isEmpty {
            remove(startTs: row.startTs, sport: row.sport, from: defaults)
        } else {
            store(followed, startTs: row.startTs, sport: row.sport, into: defaults)
        }
    }
}

extension WorkoutPauseLedger {

    /// The same pauses, every one `seconds` later (or earlier, when negative). A workout whose start moves takes its
    /// pauses with it.
    func shifted(by seconds: Double) -> WorkoutPauseLedger {
        guard seconds != 0 else { return self }
        return WorkoutPauseLedger(intervals: intervals.map { .init(start: $0.start + seconds, end: $0.end + seconds) })
    }

    /// The pauses that lie in `start...end`, each cut at its edges; a pause wholly outside is dropped.
    func clipped(from start: Double, to end: Double) -> WorkoutPauseLedger {
        WorkoutPauseLedger(intervals: intervals.compactMap { interval in
            let from = max(interval.start, start), to = min(interval.end, end)
            return to > from ? WorkoutPauseLedger.Interval(start: from, end: to) : nil
        })
    }

    /// The wall-clock second a workout that began at `start` reaches `activeSeconds` of running time: the first moment
    /// after `start` at which `activeSeconds(from: start, to:)` equals it. The pauses are walked in order, so one the
    /// workout never reaches costs nothing and one it does reach costs its whole length; a workout that reaches its
    /// running time exactly as a pause begins ends there, before the pause.
    func wallClockEnd(from start: Double, activeSeconds: Double) -> Double {
        var cursor = start
        var remaining = max(0, activeSeconds)
        for interval in intervals where interval.end > cursor {
            if interval.start <= cursor {          // the cursor is inside this pause: step over it
                cursor = interval.end
                continue
            }
            let gap = interval.start - cursor
            if remaining <= gap { return cursor + remaining }
            remaining -= gap
            cursor = interval.end
        }
        return cursor + remaining
    }
}
