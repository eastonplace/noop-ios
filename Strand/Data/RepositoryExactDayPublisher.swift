// Paste inside Repository.swift. It replaces the 4,000-day post-backfill refresh.
// The verified Today snapshot has already committed before this method runs.

import Foundation
import NoopPhase34Core
import WhoopStore

/*
Inside Repository add:

    @Published private(set) var verifiedHealthProjection: VerifiedHealthProjection?
    @Published private(set) var historyExtent = RepositoryHistoryExtent(
        earliestDay: nil,
        latestDay: nil,
        importedDayCount: 0,
        computedDayCount: 0,
        appleDayCount: 0
    )

    func publishVerifiedExactDays(
        _ exactDays: Set<CivilDay>,
        recordedTimeZoneIdentifier: String,
        snapshot: SnapshotCommitReceipt
    ) async throws -> RepositoryRefreshOutcome {
        guard !exactDays.isEmpty else {
            verifiedHealthProjection = snapshot.projection
            return RepositoryRefreshOutcome(
                authoritativeDataPublished: true,
                changedDays: [],
                snapshotStatus: .persisted
            )
        }
        guard let store = await ensureStore(),
              snapshot.projection.contextId == todayHealthSnapshotContext?.identifier,
              snapshot.projection.deviceId == canonicalDeviceId else {
            return RepositoryRefreshOutcome(
                authoritativeDataPublished: false,
                changedDays: [],
                snapshotStatus: .deferred
            )
        }

        let healthCalendar = try HealthCalendar(timeZoneIdentifier: recordedTimeZoneIdentifier)
        let runs = try Self.contiguousDayRuns(exactDays, healthCalendar: healthCalendar)
        let maximumSleepLookback = 20 * 3_600
        let windows = try runs.map { run -> CanonicalHealthSurfaceReadWindow in
            let firstInterval = try healthCalendar.interval(for: run.first)
            let lastInterval = try healthCalendar.interval(for: run.last)
            return CanonicalHealthSurfaceReadWindow(
                fromDay: run.first.key,
                throughDay: run.last.key,      // Store day queries are inclusive.
                sleepFromTs: Int(firstInterval.start.timeIntervalSince1970) - maximumSleepLookback,
                sleepThroughTs: Int(lastInterval.end.timeIntervalSince1970) + 4 * 3_600
            )
        }

        // One GRDB read transaction covers every sparse run. It cannot mix a pre-score DailyMetric with a
        // post-score metricSeries point from another WAL generation.
        let orderedSourceIds = Self.stableUniqueSourceIds(
            importedReadIds + computedReadIds + [Self.appleHealthSource]
        )
        let read = try await store.canonicalHealthSurfaceSnapshot(
            sourceIds: orderedSourceIds,
            windows: windows,
            metricKeys: [
                // One exact WAL snapshot feeds every Today/Sleep/Trends auxiliary field that can change
                // after scoring. Omitting these leaves the headline fresh while detail cards stay stale.
                "sleep_performance",
                "sleep_consistency",
                "sleep_need_min",
                "sleep_debt_min",
                "stress",
                Self.sleepPerformanceV2Key,
                Self.sleepPerformanceV2SourceKey,
                Self.sleepNeedV2Key,
                "noop_sleep_baseline_need_v2_min",
                "noop_sleep_strain_need_v2_min",
                "noop_sleep_debt_need_v2_min",
                "noop_sleep_nap_credit_v2_min",
            ]
        )
        guard read.databaseInstanceId == todayHealthSnapshotContext?.databaseInstanceId else {
            throw RepositoryExactPublicationError.databaseChanged
        }

        let dayKeys = Set(exactDays.map(\.key))
        let (sourceGeneration, overflow) = canonicalHealth.sourceGeneration.addingReportingOverflow(1)
        guard !overflow else { throw RepositoryExactPublicationError.generationExhausted }
        let exact = try await Self.mergeCanonicalHealthSurfaceRead(
            read,
            authoritativeDayKeys: dayKeys,
            importedReadIds: importedReadIds,
            computedReadIds: computedReadIds,
            sleepMode: SleepPerformanceV2Prefs.mode,
            previousCanonicalHealth: canonicalHealth,
            sourceGeneration: sourceGeneration,
            recordedTimeZoneIdentifier: recordedTimeZoneIdentifier
        )

        let nextDays = ExactDayCacheMerge.replacing(
            existing: days,
            incoming: exact.days,
            authoritativeKeys: dayKeys,
            key: \.day,
            areInIncreasingOrder: { $0.day < $1.day }
        )
        let nextSleeps = Self.replaceSleepSessions(
            existing: sleeps,
            incoming: exact.sleeps,
            authoritativeWakeDays: dayKeys,
            timeZoneIdentifier: recordedTimeZoneIdentifier
        )
        let nextVitals = Self.replaceSourcedRows(
            existing: vitalRows,
            incoming: exact.vitalRows,
            authoritativeDays: dayKeys
        )
        let nextImportedSleep = importedSleep
            .filter { !dayKeys.contains($0.key) }
            .merging(exact.importedSleep) { _, new in new }
        let nextMetricSources = todayHealthMetricSources
            .filter { !dayKeys.contains($0.key) }
            .merging(exact.todayHealthMetricSources) { _, new in new }
        let nextPersistedStrain = persistedStrainByDay
            .filter { !dayKeys.contains($0.key) }
            .merging(exact.persistedStrainByDay) { _, new in new }
        let nextImportedStrain = importedStrainByDay
            .filter { !dayKeys.contains($0.key) }
            .merging(exact.importedStrainByDay) { _, new in new }

        // Calculate the visible diff before assignment. A frontier/generation-only update must not cause
        // Sleep and Trends to rerun their expensive models. A canonical Sleep score-only change must.
        let presentationChanged = nextDays != days
            || nextSleeps != sleeps
            || nextVitals != vitalRows
            || nextImportedSleep != importedSleep
            || exact.canonicalHealth.presentationRevision != canonicalHealth.presentationRevision
            || snapshot.projection.presentationIdentity
                != verifiedHealthProjection?.presentationIdentity

        days = nextDays
        sleeps = nextSleeps
        vitalRows = nextVitals
        importedSleep = nextImportedSleep
        todayHealthMetricSources = nextMetricSources
        canonicalHealth = exact.canonicalHealth
        persistedStrainByDay = nextPersistedStrain
        importedStrainByDay = nextImportedStrain
        rebuildCanonicalStrain()
        verifiedHealthProjection = snapshot.projection
        loaded = true
        if presentationChanged { refreshSeq &+= 1 }

        return RepositoryRefreshOutcome(
            authoritativeDataPublished: true,
            changedDays: exactDays,
            snapshotStatus: .persisted
        )
    }

Required rules:

- `SnapshotCommitReceipt` is produced by save + read-back verification before this call. Do not call
  `saveTodayHealthSnapshot` or publish an uncommitted candidate here.
- Receipt, analysis, Repository, and snapshot generations are separate domains. Never pass a receipt
  generation as a snapshot generation.
- `replaceSleepSessions` determines the persisted wake day in `recordedTimeZoneIdentifier`. Missing incoming
  rows for an authoritative wake day delete old cache rows.
- `mergeCanonicalHealthSurfaceRead` is also used by launch/recent refresh. One source precedence implementation
  feeds Today, Sleep, and Trends. Its result must include `importedSleep` and field-level
  `todayHealthMetricSources`; exact publication replaces those values for every authoritative day. Refresh
  `RepositoryHistoryExtent` with its aggregate query when row counts or source coverage changed. Never derive
  extent from the bounded recent cache.
- Preserve source order. `Set` iteration is not an authority rule. Add this helper beside the merge code:

      nonisolated static func stableUniqueSourceIds(_ ids: [String]) -> [String] {
          var seen = Set<String>()
          return ids.filter { seen.insert($0).inserted }
      }

  The array order remains active imported, canonical imported, active computed, canonical computed, Apple fallback.
- Sparse January and March days create two read windows. No query covers February.
*/

private enum RepositoryExactPublicationError: Error {
    case databaseChanged
    case generationExhausted
}
