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

        let states = Dictionary(uniqueKeysWithValues: TodayHealthSnapshot.Metric.allCases.map { metric in
            (metric, preferred(metric, persisted: persisted, live: live))
        })
        let resolvedDaily = live.dailyMetric.replacing(
            totalSleepMin: .some(currentDayValue(states[.sleepDurationMinutes], displayDay: live.displayDay)),
            recovery: .some(currentDayValue(states[.recovery], displayDay: live.displayDay)),
            strain: .some(currentDayValue(states[.strain], displayDay: live.displayDay)),
            strainVersion: .some(currentDayStrainVersion(states[.strain], displayDay: live.displayDay))
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
            generation: max(persisted.generation, live.generation),
            schemaVersion: max(persisted.schemaVersion, live.schemaVersion),
            authoritativeMetrics: persisted.authoritativeMetrics.union(live.authoritativeMetrics),
            dailyMetric: resolvedDaily,
            metricStates: states
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
    ) -> TodayHealthMetricState {
        let persistedState = persisted.state(for: metric)
        let liveState = live.state(for: metric)

        // Strain is an intraday value. It may be replaced by a newer same-day state, but it is never a
        // valid carry from the prior physiological day. Recovery and Sleep may carry their evidence.
        if metric == .strain,
           liveState.isUnknown,
           let persistedDay = persistedState.metricDay,
           persistedDay != live.displayDay {
            return .unknown
        }

        let liveDay = liveState.metricDay ?? live.displayDay
        let persistedDay = persistedState.metricDay ?? persisted.displayDay

        // A persisted unavailable state is a durable negative read. A same-day live value may replace it
        // only when the producer proves that it is a newer authoritative read. This prevents an unsaved,
        // generation-zero stale value from resurrecting a value that the database has already cleared.
        if liveDay == persistedDay,
           case .unavailable = persistedState,
           case .value = liveState {
            guard live.isAuthoritative(metric),
                  isNewerEvidence(liveState, in: live, than: persistedState, in: persisted)
            else { return persistedState }
        }

        if live.isAuthoritative(metric) {
            switch liveState {
            case let .unavailable(evidence):
                // A new-day absence means that today's overnight score has not arrived yet. It is not a
                // deletion of yesterday's completed night. Explicit deletion remains allowed to clear a
                // carried value across the day boundary.
                if metric != .strain,
                   liveDay != persistedDay,
                   evidence.reason != .deleted {
                    return persistedState.isUnknown ? liveState : persistedState
                }
                // The live producer completed this same-day read. Its generation is still zero until the
                // write reaches SQLite, but explicit authority is the current-read precedence signal.
                return liveState
            case .value:
                // Preserve the existing authoritative-read contract. It lets a completed same-day read
                // replace a persisted provisional value even before SQLite assigns the next generation.
                if liveDay >= persistedDay { return liveState }
            case .unknown:
                break
            }
        }

        switch liveState {
        case .unknown:
            // Unknown means the read did not complete. It cannot clear evidence already on disk.
            return persistedState
        case .value, .unavailable:
            guard !persistedState.isUnknown else { return liveState }
            return isNewerOrEqual(liveState, in: live, authoritative: live.isAuthoritative(metric))
                >= isNewerOrEqual(persistedState, in: persisted,
                                   authoritative: persisted.isAuthoritative(metric))
                ? liveState
                : persistedState
        }
    }

    /// Raw frontier orders source evidence. Database generation orders writes that consumed the same
    /// frontier. A fresh correction must provide one of those signals; generatedAt is never sufficient.
    private static func isNewerEvidence(
        _ candidate: TodayHealthMetricState,
        in candidateSnapshot: TodayHealthSnapshot,
        than existing: TodayHealthMetricState,
        in existingSnapshot: TodayHealthSnapshot
    ) -> Bool {
        let candidateFrontier = rawFrontier(candidate)
        let existingFrontier = rawFrontier(existing)
        if candidateFrontier != existingFrontier {
            return candidateFrontier > existingFrontier
        }
        return evidenceGeneration(candidate, snapshot: candidateSnapshot)
            > evidenceGeneration(existing, snapshot: existingSnapshot)
    }

    /// The day identity belongs to metric evidence, not to the snapshot row. A new physiological day wins
    /// even when the raw frontier is absent, and an older carry cannot overwrite a current-day state.
    private static func isNewerOrEqual(
        _ state: TodayHealthMetricState,
        in snapshot: TodayHealthSnapshot,
        authoritative: Bool
    ) -> MetricOrder {
        MetricOrder(
            metricDay: state.metricDay ?? snapshot.displayDay,
            sourceAuthority: authoritative ? 1 : 0,
            algorithmAuthority: algorithmAuthority(state),
            rawFrontierTs: rawFrontier(state),
            evidenceGeneration: evidenceGeneration(state, snapshot: snapshot),
            observedAt: observedAt(state),
            liveTieBreak: snapshot.generation
        )
    }

    private struct MetricOrder: Comparable {
        let metricDay: String
        let sourceAuthority: Int
        let algorithmAuthority: Int
        let rawFrontierTs: Int
        let evidenceGeneration: Int64
        let observedAt: Int
        let liveTieBreak: Int64

        static func < (lhs: MetricOrder, rhs: MetricOrder) -> Bool {
            if lhs.metricDay != rhs.metricDay { return lhs.metricDay < rhs.metricDay }
            if lhs.sourceAuthority != rhs.sourceAuthority {
                return lhs.sourceAuthority < rhs.sourceAuthority
            }
            if lhs.algorithmAuthority != rhs.algorithmAuthority {
                return lhs.algorithmAuthority < rhs.algorithmAuthority
            }
            if lhs.rawFrontierTs != rhs.rawFrontierTs { return lhs.rawFrontierTs < rhs.rawFrontierTs }
            if lhs.evidenceGeneration != rhs.evidenceGeneration {
                return lhs.evidenceGeneration < rhs.evidenceGeneration
            }
            if lhs.observedAt != rhs.observedAt { return lhs.observedAt < rhs.observedAt }
            return lhs.liveTieBreak < rhs.liveTieBreak
        }
    }

    private static func algorithmAuthority(_ state: TodayHealthMetricState) -> Int {
        guard let value = state.value else { return 0 }
        let algorithm = value.algorithmVersion ?? ""
        return value.strainVersion == 2 && algorithm.contains("strain-v2") ? 2 : 1
    }

    private static func rawFrontier(_ state: TodayHealthMetricState) -> Int {
        switch state {
        case .unknown: return -1
        case let .value(value): return value.rawFrontierTs ?? -1
        case let .unavailable(evidence): return evidence.rawFrontierTs ?? -1
        }
    }

    private static func evidenceGeneration(
        _ state: TodayHealthMetricState,
        snapshot: TodayHealthSnapshot
    ) -> Int64 {
        switch state {
        case .unknown: return snapshot.generation
        case let .value(value): return max(value.generation, snapshot.generation)
        case let .unavailable(evidence): return max(evidence.generation, snapshot.generation)
        }
    }

    private static func observedAt(_ state: TodayHealthMetricState) -> Int {
        switch state {
        case .unknown: return -1
        case let .value(value): return value.observedAt ?? -1
        case let .unavailable(evidence): return evidence.observedAt
        }
    }

    private static func currentDayValue(
        _ state: TodayHealthMetricState?,
        displayDay: String
    ) -> Double? {
        guard let value = state?.value, value.metricDay == displayDay else { return nil }
        return value.value
    }

    private static func currentDayStrainVersion(
        _ state: TodayHealthMetricState?,
        displayDay: String
    ) -> Int? {
        guard let value = state?.value, value.metricDay == displayDay else { return nil }
        return value.strainVersion
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
