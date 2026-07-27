import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Privacy-safe, source-to-score receipt for one Recovery day. It deliberately carries counts and Boolean
/// gates only—no HR, R-R, HRV, RHR or Recovery values—so a user can share it without exporting raw health
/// data. Store and published-cache states are separate: `recovery=1 publishedRecovery=0` is a Repository/Home
/// freshness defect, while `scorerInputsReady=1 recovery=0` isolates analysis or persistence.
struct RecoveryReadinessReceipt: Equatable, Sendable {
    let day: String
    let storeAvailable: Bool
    let rawSourceCount: Int
    let hrRows: Int
    let rrRows: Int
    let validSleepSessions: Int
    let defensiblyStagedSessions: Int
    let rrRowsInsideSleep: Int
    /// The merged daily row exists in durable storage.
    let dailyRowPresent: Bool
    let hrvPresent: Bool
    let restingHRPresent: Bool
    let hrvBaselineNights: Int
    let hrvBaselineUsable: Bool
    let scorerInputsReady: Bool
    /// Recovery exists in the durable merged daily row.
    let recoveryPresent: Bool
    /// The long-lived Repository cache currently exposes this day/Recovery to Home.
    let publishedDailyRowPresent: Bool
    let publishedRecoveryPresent: Bool
    let repositoryRefreshSeq: Int

    init(
        day: String,
        storeAvailable: Bool,
        rawSourceCount: Int,
        hrRows: Int,
        rrRows: Int,
        validSleepSessions: Int,
        defensiblyStagedSessions: Int,
        rrRowsInsideSleep: Int,
        dailyRowPresent: Bool,
        hrvPresent: Bool,
        restingHRPresent: Bool,
        hrvBaselineNights: Int,
        hrvBaselineUsable: Bool,
        scorerInputsReady: Bool,
        recoveryPresent: Bool,
        publishedDailyRowPresent: Bool = false,
        publishedRecoveryPresent: Bool = false,
        repositoryRefreshSeq: Int = -1
    ) {
        self.day = day
        self.storeAvailable = storeAvailable
        self.rawSourceCount = rawSourceCount
        self.hrRows = hrRows
        self.rrRows = rrRows
        self.validSleepSessions = validSleepSessions
        self.defensiblyStagedSessions = defensiblyStagedSessions
        self.rrRowsInsideSleep = rrRowsInsideSleep
        self.dailyRowPresent = dailyRowPresent
        self.hrvPresent = hrvPresent
        self.restingHRPresent = restingHRPresent
        self.hrvBaselineNights = hrvBaselineNights
        self.hrvBaselineUsable = hrvBaselineUsable
        self.scorerInputsReady = scorerInputsReady
        self.recoveryPresent = recoveryPresent
        self.publishedDailyRowPresent = publishedDailyRowPresent
        self.publishedRecoveryPresent = publishedRecoveryPresent
        self.repositoryRefreshSeq = repositoryRefreshSeq
    }

    var line: String {
        "recoveryReceipt day=\(day) store=\(token(storeAvailable)) "
            + "rawSources=\(rawSourceCount) hrRows=\(hrRows) rrRows=\(rrRows) "
            + "validSleep=\(validSleepSessions) stagedSleep=\(defensiblyStagedSessions) "
            + "rrInSleep=\(rrRowsInsideSleep) daily=\(token(dailyRowPresent)) "
            + "hrv=\(token(hrvPresent)) rhr=\(token(restingHRPresent)) "
            + "baselineN=\(hrvBaselineNights) baselineUsable=\(token(hrvBaselineUsable)) "
            + "scorerInputsReady=\(token(scorerInputsReady)) recovery=\(token(recoveryPresent)) "
            + "publishedDaily=\(token(publishedDailyRowPresent)) "
            + "publishedRecovery=\(token(publishedRecoveryPresent)) refreshSeq=\(repositoryRefreshSeq)"
    }

    private func token(_ value: Bool) -> Int { value ? 1 : 0 }
}

extension DebugDataDiagnostics {
    /// Build the minimum redacted receipt needed to triage a missing Recovery. The raw read window and source
    /// union mirror IntelligenceEngine's current-day scan closely enough to answer the operational question:
    /// did source data exist, did it overlap a valid/staged sleep, were HRV/RHR and the baseline ready, did a
    /// Recovery row persist, and did Repository publish that row to Home? No measurement values leave here.
    @MainActor
    static func recoveryReadinessReceipt(
        repo: Repository,
        day explicitDay: String? = nil,
        now: Date = Date()
    ) async -> RecoveryReadinessReceipt {
        let logicalKey = Repository.logicalDayKey(now)
        let localKey = Repository.localDayKey(now)
        let targetDay = explicitDay
            ?? Repository.resolveToday(days: repo.days, logicalKey: logicalKey, localKey: localKey)?.day
            ?? logicalKey
        let published = repo.days.last(where: { $0.day == targetDay })

        guard let store = await repo.storeHandle(),
              let bounds = recoveryAnalysisBounds(day: targetDay, now: now) else {
            return RecoveryReadinessReceipt(
                day: targetDay,
                storeAvailable: false,
                rawSourceCount: 0,
                hrRows: 0,
                rrRows: 0,
                validSleepSessions: 0,
                defensiblyStagedSessions: 0,
                rrRowsInsideSleep: 0,
                dailyRowPresent: false,
                hrvPresent: false,
                restingHRPresent: false,
                hrvBaselineNights: 0,
                hrvBaselineUsable: false,
                scorerInputsReady: false,
                recoveryPresent: false,
                publishedDailyRowPresent: published != nil,
                publishedRecoveryPresent: published?.recovery != nil,
                repositoryRefreshSeq: repo.refreshSeq)
        }

        var hrByTimestamp: [Int: HRSample] = [:]
        var rrByTimestamp: [Int: RRInterval] = [:]
        var rawSourcesWithRows = 0
        for source in repo.importedReadIds {
            let bundle = try? await store.analysisDayBundle(
                deviceId: source,
                from: bounds.from,
                to: bounds.to,
                limit: 200_000)
            let hr = bundle?.hr ?? []
            let rr = bundle?.rr ?? []
            if !hr.isEmpty || !rr.isEmpty { rawSourcesWithRows += 1 }
            for row in hr where hrByTimestamp[row.ts] == nil { hrByTimestamp[row.ts] = row }
            for row in rr where rrByTimestamp[row.ts] == nil { rrByTimestamp[row.ts] = row }
        }

        var storedSessions: [CachedSleepSession] = []
        var seenSessionSources = Set<String>()
        for source in repo.importedReadIds + repo.computedReadIds where seenSessionSources.insert(source).inserted {
            storedSessions += (try? await store.sleepSessions(
                deviceId: source,
                from: bounds.from,
                to: bounds.to,
                limit: 4_000)) ?? []
        }
        let validSessions = SleepSessionDedup.dedupe(storedSessions.filter {
            SleepSessionWindow.isValid(start: $0.effectiveStartTs, end: $0.endTs)
        }).kept
        let stagedSessions = validSessions.filter { session in
            guard let totals = SleepStageTotals.minutes(fromStagesJSON: session.stagesJSON) else { return false }
            return totals.asleep > 0 && totals.inBed > 0
        }
        let rrInsideSleep = rrByTimestamp.values.filter { row in
            validSessions.contains { row.ts >= $0.effectiveStartTs && row.ts < $0.endTs }
        }.count

        var computedRows: [DailyMetric] = []
        var importedRows: [DailyMetric] = []
        for source in repo.computedReadIds {
            computedRows += (try? await store.dailyMetrics(
                deviceId: source, from: "0000-01-01", to: targetDay)) ?? []
        }
        for source in repo.importedReadIds {
            importedRows += (try? await store.dailyMetrics(
                deviceId: source, from: "0000-01-01", to: targetDay)) ?? []
        }
        let mergedHistory = SleepRecoveryHistoryMerge.merge(
            computed: computedRows,
            imported: importedRows)
        let storedCurrent = mergedHistory.last(where: { $0.day == targetDay })
        let prior = mergedHistory.filter { $0.day < targetDay }
        let hrvBaseline = Baselines.foldHistory(
            prior.map(\.avgHrv),
            dayKeys: prior.map(\.day),
            cfg: Baselines.hrvCfg)
        let hrvPresent = storedCurrent?.avgHrv != nil
        let rhrPresent = storedCurrent?.restingHr != nil
        let inputsReady = hrvPresent && rhrPresent && hrvBaseline.usable

        return RecoveryReadinessReceipt(
            day: targetDay,
            storeAvailable: true,
            rawSourceCount: rawSourcesWithRows,
            hrRows: hrByTimestamp.count,
            rrRows: rrByTimestamp.count,
            validSleepSessions: validSessions.count,
            defensiblyStagedSessions: stagedSessions.count,
            rrRowsInsideSleep: rrInsideSleep,
            dailyRowPresent: storedCurrent != nil,
            hrvPresent: hrvPresent,
            restingHRPresent: rhrPresent,
            hrvBaselineNights: hrvBaseline.nValid,
            hrvBaselineUsable: hrvBaseline.usable,
            scorerInputsReady: inputsReady,
            recoveryPresent: storedCurrent?.recovery != nil,
            publishedDailyRowPresent: published != nil,
            publishedRecoveryPresent: published?.recovery != nil,
            repositoryRefreshSeq: repo.refreshSeq)
    }

    @MainActor
    static func recoveryReadinessLines(repo: Repository, day: String? = nil) async -> [String] {
        let receipt = await recoveryReadinessReceipt(repo: repo, day: day)
        return [String(repeating: "─", count: 40), "Recovery readiness", receipt.line]
    }

    /// IntelligenceEngine uses a generous night window: 30 hours before the wake day and, for today, through
    /// 18:00 local (naturally capped at now); past days run through the next midnight. Keep the diagnostic on
    /// that same shape so a count mismatch is meaningful rather than a different-query artifact.
    private static func recoveryAnalysisBounds(day: String, now: Date) -> (from: Int, to: Int)? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        guard let dayStartDate = formatter.date(from: day) else { return nil }
        let dayStart = Int(dayStartDate.timeIntervalSince1970)
        let currentMidnight = Int(Calendar.current.startOfDay(for: now).timeIntervalSince1970)
        let (from, fromOverflow) = dayStart.subtractingReportingOverflow(30 * 3_600)
        let horizon = dayStart < currentMidnight ? 86_400 : 18 * 3_600
        let (uncappedTo, toOverflow) = dayStart.addingReportingOverflow(horizon)
        guard !fromOverflow, !toOverflow else { return nil }
        return (from, min(uncappedTo, Int(now.timeIntervalSince1970)))
    }
}
