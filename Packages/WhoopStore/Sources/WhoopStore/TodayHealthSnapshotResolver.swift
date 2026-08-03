import Foundation

/// Pure, per-metric first-paint handoff. A full repository refresh may know only some current values;
/// this keeps a visible snapshot value until a fresher non-nil replacement exists.
public enum TodayHealthSnapshotResolver {
    public static func resolve(
        persisted: TodayHealthSnapshot?,
        live: TodayHealthSnapshot?
    ) -> TodayHealthSnapshot? {
        guard let live else { return persisted }
        guard let persisted else { return live }

        // A different scope represents another dashboard owner. Never blend its health values.
        guard persisted.scopeId == live.scopeId else { return live }

        // A new resolved day with no health data must not erase a still-visible prior snapshot. Once it
        // has any real value, it owns the screen and remains internally coherent rather than mixing days.
        guard persisted.displayDay == live.displayDay else {
            return live.hasHealthValue ? live : persisted
        }

        let recovery = preferred(persisted.recovery, from: persisted, live.recovery, from: live)
        let strain = preferred(persisted.strain, from: persisted, live.strain, from: live)
        let sleepScore = preferred(persisted.sleepScore, from: persisted, live.sleepScore, from: live)
        let sleepDuration = preferred(
            persisted.sleepDurationMinutes, from: persisted,
            live.sleepDurationMinutes, from: live
        )

        let base = live.dailyMetric
        let resolvedDaily = base.replacing(
            totalSleepMin: .some(sleepDuration?.value),
            recovery: .some(recovery?.value),
            strain: .some(strain?.value),
            strainVersion: .some(strain?.strainVersion)
        )
        return TodayHealthSnapshot(
            scopeId: live.scopeId,
            deviceId: live.deviceId,
            displayDay: live.displayDay,
            logicalDay: live.logicalDay,
            localDay: live.localDay,
            generatedAt: max(persisted.generatedAt, live.generatedAt),
            rawFrontierTs: maxOptional(persisted.rawFrontierTs, live.rawFrontierTs),
            schemaVersion: max(persisted.schemaVersion, live.schemaVersion),
            dailyMetric: resolvedDaily,
            recovery: recovery,
            strain: strain,
            sleepScore: sleepScore,
            sleepDurationMinutes: sleepDuration
        )
    }

    private static func preferred(
        _ persisted: TodayHealthMetricValue?, from persistedSnapshot: TodayHealthSnapshot,
        _ live: TodayHealthMetricValue?, from liveSnapshot: TodayHealthSnapshot
    ) -> TodayHealthMetricValue? {
        guard let persisted else { return live }
        guard let live else { return persisted }
        return evidence(live, snapshot: liveSnapshot) >= evidence(persisted, snapshot: persistedSnapshot)
            ? live
            : persisted
    }

    /// Raw-data frontier is strongest evidence. When a producer does not have one, use its own observed
    /// timestamp, then the snapshot generation timestamp. Nil is intentionally not fabricated as "now".
    private static func evidence(
        _ value: TodayHealthMetricValue,
        snapshot: TodayHealthSnapshot
    ) -> (Int, Int, Int) {
        (value.rawFrontierTs ?? Int.min, value.observedAt ?? snapshot.generatedAt,
         snapshot.generatedAt)
    }

    private static func maxOptional(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): return max(lhs, rhs)
        case let (lhs?, nil): return lhs
        case let (nil, rhs?): return rhs
        case (nil, nil): return nil
        }
    }
}

private extension TodayHealthSnapshot {
    var hasHealthValue: Bool {
        recovery != nil || strain != nil || sleepScore != nil || sleepDurationMinutes != nil
    }
}
