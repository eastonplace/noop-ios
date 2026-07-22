#if os(iOS)
import Foundation

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

/// Pure policy for the expensive workout projection attached to a Live Activity update.
///
/// Starting a workout must be detected promptly, so the no-workout path probes whenever a throttled
/// ActivityKit push is otherwise eligible. Once a workout projection is cached, calorie/zone rescans are
/// capped to this interval instead of rebuilding over the entire growing sample array on every HR tick.
enum LiveActivityWorkoutProjectionPolicy {
    static let rebuildInterval: TimeInterval = 10

    static func shouldRebuild(
        lastModeWasWorkout: Bool?,
        hasCachedWorkout: Bool,
        lastBuiltAt: Date,
        now: Date,
        rebuildInterval: TimeInterval = rebuildInterval
    ) -> Bool {
        guard lastModeWasWorkout == true, hasCachedWorkout else { return true }
        let elapsed = now.timeIntervalSince(lastBuiltAt)
        return elapsed < 0 || elapsed >= rebuildInterval
    }
}
#endif