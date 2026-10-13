#if os(iOS)
import Foundation

/// Standard widgets are budgeted, but the existing one-minute live lane may still publish while a
/// workout owns background BLE/location execution. Outside a workout, sensor callbacks remain
/// foreground-only so incidental background wakes cannot churn WidgetKit timelines.
enum WidgetLivePublicationContext {
    static func shouldPublish(sceneIsActive: Bool, hasActiveWorkout: Bool) -> Bool {
        sceneIsActive || hasActiveWorkout
    }
}

/// Pure publication policy for the widget's fast live lane.
///
/// Connection, battery, and workout start/end transitions are user-visible state edges and publish
/// immediately. Heart-rate, canonical Strain, and in-workout sparkline churn are high-frequency and
/// coalesce to a bounded cadence so a live session does not encode App Group JSON and ask WidgetKit to
/// reload several times per minute.
enum WidgetLivePublishPolicy {
    static let highFrequencyInterval: TimeInterval = 60

    static func shouldPublish(
        previous: WidgetSnapshot?,
        next: WidgetSnapshot,
        lastPublishedAt: Date,
        now: Date,
        highFrequencyInterval: TimeInterval = highFrequencyInterval
    ) -> Bool {
        guard let previous else { return true }

        let old = LiveFields(previous)
        let new = LiveFields(next)
        guard old != new else { return false }

        let workoutModeChanged = (old.hrSparkline == nil) != (new.hrSparkline == nil)
        let urgentChange = old.bonded != new.bonded
            || old.batteryPct != new.batteryPct
            || workoutModeChanged
        if urgentChange { return true }

        // A manual clock correction must not starve publication until wall time catches up with a
        // future-dated snapshot. Treat a negative elapsed interval as an expired throttle window.
        let elapsed = now.timeIntervalSince(lastPublishedAt)
        return elapsed < 0 || elapsed >= highFrequencyInterval
    }

    private struct LiveFields: Equatable {
        let bpm: Int?
        let batteryPct: Int?
        let bonded: Bool
        /// Widgets render Strain at one decimal place. Comparing the rendered tenth prevents tiny
        /// floating-point changes that cannot alter the UI from triggering a publication.
        let strainTenths: Int?
        let hrSparkline: [Int]?

        init(_ snapshot: WidgetSnapshot) {
            bpm = snapshot.bpm
            batteryPct = snapshot.batteryPct
            bonded = snapshot.bonded
            strainTenths = snapshot.strain.map { Int(($0 * 10).rounded()) }
            hrSparkline = snapshot.hrSparkline
        }
    }
}

/// Pure policy for the slower full-dashboard widget publication.
///
/// Repository refreshes can fire for unrelated data and rebuild the same widget payload. The snapshot's
/// timestamp must not turn those semantic no-ops into App Group writes and WidgetKit reloads. A bounded
/// heartbeat still advances freshness for a quiet app, and clock rollback is treated as an expired gate.
enum WidgetFullPublishPolicy {
    static let unchangedHeartbeatInterval: TimeInterval = 15 * 60

    static func shouldPublish(
        previous: WidgetSnapshot?,
        next: WidgetSnapshot,
        lastPublishedAt: Date,
        now: Date,
        unchangedHeartbeatInterval: TimeInterval = unchangedHeartbeatInterval
    ) -> Bool {
        guard let previous else { return true }
        guard previous.hasSameRenderedContent(as: next) else { return true }
        let elapsed = now.timeIntervalSince(lastPublishedAt)
        return elapsed < 0 || elapsed >= unchangedHeartbeatInterval
    }
}

/// Pure gate for ActivityKit pushes.
///
/// Normal content updates retain the approximately two-second cadence. A workout start/end mode edge
/// bypasses that throttle so the Lock Screen and Dynamic Island cannot remain in the wrong mode merely
/// because the user tapped Start or Finish immediately after a BPM update.
enum LiveActivityPushPolicy {
    static let pushInterval: TimeInterval = 2

    static func shouldPush(
        activityExists: Bool,
        currentModeIsWorkout: Bool?,
        desiredModeIsWorkout: Bool,
        lastPushedAt: Date,
        now: Date,
        pushInterval: TimeInterval = pushInterval
    ) -> Bool {
        guard activityExists else { return true }
        if let currentModeIsWorkout, currentModeIsWorkout != desiredModeIsWorkout {
            return true
        }
        let elapsed = now.timeIntervalSince(lastPushedAt)
        return elapsed < 0 || elapsed >= pushInterval
    }
}

/// Remembers that the workout's pause state changed, so the next ActivityKit write skips the push throttle, and forgets
/// it only once a write that was BUILT AFTER the change has gone out.
///
/// A write can be in flight (suspended at `await activity.update`) when the person taps Pause. That write carries the
/// old state. When it returns it must not clear what the tap just raised: the write that follows would then be throttled
/// away (it comes less than a push interval later) and the activity would keep a running clock and a Pause button under
/// a paused workout, for as long as nothing else drove an update. Counting edges instead of holding a flag settles it:
/// a write records the count it was built at, and only edges up to that count are carried.
struct PauseEdgeLatch: Equatable {
    private(set) var generation = 0
    private var deliveredGeneration = 0

    /// An edge has happened that no write has carried yet.
    var isPending: Bool { generation != deliveredGeneration }

    /// The workout was paused or resumed (or a surface asked for a state the workout was already in).
    mutating func noteEdge() { generation &+= 1 }

    /// A write built when the count stood at `built` has gone out: edges up to it are carried, later ones are not.
    mutating func delivered(builtAt built: Int) { deliveredGeneration = built }

    /// Forget everything (the activity ended); nothing is owed to a surface that no longer exists.
    mutating func reset() { deliveredGeneration = generation }
}

/// What heart rate the Live Activity carries.
///
/// A workout's heart rate is the last reading it took, whether or not the strap is connected right now, exactly what the
/// workout screen shows. Dropping it to "—" the moment the link goes (or while paused with no strap) made the Lock Screen
/// say less than the app did; the activity dims a reading it cannot vouch for instead (`bonded`, paused, stale).
enum LiveActivityHeartRate {
    static func value(workoutIsActive: Bool, workoutBPM: Int?, connected: Bool, passiveBPM: Int?) -> Int? {
        if workoutIsActive { return workoutBPM }
        return connected ? passiveBPM : nil
    }
}

enum LiveActivityWorkoutProjectionDecision: Equatable {
    /// Workout mode is not active. Drop any cached workout projection without evaluating the supplier.
    case clear
    /// Workout mode is active and the bounded cached projection is still fresh.
    case reuse
    /// Workout mode is active and a fresh expensive projection is required.
    case rebuild
}

/// Pure policy for the expensive workout projection attached to a Live Activity update.
///
/// Workout presence is supplied separately from the expensive projection itself. That lets a start/end
/// edge be observed immediately without rescanning calories and zones on every HR event. While a workout
/// is active, the growing-array projection is rebuilt at a bounded cadence and reused between builds.
enum LiveActivityWorkoutProjectionPolicy {
    static let rebuildInterval: TimeInterval = 10

    static func decision(
        workoutIsActive: Bool,
        hasCachedWorkout: Bool,
        lastBuiltAt: Date,
        now: Date,
        rebuildInterval: TimeInterval = rebuildInterval
    ) -> LiveActivityWorkoutProjectionDecision {
        guard workoutIsActive else { return .clear }
        guard hasCachedWorkout else { return .rebuild }
        let elapsed = now.timeIntervalSince(lastBuiltAt)
        return elapsed < 0 || elapsed >= rebuildInterval ? .rebuild : .reuse
    }

    static func shouldRebuild(
        workoutIsActive: Bool,
        hasCachedWorkout: Bool,
        lastBuiltAt: Date,
        now: Date,
        rebuildInterval: TimeInterval = rebuildInterval
    ) -> Bool {
        decision(
            workoutIsActive: workoutIsActive,
            hasCachedWorkout: hasCachedWorkout,
            lastBuiltAt: lastBuiltAt,
            now: now,
            rebuildInterval: rebuildInterval
        ) == .rebuild
    }

    /// Compatibility seam for any older focused caller. New production code should pass explicit workout
    /// presence so inactive mode cannot be inferred from a stale cached projection.
    static func shouldRebuild(
        lastModeWasWorkout: Bool?,
        hasCachedWorkout: Bool,
        lastBuiltAt: Date,
        now: Date,
        rebuildInterval: TimeInterval = rebuildInterval
    ) -> Bool {
        shouldRebuild(
            workoutIsActive: lastModeWasWorkout == true,
            hasCachedWorkout: hasCachedWorkout,
            lastBuiltAt: lastBuiltAt,
            now: now,
            rebuildInterval: rebuildInterval
        )
    }
}

/// The workout state the controller keeps between rebuilds. The projection is expensive (calories, zones, the heart-rate
/// trace), so it is reused for up to `LiveActivityWorkoutProjectionPolicy.rebuildInterval`; anything cheap that can change
/// inside that window must not be frozen into it. The quiet-strap verdict is the one such field: it flips the moment a
/// reading arrives or the fifteenth silent second passes, and a cached copy would keep the heart dimmed (or undimmed) on the
/// Lock Screen until the next rebuild. It is asked again for every write, from the clock of that write, never when an update
/// was queued.
struct LiveActivityWorkoutStateCache {
    enum Write {
        /// Workout mode is not active: the cache was dropped, and the write carries no workout.
        case noWorkout
        /// The state to write, with the verdict of this write.
        case state(WorkoutLiveActivityState)
        /// Workout mode is active but there is no workout to project: the write is not applicable.
        case unavailable
    }

    private(set) var state: WorkoutLiveActivityState?
    private(set) var builtAt: Date = .distantPast

    /// A pause edge, a mode change or a reset: the next write rebuilds.
    mutating func clear() {
        state = nil
        builtAt = .distantPast
    }

    mutating func stateForWrite(workoutIsActive: Bool, now: Date, build: () -> WorkoutLiveActivityState?,
                                heartRateIsStale: () -> Bool) -> Write {
        guard workoutIsActive else {
            clear()
            return .noWorkout
        }
        var current: WorkoutLiveActivityState
        if LiveActivityWorkoutProjectionPolicy.shouldRebuild(
            workoutIsActive: true, hasCachedWorkout: state != nil, lastBuiltAt: builtAt, now: now) {
            guard let built = build() else {
                clear()
                return .unavailable
            }
            current = built
            builtAt = now
        } else if let cached = state {
            current = cached
        } else {
            clear()
            return .unavailable
        }
        current.heartRateIsStale = heartRateIsStale()
        state = current
        return .state(current)
    }
}

#endif
