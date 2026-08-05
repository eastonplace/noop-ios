// Add to Strand/Data.

import Foundation
import NoopPhase34Core
import WhoopStore

enum RepositoryHistoricalHealthKitPayloadBuilder {
    struct Input: Sendable {
        let contextId: String
        let deviceId: String
        let analysisGeneration: Int64
        let recordedTimeZoneIdentifier: String
        let changedDays: Set<CivilDay>
        let read: CanonicalHealthSurfaceStoreSnapshot
        let importedSourceIds: Set<String>
        let computedSourceIds: Set<String>
    }

    static func build(_ input: Input) throws -> HistoricalHealthKitMutationPayload {
        let calendar = try HealthCalendar(timeZoneIdentifier: input.recordedTimeZoneIdentifier)
        let changedKeys = Set(input.changedDays.map(\.key))

        let imported = bestDailyRows(input.read.dailyRows.filter {
            input.importedSourceIds.contains($0.sourceId)
        })
        let computed = bestDailyRows(input.read.dailyRows.filter {
            input.computedSourceIds.contains($0.sourceId)
        })
        let sleepRows = selectedSleepRows(
            input.read.sleepRows,
            changedKeys: changedKeys,
            importedSourceIds: input.importedSourceIds,
            computedSourceIds: input.computedSourceIds,
            calendar: calendar
        )

        var wakeByDay: [String: Int] = [:]
        for row in sleepRows {
            let day = try calendar.civilDay(
                containing: Date(timeIntervalSince1970: TimeInterval(row.session.endTs))
            ).key
            wakeByDay[day] = max(wakeByDay[day] ?? row.session.endTs, row.session.endTs)
        }

        let daily = try input.changedDays.sorted().compactMap { day -> HistoricalHealthKitDailyMutation? in
            let importedRow = imported[day.key]?.metric
            let computedRow = computed[day.key]?.metric
            let rhr = importedRow?.restingHr ?? computedRow?.restingHr
            let hrv = importedRow?.avgHrv ?? computedRow?.avgHrv
            let spo2 = importedRow?.spo2Pct ?? computedRow?.spo2Pct
            let respiration = importedRow?.respRateBpm ?? computedRow?.respRateBpm
            guard rhr != nil || hrv != nil || spo2 != nil || respiration != nil else { return nil }
            return try HistoricalHealthKitDailyMutation(
                day: day,
                wakeTimestamp: wakeByDay[day.key],
                restingHR: rhr,
                hrvMilliseconds: hrv,
                oxygenSaturationPercent: spo2,
                respiratoryRate: respiration
            )
        }

        let sleep = try sleepRows.map { row in
            try HistoricalHealthKitSleepMutation(
                stableStartTimestamp: row.session.startTs,
                effectiveStartTimestamp: row.session.effectiveStartTs,
                endTimestamp: row.session.endTs,
                stagesJSON: row.session.stagesJSON
            )
        }

        return try HistoricalHealthKitMutationPayload(
            contextId: input.contextId,
            deviceId: input.deviceId,
            analysisGeneration: input.analysisGeneration,
            recordedTimeZoneIdentifier: input.recordedTimeZoneIdentifier,
            changedDays: input.changedDays,
            dailyMutations: daily,
            sleepMutations: sleep
        )
    }

    private static func bestDailyRows(
        _ rows: [StoredSourcedDailyMetric]
    ) -> [String: StoredSourcedDailyMetric] {
        Dictionary(grouping: rows, by: { $0.metric.day }).compactMapValues { candidates in
            candidates.max {
                ($0.sourcePriority, $0.sourceId) < ($1.sourcePriority, $1.sourceId)
            }
        }
    }

    private static func selectedSleepRows(
        _ rows: [StoredSourcedSleepSession],
        changedKeys: Set<String>,
        importedSourceIds: Set<String>,
        computedSourceIds: Set<String>,
        calendar: HealthCalendar
    ) -> [StoredSourcedSleepSession] {
        var byStableStart: [Int: StoredSourcedSleepSession] = [:]
        for row in rows {
            guard row.session.endTs > row.session.effectiveStartTs,
                  let day = try? calendar.civilDay(
                    containing: Date(timeIntervalSince1970: TimeInterval(row.session.endTs))
                  ),
                  changedKeys.contains(day.key) else { continue }
            guard importedSourceIds.contains(row.sourceId) || computedSourceIds.contains(row.sourceId) else {
                continue
            }
            let existing = byStableStart[row.session.startTs]
            if existing == nil || sleepRank(row, imported: importedSourceIds, computed: computedSourceIds)
                > sleepRank(existing!, imported: importedSourceIds, computed: computedSourceIds) {
                byStableStart[row.session.startTs] = row
            }
        }
        return byStableStart.values.sorted {
            ($0.session.effectiveStartTs, $0.session.endTs, $0.sourceId)
                < ($1.session.effectiveStartTs, $1.session.endTs, $1.sourceId)
        }
    }

    private static func sleepRank(
        _ row: StoredSourcedSleepSession,
        imported: Set<String>,
        computed: Set<String>
    ) -> (Int, Int, String) {
        let classRank: Int
        if row.session.userEdited, computed.contains(row.sourceId) { classRank = 3 }
        else if imported.contains(row.sourceId) { classRank = 2 }
        else { classRank = 1 }
        return (classRank, row.sourcePriority, row.sourceId)
    }
}
