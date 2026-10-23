import Foundation
import StrandAnalytics
import WhoopStore

struct DailyTrainingTargetReadKey: Hashable {
    let sourceContext: String
    let scope: String
    let invalidationEpoch: UInt64
    let isFenced: Bool
    let revision: Int
    let day: String
    let timeZone: String
    let recoverySource: String
}

struct DailyTrainingTargetData {
    let key: DailyTrainingTargetReadKey
    let history: [DailyTrainingTargetEngine.Day]
    let sleepNeedHours: Double?
    let sleepNeedDay: String?
    let sleepNeedObservationCount: Int
}

enum DailyTrainingTargetReadError: Error, Equatable {
    case sourceChanged, snapshotUnavailable, storeUnavailable, invalidDay
}

extension Repository {
    /// A live Strain update changes only the cheap evaluation. The 56-day database read runs on a
    /// repository/history revision, source change, recovery-source change, or logical-day rollover.
    func dailyTrainingTargetReadKey(now: Date) -> DailyTrainingTargetReadKey {
        DailyTrainingTargetReadKey(
            sourceContext: notificationSourceContext, scope: todayHealthSnapshotScopeId,
            invalidationEpoch: externalSurfaceInvalidationEpoch, isFenced: verifiedExternalSurfaceFenced, revision: refreshSeq,
            day: Self.logicalDayKey(now), timeZone: TimeZone.current.identifier,
            recoverySource: todayHealthSnapshot?.recovery?.sourceId ?? "")
    }

    func loadDailyTrainingTarget(now: Date = Date()) async throws -> DailyTrainingTargetData {
        try await readDailyTrainingTarget(now: now, afterRead: nil)
    }

    #if DEBUG
    func loadDailyTrainingTargetForTesting(
        now: Date, afterRead: @escaping @MainActor () async -> Void
    ) async throws -> DailyTrainingTargetData {
        try await readDailyTrainingTarget(now: now, afterRead: afterRead)
    }
    #endif

    private func readDailyTrainingTarget(
        now: Date, afterRead: (@MainActor () async -> Void)?
    ) async throws -> DailyTrainingTargetData {
        let key = dailyTrainingTargetReadKey(now: now)
        func check() throws {
            try Task.checkCancellation()
            guard !verifiedExternalSurfaceFenced, dailyTrainingTargetReadKey(now: now) == key else {
                throw DailyTrainingTargetReadError.sourceChanged
            }
        }
        try check()
        guard let from = DailyTrainingTargetEngine.offsetDay(key.day, by: -DailyTrainingTargetEngine.historyDays),
              let needFrom = DailyTrainingTargetEngine.offsetDay(key.day, by: -6) else {
            throw DailyTrainingTargetReadError.invalidDay
        }
        guard let store = await storeHandle() else { throw DailyTrainingTargetReadError.storeUnavailable }
        try check()
        guard let snapshot = todayHealthSnapshot, snapshot.scopeId == key.scope,
              let context = snapshot.context, context.identifier == activeVerifiedSinkContextId else {
            throw DailyTrainingTargetReadError.snapshotUnavailable
        }
        let imported = importedReadIds
        let computed = computedReadIds
        let currentTs = Int(now.timeIntervalSince1970)
        let read = try await store.canonicalHealthSurfaceSnapshot(
            sourceIds: imported + computed + [Self.appleHealthSource],
            fromDay: from, throughDay: key.day,
            sleepFromTs: currentTs - 48 * 3_600, sleepThroughTs: currentTs,
            metricKeys: [Self.sleepNeedV2Key])
        await afterRead?()
        try check()
        guard read.databaseInstanceId == context.databaseInstanceId else {
            throw DailyTrainingTargetReadError.sourceChanged
        }

        let computedSet = Set(computed)
        let byDay = Dictionary(grouping: read.dailyRows.filter { $0.metric.day < key.day }, by: { $0.metric.day })
        let history = byDay.keys.sorted().map { day -> DailyTrainingTargetEngine.Day in
            let rows = byDay[day] ?? []
            // Match canonical NOOP V2 precedence. Imported/legacy values stay out of this model even
            // when they happen to have the same numeric range as NOOP Strain.
            let strain = rows.filter {
                computedSet.contains($0.sourceId) && $0.metric.strainVersion == 2 && $0.metric.strain != nil
            }.max { $0.sourcePriority < $1.sourcePriority }?.metric.strain
            // Recovery forecast history keeps the source of the current Recovery observation.
            let recovery = rows.first { $0.sourceId == key.recoverySource }?.metric.recovery
            return .init(day: day, strainStored: strain, recovery: recovery)
        }
        let needRows = read.metricRows.filter {
            computedSet.contains($0.sourceId) && $0.key == Self.sleepNeedV2Key
                && $0.day >= needFrom && $0.day <= key.day
        }
        let need = needRows.max {
            ($0.day, $0.sourcePriority) < ($1.day, $1.sourcePriority)
        }
        let needDays = Set(needRows.filter { $0.value.isFinite && (60...1_440).contains($0.value) }.map(\.day)).count
        return DailyTrainingTargetData(key: key, history: history,
                                       sleepNeedHours: need.map { $0.value / 60 }, sleepNeedDay: need?.day,
                                       sleepNeedObservationCount: needDays)
    }

    /// Resolves current inputs at display time. Cached history never keeps old daily metrics alive.
    func dailyTrainingTargetEvaluation(_ data: DailyTrainingTargetData, now: Date) -> DailyTrainingTargetEngine.Result? {
        guard !verifiedExternalSurfaceFenced, dailyTrainingTargetReadKey(now: now) == data.key,
              let snapshot = todayHealthSnapshot, snapshot.scopeId == data.key.scope,
              let context = snapshot.context, context.identifier == activeVerifiedSinkContextId else { return nil }
        let sourceIDs = activeProjectionContributorIds
        let recovery = Self.currentTrainingMetric(.recovery, snapshot: snapshot, day: data.key.day,
                                                  sourceIDs: sourceIDs, now: now)
        let sleep = Self.currentTrainingMetric(.sleepDurationMinutes, snapshot: snapshot, day: data.key.day,
                                               sourceIDs: sourceIDs, now: now)
        let strain = Self.currentTrainingMetric(.strain, snapshot: snapshot, day: data.key.day,
                                                sourceIDs: sourceIDs, now: now)
        return DailyTrainingTargetEngine.evaluate(.init(
            day: data.key.day, recovery: recovery, sleptHours: sleep.map { $0 / 60 },
            sleepNeedHours: data.sleepNeedHours, sleepNeedDay: data.sleepNeedDay,
            currentStrainStored: strain, history: data.history,
            sleepNeedObservationCount: data.sleepNeedObservationCount))
    }

    nonisolated static func currentTrainingMetric(
        _ metric: TodayHealthSnapshot.Metric, snapshot: TodayHealthSnapshot, day: String,
        sourceIDs: Set<String>, now: Date
    ) -> Double? {
        guard let value = snapshot.metric(metric), value.metricDay == day,
              sourceIDs.contains(value.sourceId), value.value.isFinite, value.freshness != .stale else { return nil }
        let nowTs = Int(now.timeIntervalSince1970)
        guard value.observedAt.map({ $0 <= nowTs }) ?? true,
              value.rawFrontierTs.map({ $0 <= nowTs }) ?? true else { return nil }
        if metric == .strain {
            guard value.strainVersion == 2,
                  let frontier = value.rawFrontierTs ?? value.observedAt,
                  nowTs - frontier <= 3_600 else { return nil }
        }
        return value.value
    }
}
