// Add to Strand/Data. This pure builder consumes one post-analysis WAL snapshot.
// It never reads Repository's pre-analysis caches and never publishes before the SQLite commit succeeds.

import Foundation
import NoopPhase34Core
import WhoopStore
import StrandAnalytics

struct PostAnalysisTodaySnapshotInput: Sendable {
    let template: TodayHealthSnapshot
    /// Durable owner for the exact historical publication. The dashboard scope remains canonical.
    let ownerDeviceId: String
    let read: CanonicalHealthSurfaceStoreSnapshot
    let importedSourceIds: [String]
    let computedSourceIds: [String]
    let appleSourceId: String
    let sleepMode: SleepPerformanceV2Prefs.Mode
    let analysisGeneration: Int64
    let rawFrontierTs: Int?
    let recordedTimeZoneIdentifier: String
    let now: Date
}

enum PostAnalysisTodaySnapshotBuilderError: Error {
    case invalidContext
    case invalidGeneration
    case invalidTimeZone
    case invalidDay
}

enum RepositoryPostAnalysisSnapshotBuilder {
    static func build(_ input: PostAnalysisTodaySnapshotInput) throws -> TodayHealthSnapshot {
        guard let context = input.template.context,
              context.databaseInstanceId == input.read.databaseInstanceId,
              input.analysisGeneration > 0 else {
            throw PostAnalysisTodaySnapshotBuilderError.invalidContext
        }
        let calendar = try HealthCalendar(timeZoneIdentifier: input.recordedTimeZoneIdentifier)
        guard let displayDay = try? CivilDay(key: input.template.displayDay) else {
            throw PostAnalysisTodaySnapshotBuilderError.invalidDay
        }

        let importedIds = Set(input.importedSourceIds)
        let computedIds = Set(input.computedSourceIds)
        let importedRows = bestDailyRows(input.read.dailyRows.filter { importedIds.contains($0.sourceId) })
        let computedRows = bestDailyRows(input.read.dailyRows.filter { computedIds.contains($0.sourceId) })
        let appleRows = bestDailyRows(input.read.dailyRows.filter { $0.sourceId == input.appleSourceId })

        let editedWakeDays = try Set(input.read.sleepRows.compactMap { row -> String? in
            guard row.session.userEdited, computedIds.contains(row.sourceId) else { return nil }
            return try calendar.civilDay(
                containing: Date(timeIntervalSince1970: TimeInterval(row.session.endTs))
            ).key
        })

        let importedMetrics = importedRows.values.map(\.metric).sorted { $0.day < $1.day }
        let computedMetrics = computedRows.values.map(\.metric).sorted { $0.day < $1.day }
        let appleMetrics = appleRows.values.map(\.metric).sorted { $0.day < $1.day }
        let importedAndComputed = Repository.mergeDaily(
            imported: importedMetrics,
            computed: computedMetrics,
            userEditedDays: editedWakeDays
        )
        let allDaily = Repository.mergeDaily(imported: importedAndComputed, computed: appleMetrics)
        let base = allDaily.last(where: { $0.day == displayDay.key })
            ?? emptyDailyMetric(day: displayDay.key)

        let latestSleepEnd = latestSleepEndByDay(
            input.read.sleepRows,
            calendar: calendar
        )
        let recoverySource = winningDailyRow(
            day: displayDay.key,
            imported: importedRows,
            computed: computedRows,
            apple: appleRows,
            field: { $0.recovery }
        )
        let sleepDurationSource = winningSleepDurationRow(
            day: displayDay.key,
            editedWakeDays: editedWakeDays,
            imported: importedRows,
            computed: computedRows,
            apple: appleRows
        )
        let strainSource = computedRows[displayDay.key].flatMap { row in
            row.metric.strainVersion == 2 && row.metric.strain != nil ? row : nil
        }

        let sleepResolution = try canonicalSleepResolution(
            day: displayDay,
            read: input.read,
            importedSourceIds: importedIds,
            computedSourceIds: computedIds,
            editedWakeDays: editedWakeDays,
            mode: input.sleepMode,
            analysisGeneration: input.analysisGeneration,
            latestSleepEnd: latestSleepEnd
        )

        // The analysis journal is the durable frontier for this exact score commit. Keep a previously
        // committed frontier when this exact work had no HR rows, so a replay cannot move the snapshot back.
        let rawFrontier = max(input.template.rawFrontierTs ?? -1, input.rawFrontierTs ?? -1)
            .nonNegativeOptional
        let recovery = recoverySource.flatMap { row -> TodayHealthMetricValue? in
            guard let value = row.metric.recovery else { return nil }
            return TodayHealthMetricValue(
                value: value,
                metricDay: displayDay.key,
                sourceId: row.sourceId,
                observedAt: latestSleepEnd[displayDay.key],
                rawFrontierTs: rawFrontier,
                algorithmVersion: "daily-recovery-v1",
                generation: 0,
                freshness: freshness(
                    kind: .recovery,
                    metricDay: displayDay,
                    logicalDayKey: input.template.logicalDay,
                    observedAt: latestSleepEnd[displayDay.key],
                    now: input.now
                )
            )
        }
        let strain = strainSource.flatMap { row -> TodayHealthMetricValue? in
            guard let value = row.metric.strain else { return nil }
            return TodayHealthMetricValue(
                value: value,
                metricDay: displayDay.key,
                sourceId: row.sourceId,
                observedAt: rawFrontier,
                rawFrontierTs: rawFrontier,
                algorithmVersion: "strain-v2-daily",
                strainVersion: 2,
                generation: 0,
                freshness: freshness(
                    kind: .strain,
                    metricDay: displayDay,
                    logicalDayKey: input.template.logicalDay,
                    observedAt: rawFrontier,
                    now: input.now
                )
            )
        }
        let sleepDuration = sleepDurationSource.flatMap { row -> TodayHealthMetricValue? in
            guard let value = row.metric.totalSleepMin else { return nil }
            return TodayHealthMetricValue(
                value: value,
                metricDay: displayDay.key,
                sourceId: row.sourceId,
                observedAt: latestSleepEnd[displayDay.key],
                rawFrontierTs: rawFrontier,
                algorithmVersion: "daily-sleep-duration-v1",
                generation: 0,
                freshness: freshness(
                    kind: .sleepDurationMinutes,
                    metricDay: displayDay,
                    logicalDayKey: input.template.logicalDay,
                    observedAt: latestSleepEnd[displayDay.key],
                    now: input.now
                )
            )
        }
        let sleepScore = sleepResolution.production.map { point in
            TodayHealthMetricValue(
                value: point.value,
                metricDay: point.day.key,
                sourceId: point.sourceId,
                observedAt: point.observedAt ?? latestSleepEnd[point.day.key],
                rawFrontierTs: rawFrontier,
                algorithmVersion: point.modelVersion ?? point.model.rawValue,
                generation: 0,
                freshness: freshness(
                    kind: .sleepScore,
                    metricDay: point.day,
                    logicalDayKey: input.template.logicalDay,
                    observedAt: point.observedAt ?? latestSleepEnd[point.day.key],
                    now: input.now
                )
            )
        }

        let metricStates: [TodayHealthSnapshot.Metric: TodayHealthMetricState] = [
            .recovery: state(
                value: recovery,
                prior: input.template.recoveryState,
                carryPrior: true,
                metric: .recovery,
                displayDay: displayDay.key,
                now: input.now
            ),
            .strain: state(
                value: strain,
                prior: input.template.strainState,
                carryPrior: false,
                metric: .strain,
                displayDay: displayDay.key,
                now: input.now
            ),
            .sleepScore: state(
                value: sleepScore,
                prior: input.template.sleepScoreState,
                carryPrior: true,
                metric: .sleepScore,
                displayDay: displayDay.key,
                now: input.now
            ),
            .sleepDurationMinutes: state(
                value: sleepDuration,
                prior: input.template.sleepDurationMinutesState,
                carryPrior: true,
                metric: .sleepDurationMinutes,
                displayDay: displayDay.key,
                now: input.now
            ),
        ]

        // Keep this row truthful for its own day. Carried prior-night values stay only in metricStates.
        let daily = base.replacing(
            totalSleepMin: .some(sleepDuration?.value),
            recovery: .some(recovery?.value),
            strain: .some(strain?.value),
            strainVersion: .some(strain == nil ? nil : 2)
        )
        return TodayHealthSnapshot(
            scopeId: input.template.scopeId,
            context: context,
            deviceId: input.ownerDeviceId,
            displayDay: displayDay.key,
            logicalDay: input.template.logicalDay,
            localDay: input.template.localDay,
            generatedAt: Int(input.now.timeIntervalSince1970),
            rawFrontierTs: rawFrontier,
            generation: input.template.generation,
            schemaVersion: TodayHealthSnapshot.currentSchemaVersion,
            authoritativeMetrics: Set(metricStates.compactMap { $0.value.isAuthoritative ? $0.key : nil }),
            dailyMetric: daily,
            metricStates: metricStates
        )
    }

    private static func bestDailyRows(
        _ rows: [StoredSourcedDailyMetric]
    ) -> [String: StoredSourcedDailyMetric] {
        Dictionary(grouping: rows, by: { $0.metric.day }).compactMapValues { rows in
            rows.max { lhs, rhs in
                (lhs.sourcePriority, lhs.sourceId) < (rhs.sourcePriority, rhs.sourceId)
            }
        }
    }

    private static func winningDailyRow(
        day: String,
        imported: [String: StoredSourcedDailyMetric],
        computed: [String: StoredSourcedDailyMetric],
        apple: [String: StoredSourcedDailyMetric],
        field: (DailyMetric) -> Double?
    ) -> StoredSourcedDailyMetric? {
        for candidate in [imported[day], computed[day], apple[day]].compactMap({ $0 }) {
            if field(candidate.metric) != nil { return candidate }
        }
        return nil
    }

    private static func winningSleepDurationRow(
        day: String,
        editedWakeDays: Set<String>,
        imported: [String: StoredSourcedDailyMetric],
        computed: [String: StoredSourcedDailyMetric],
        apple: [String: StoredSourcedDailyMetric]
    ) -> StoredSourcedDailyMetric? {
        let order: [StoredSourcedDailyMetric?] = editedWakeDays.contains(day)
            ? [computed[day], imported[day], apple[day]]
            : [imported[day], computed[day], apple[day]]
        return order.compactMap({ $0 }).first { $0.metric.totalSleepMin != nil }
    }

    private static func canonicalSleepResolution(
        day: CivilDay,
        read: CanonicalHealthSurfaceStoreSnapshot,
        importedSourceIds: Set<String>,
        computedSourceIds: Set<String>,
        editedWakeDays: Set<String>,
        mode: SleepPerformanceV2Prefs.Mode,
        analysisGeneration: Int64,
        latestSleepEnd: [String: Int]
    ) throws -> CanonicalSleepScoreResolution {
        let coreMode: SleepScoreMode
        switch mode {
        case .off: coreMode = .off
        case .shadow: coreMode = .shadow
        case .on: coreMode = .on
        }
        var imported: [SleepScoreCandidate] = []
        var v2: [SleepScoreCandidate] = []
        var legacy: [SleepScoreCandidate] = []
        for row in read.metricRows where row.day == day.key {
            let model: SleepScoreModel?
            if importedSourceIds.contains(row.sourceId), row.key == "sleep_performance" {
                model = .importedWhoop
            } else if computedSourceIds.contains(row.sourceId),
                      row.key == Repository.sleepPerformanceV2Key {
                model = .noopV2
            } else if computedSourceIds.contains(row.sourceId), row.key == "sleep_performance" {
                model = .noopLegacy
            } else {
                model = nil
            }
            guard let model,
                  let candidate = try? SleepScoreCandidate(
                    day: day,
                    value: row.value,
                    sourceId: row.sourceId,
                    model: model,
                    modelVersion: model == .noopV2 ? SleepPerformanceV2.modelVersion : nil,
                    observedAt: latestSleepEnd[day.key],
                    generation: analysisGeneration,
                    authorityRank: row.sourcePriority,
                    isUserEditedAuthority: computedSourceIds.contains(row.sourceId)
                        && editedWakeDays.contains(day.key)
                  ) else { continue }
            switch model {
            case .importedWhoop: imported.append(candidate)
            case .noopV2: v2.append(candidate)
            case .noopLegacy: legacy.append(candidate)
            case .provisionalComposite: break
            }
        }
        return try CanonicalSleepScoreResolver.resolve(
            day: day,
            mode: coreMode,
            imported: imported,
            v2: v2,
            legacy: legacy
        )
    }

    private static func latestSleepEndByDay(
        _ rows: [StoredSourcedSleepSession],
        calendar: HealthCalendar
    ) -> [String: Int] {
        var result: [String: Int] = [:]
        for row in rows {
            guard let day = try? calendar.civilDay(
                containing: Date(timeIntervalSince1970: TimeInterval(row.session.endTs))
            ) else { continue }
            result[day.key] = max(result[day.key] ?? row.session.endTs, row.session.endTs)
        }
        return result
    }

    private static func state(
        value: TodayHealthMetricValue?,
        prior: TodayHealthMetricState,
        carryPrior: Bool,
        metric: TodayHealthSnapshot.Metric,
        displayDay: String,
        now: Date
    ) -> TodayHealthMetricState {
        if let value { return .value(value) }
        if carryPrior, let priorValue = prior.value,
           let priorDay = priorValue.metricDay, priorDay < displayDay {
            return .value(TodayHealthMetricValue(
                value: priorValue.value,
                metricDay: priorDay,
                sourceId: priorValue.sourceId,
                observedAt: priorValue.observedAt,
                rawFrontierTs: priorValue.rawFrontierTs,
                algorithmVersion: priorValue.algorithmVersion,
                strainVersion: priorValue.strainVersion,
                generation: priorValue.generation,
                freshness: .aging
            ))
        }
        return .unavailable(TodayHealthUnavailableEvidence(
            metricDay: displayDay,
            sourceId: "canonical-complete-read",
            reason: .absent,
            observedAt: max(0, Int(now.timeIntervalSince1970)),
            rawFrontierTs: nil,
            algorithmVersion: "canonical-absence-\(metric.rawValue)-v1",
            generation: 0
        ))
    }

    private static func freshness(
        kind: TodayHealthSnapshot.Metric,
        metricDay: CivilDay,
        logicalDayKey: String,
        observedAt: Int?,
        now: Date
    ) -> TodayHealthMetricFreshness {
        if kind == .strain, metricDay.key != logicalDayKey { return .stale }
        if metricDay.key < logicalDayKey { return .aging }
        guard let observedAt else { return kind == .strain ? .stale : .aging }
        return now.timeIntervalSince1970 - TimeInterval(observedAt) <= 3_600 ? .fresh : .aging
    }

    private static func emptyDailyMetric(day: String) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: nil,
            efficiency: nil,
            deepMin: nil,
            remMin: nil,
            lightMin: nil,
            disturbances: nil,
            restingHr: nil,
            avgHrv: nil,
            recovery: nil,
            strain: nil,
            exerciseCount: nil
        )
    }
}

private extension Int {
    var nonNegativeOptional: Int? { self >= 0 ? self : nil }
}
