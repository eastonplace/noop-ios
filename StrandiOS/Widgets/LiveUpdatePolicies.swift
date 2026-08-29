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
#endif
