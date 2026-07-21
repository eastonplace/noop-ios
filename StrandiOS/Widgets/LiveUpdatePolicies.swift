#if os(iOS)
import Foundation

/// Pure publication policy for the widget's fast live lane.
///
/// Connection, battery, canonical Strain, and workout start/end transitions are user-visible state
/// changes and publish immediately. Heart-rate and in-workout sparkline churn are high-frequency and
/// coalesce to a bounded cadence so a 1 Hz workout does not encode App Group JSON and ask WidgetKit to
/// reload every second.
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
            || old.strain != new.strain
            || workoutModeChanged
        if urgentChange { return true }

        return now.timeIntervalSince(lastPublishedAt) >= highFrequencyInterval
    }

    private struct LiveFields: Equatable {
        let bpm: Int?
        let batteryPct: Int?
        let bonded: Bool
        let strain: Double?
        let hrSparkline: [Int]?

        init(_ snapshot: WidgetSnapshot) {
            bpm = snapshot.bpm
            batteryPct = snapshot.batteryPct
            bonded = snapshot.bonded
            strain = snapshot.strain
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
        return now.timeIntervalSince(lastBuiltAt) >= rebuildInterval
    }
}
#endif
