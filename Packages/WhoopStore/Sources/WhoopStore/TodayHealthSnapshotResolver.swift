import Foundation

/// Pure, per-metric first-paint handoff. A partial producer may leave a metric unknown, while an
/// authoritative producer may explicitly clear it. Recovery, Strain, and Sleep can also describe
/// different days around the morning rollover, so they are resolved independently.
public enum TodayHealthSnapshotResolver {
    public static func resolve(
        persisted: TodayHealthSnapshot?,
        live: TodayHealthSnapshot?
    ) -> TodayHealthSnapshot? {
        guard let live else { return persisted }
        guard let persisted else { return live }

        // A different scope or context represents another dashboard/source generation. Never blend it.
        guard persisted.scopeId == live.scopeId,
              contextsAreCompatible(persisted: persisted, live: live)
        else { return live }

        let recovery = preferred(.recovery, persisted: persisted, live: live)
        let strain = preferred(.strain, persisted: persisted, live: live)
        let sleepScore = preferred(.sleepScore, persisted: persisted, live: live)
        let sleepDuration = preferred(.sleepDurationMinutes, persisted: persisted, live: live)

        let base = live.dailyMetric
        let resolvedDaily = base.replacing(
            totalSleepMin: .some(sleepDuration?.value),
            recovery: .some(recovery?.value),
            strain: .some(strain?.value),
            strainVersion: .some(strain?.strainVersion)
        )
        return TodayHealthSnapshot(
            scopeId: live.scopeId,
            context: live.context,
            deviceId: live.deviceId,
            displayDay: live.displayDay,
            logicalDay: live.logicalDay,
            localDay: live.localDay,
            generatedAt: max(persisted.generatedAt, live.generatedAt),
            rawFrontierTs: maxOptional(persisted.rawFrontierTs, live.rawFrontierTs),
            schemaVersion: max(persisted.schemaVersion, live.schemaVersion),
            authoritativeMetrics: persisted.authoritativeMetrics.union(live.authoritativeMetrics),
            dailyMetric: resolvedDaily,
            recovery: recovery,
            strain: strain,
            sleepScore: sleepScore,
            sleepDurationMinutes: sleepDuration
        )
    }

    private static func contextsAreCompatible(
        persisted: TodayHealthSnapshot,
        live: TodayHealthSnapshot
    ) -> Bool {
        switch (persisted.context, live.context) {
        case let (persisted?, live?):
            return persisted == live
        // A legacy snapshot has no source/database context. Repository upgrades only snapshots it can
        // prove compatible before it reaches this resolver; do not silently blend one here.
        case (nil, nil):
            return persisted.schemaVersion < TodayHealthSnapshot.currentSchemaVersion
                && live.schemaVersion < TodayHealthSnapshot.currentSchemaVersion
        case (nil, _), (_, nil):
            return false
        }
    }

    private static func preferred(
        _ metric: TodayHealthSnapshot.Metric,
        persisted: TodayHealthSnapshot,
        live: TodayHealthSnapshot
    ) -> TodayHealthMetricValue? {
        let persistedValue = persisted.metric(metric)
        let liveValue = live.metric(metric)

        // A full read resolves both states for its own display day: value replaces older evidence; nil
        // clears a value for that same day. A new day with no Recovery or Sleep is not a deletion of the
        // previous night's score, so retain that carried metric until the new day's producer resolves it.
        if live.isAuthoritative(metric) {
            if let liveValue { return liveValue }
            guard let persistedValue else { return nil }
            return persistedValue.metricDay == live.displayDay ? nil : persistedValue
        }
        guard let persistedValue else { return liveValue }
        guard let liveValue else { return persistedValue }

        // A real new physiological day is more useful than an older carried metric. The metric's own day,
        // not the snapshot's display day, owns this comparison.
        if let liveDay = liveValue.metricDay, let persistedDay = persistedValue.metricDay,
           liveDay != persistedDay {
            return liveDay > persistedDay ? liveValue : persistedValue
        }

        return precedence(liveValue, metric: metric, snapshot: live)
            >= precedence(persistedValue, metric: metric, snapshot: persisted)
            ? liveValue
            : persistedValue
    }

    /// Algorithm/provenance authority outranks a raw frontier. This prevents a provisional live value from
    /// pinning a verified canonical V2 daily value simply because it carries a newer synthetic timestamp.
    private static func precedence(
        _ value: TodayHealthMetricValue,
        metric: TodayHealthSnapshot.Metric,
        snapshot: TodayHealthSnapshot
    ) -> (Int, Int, Int, Int) {
        let algorithmAuthority: Int
        switch metric {
        case .strain:
            algorithmAuthority = value.strainVersion == 2 && value.algorithmVersion?.contains("strain-v2") == true
                ? 2 : 0
        case .recovery, .sleepScore, .sleepDurationMinutes:
            algorithmAuthority = value.algorithmVersion == nil ? 0 : 1
        }
        return (algorithmAuthority, value.rawFrontierTs ?? Int.min,
                value.observedAt ?? snapshot.generatedAt,
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
