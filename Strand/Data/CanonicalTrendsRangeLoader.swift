// Add to Strand/Data. The screen calls this instead of treating the 30-day dashboard cache as all history.

import Foundation
import NoopPhase34Core
import WhoopStore
import StrandAnalytics

extension Repository {
    func loadCanonicalTrendsData(
        anchorDay: String,
        timeZoneIdentifier: String,
        rangeDays: Int,
        weekOffset: Int
    ) async -> TrendsLoadedData? {
        guard let store = await storeHandle(),
              let anchor = try? CivilDay(key: anchorDay),
              let timeZone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let anchorDate = try? anchor.date(in: calendar) else { return nil }

        let currentAndPrevious = max(2, rangeDays * 2)
        let weeklyBaseline = (8 + max(0, -weekOffset) + 2) * 7
        let requiredDays = max(42, currentAndPrevious, weeklyBaseline)
        guard let fromDate = calendar.date(byAdding: .day, value: -(requiredDays - 1), to: anchorDate),
              let sleepFrom = calendar.date(byAdding: .day, value: -1, to: fromDate),
              let sleepThrough = calendar.date(byAdding: .day, value: 2, to: anchorDate) else { return nil }
        let fromDay = Repository.localDayKey(fromDate, calendar: calendar)
        let sourceIds = importedReadIds + computedReadIds + [Self.appleHealthSource]

        let read: CanonicalHealthSurfaceStoreSnapshot
        do {
            read = try await store.canonicalHealthSurfaceSnapshot(
                sourceIds: sourceIds,
                fromDay: fromDay,
                throughDay: anchorDay,
                sleepFromTs: Int(sleepFrom.timeIntervalSince1970),
                sleepThroughTs: Int(sleepThrough.timeIntervalSince1970),
                metricKeys: ["sleep_performance", Self.sleepPerformanceV2Key, "stress"]
            )
        } catch { return nil }

        let imported = Set(importedReadIds)
        let computed = Set(computedReadIds)
        let healthCalendar: HealthCalendar
        do { healthCalendar = try HealthCalendar(timeZoneIdentifier: timeZoneIdentifier) }
        catch { return nil }
        let editedDays = Set(read.sleepRows.compactMap { row -> String? in
            guard row.session.userEdited, computed.contains(row.sourceId) else { return nil }
            return try? healthCalendar.civilDay(
                containing: Date(timeIntervalSince1970: TimeInterval(row.session.endTs))).key
        })
        let generation = Int64(max(1, refreshSeq + 1))
        let sleepRows: [PersistedSleepScoreRow] = read.metricRows.compactMap { row in
            let model: SleepScoreModel
            let modelVersion: String?
            if imported.contains(row.sourceId), row.key == "sleep_performance" {
                model = .importedWhoop; modelVersion = nil
            } else if computed.contains(row.sourceId), row.key == Self.sleepPerformanceV2Key {
                model = .noopV2; modelVersion = SleepPerformanceV2.modelVersion
            } else if computed.contains(row.sourceId), row.key == "sleep_performance" {
                model = .noopLegacy; modelVersion = "noop-sleep-performance-v1"
            } else { return nil }
            return PersistedSleepScoreRow(
                day: row.day, value: row.value, sourceId: row.sourceId,
                model: model, modelVersion: modelVersion, observedAt: nil,
                authorityRank: row.sourcePriority, generation: generation,
                isUserEditedAuthority: computed.contains(row.sourceId) && editedDays.contains(row.day)
            )
        }
        let stressRows = read.metricRows.compactMap { row -> PersistedScalarMetricRow? in
            guard row.key == "stress" else { return nil }
            return PersistedScalarMetricRow(
                day: row.day, value: row.value, sourceId: row.sourceId,
                authorityRank: row.sourcePriority, generation: generation)
        }
        let appleRows = read.appleDailyRows.map {
            CanonicalAppleDailyPoint(
                day: $0.day, sourceId: $0.sourceId, authorityRank: $0.sourcePriority,
                steps: $0.steps, activeKcal: $0.activeKcal, basalKcal: $0.basalKcal,
                vo2max: $0.vo2max, avgHr: $0.avgHr, maxHr: $0.maxHr,
                walkingHr: $0.walkingHr, weightKg: $0.weightKg)
        }
        guard let model = try? CanonicalHealthReadModelBuilder.build(
            mode: SleepPerformanceV2Prefs.mode,
            sleepRows: sleepRows,
            stressRows: stressRows,
            appleRows: appleRows,
            previous: .empty,
            sourceGeneration: generation
        ) else { return nil }

        let importedDaily = bestDaily(read.dailyRows.filter { imported.contains($0.sourceId) })
        let computedDaily = bestDaily(read.dailyRows.filter { computed.contains($0.sourceId) })
        let appleDaily = bestDaily(read.dailyRows.filter { $0.sourceId == Self.appleHealthSource })
        let merged = Repository.mergeDaily(
            imported: importedDaily, computed: computedDaily, userEditedDays: editedDays)
        let canonicalDays = Repository.mergeDaily(imported: merged, computed: appleDaily)

        return TrendsLoadedData(
            loadIdentity: TrendsLoadIdentity(
                revision: refreshSeq,
                anchorDay: anchorDay,
                timeZoneIdentifier: timeZoneIdentifier,
                rangeDays: rangeDays,
                weekOffset: weekOffset
            ),
            revision: refreshSeq,
            anchorDay: anchorDay,
            timeZoneIdentifier: timeZoneIdentifier,
            canonicalDays: canonicalDays,
            sleepPerfByDay: Dictionary(uniqueKeysWithValues: model.sleepSeries(
                from: fromDay, through: anchorDay).map { ($0.day, $0.value) }),
            stressByDay: Dictionary(uniqueKeysWithValues: model.stressSeries(
                from: fromDay, through: anchorDay).map { ($0.day, $0.value) }),
            appleDays: model.appleDailyByDay.values.map {
                AppleDaily(day: $0.day, steps: $0.steps, activeKcal: $0.activeKcal,
                           basalKcal: $0.basalKcal, vo2max: $0.vo2max, avgHr: $0.avgHr,
                           maxHr: $0.maxHr, walkingHr: $0.walkingHr, weightKg: $0.weightKg)
            }.sorted { $0.day < $1.day }
        )
    }

    private func bestDaily(_ rows: [StoredSourcedDailyMetric]) -> [DailyMetric] {
        Dictionary(grouping: rows, by: { $0.metric.day }).compactMapValues { candidates in
            candidates.max {
                ($0.sourcePriority, $0.sourceId) < ($1.sourcePriority, $1.sourceId)
            }?.metric
        }.values.sorted { $0.day < $1.day }
    }
}
