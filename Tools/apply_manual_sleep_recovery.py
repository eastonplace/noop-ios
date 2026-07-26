#!/usr/bin/env python3
"""Apply the small cross-cutting edits for the manual sleep-window recovery PR.

The GitHub connector can create files but cannot apply line patches to large existing
Swift files. CI runs this deterministic, idempotent patcher on the PR branch, tests the
result, and commits only a green generated diff. Remove this helper before merging.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def write(path: str, text: str) -> None:
    (ROOT / path).write_text(text, encoding="utf-8")


def replace_once(path: str, old: str, new: str) -> None:
    text = read(path)
    if new in text:
        return
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{path}: expected one patch anchor, found {count}: {old[:90]!r}")
    write(path, text.replace(old, new, 1))


def regex_replace_once(path: str, pattern: str, replacement: str) -> None:
    text = read(path)
    compiled = re.compile(pattern, re.DOTALL)
    matches = list(compiled.finditer(text))
    if len(matches) != 1:
        raise RuntimeError(f"{path}: expected one regex match, found {len(matches)}")
    write(path, compiled.sub(replacement, text, count=1))


# ── WhoopStore v31 provenance ─────────────────────────────────────────────────
replace_once(
    "Packages/WhoopStore/Sources/WhoopStore/WhoopStore.swift",
    "    public static let schemaVersion = 30\n",
    "    public static let schemaVersion = 31\n",
)

migration = '''        // v31: provenance for detector retries and user-bounded sleep reprocessing. The table stores
        // summary metadata only; raw physiology remains in the existing device-scoped sample tables.
        migrator.registerMigration("v31-sleep-window-recovery") { db in
            try db.create(table: "sleepRecoveryAttempt") { t in
                t.column("id", .text).primaryKey()
                t.column("deviceId", .text).notNull()
                t.column("source", .text).notNull()
                t.column("requestedStartTs", .integer).notNull()
                t.column("requestedEndTs", .integer).notNull()
                t.column("outcome", .text).notNull()
                t.column("confidence", .double).notNull()
                t.column("reason", .text).notNull()
                t.column("resultStartTs", .integer)
                t.column("resultEndTs", .integer)
                t.column("stagesAvailable", .boolean).notNull().defaults(to: false)
                t.column("restingHr", .integer)
                t.column("avgHrv", .double)
                t.column("algorithmVersion", .text).notNull()
                t.column("createdAt", .integer).notNull()
                t.column("updatedAt", .integer).notNull()
            }
            try db.create(index: "idx_sleepRecoveryAttempt_device_updated",
                          on: "sleepRecoveryAttempt", columns: ["deviceId", "updatedAt"])
            try db.create(index: "idx_sleepRecoveryAttempt_device_window",
                          on: "sleepRecoveryAttempt",
                          columns: ["deviceId", "requestedStartTs", "requestedEndTs"])
        }
'''
database_path = "Packages/WhoopStore/Sources/WhoopStore/Database.swift"
database_text = read(database_path)
if "v31-sleep-window-recovery" not in database_text:
    replace_once(database_path, "        return migrator\n", migration + "        return migrator\n")

replace_once(
    "Packages/WhoopStore/Sources/WhoopStore/DeviceRegistryStore.swift",
    '        "ppgWaveformSample", "strainV2Shadow",\n',
    '        "ppgWaveformSample", "strainV2Shadow", "sleepRecoveryAttempt",\n',
)
replace_once(
    "Packages/WhoopStore/Tests/WhoopStoreTests/MetricsCacheTests.swift",
    "        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 30)\n",
    "        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 31)\n",
)

# The recovery extension is in a separate file, so these two seams must be module-internal.
replace_once(
    "Strand/Data/Repository.swift",
    "    private var computedDeviceId: String { deviceId + \"-noop\" }\n",
    "    var computedDeviceId: String { deviceId + \"-noop\" }\n",
)
replace_once(
    "Strand/Data/Repository.swift",
    "    private func ensureStore() async -> WhoopStore? {\n",
    "    func ensureStore() async -> WhoopStore? {\n",
)

# ── Make corrected-window vitals flow into daily Charge inputs ─────────────────
new_sleep_edited_daily = '''    private func sleepEditedDaily(_ daily: DailyMetric, detected: [CachedSleepSession],
                                  editsByStart: [Int: CachedSleepSession],
                                  habitualMidsleepSec: Int?) -> DailyMetric {
        guard !editsByStart.isEmpty else { return daily }
        let editedRows = Array(editsByStart.values)
        let vitalFold = SleepEditVitalFold.fold(
            detected: detected,
            edits: editedRows,
            fallbackRestingHr: daily.restingHr,
            fallbackAvgHrv: daily.avgHrv)

        let detectedTuples = detected.map { (startTs: $0.startTs, stagesJSON: $0.stagesJSON) }
        let editedStages = editsByStart.mapValues { $0.stagesJSON }
        // A hand-logged block has no detected twin. Keep it in the union so a recovered
        // missed night can become the day's main sleep without double-counting a detector row.
        let detectedStarts = Set(detected.map(\\.startTs))
        let manualTuples = editsByStart
            .filter { !detectedStarts.contains($0.key) }
            .map { (startTs: $0.key, stagesJSON: $0.value.stagesJSON) }
        var onsetByStart: [Int: Int] = [:]
        for d in detected {
            onsetByStart[d.startTs] = editsByStart[d.startTs]?.effectiveStartTs ?? d.effectiveStartTs
        }
        for (start, edit) in editsByStart where !detectedStarts.contains(start) {
            onsetByStart[start] = edit.effectiveStartTs
        }

        let stageResult = SleepStageTotals.dailyAggregateHonoringEdits(
            detected: detectedTuples,
            edited: editedStages,
            manual: manualTuples,
            onsetByStart: onsetByStart,
            offsetSec: TimeZone.current.secondsFromGMT(),
            habitualMidsleepSec: habitualMidsleepSec)
        if let stageResult, stageResult.editApplied {
            let aggregate = stageResult.sleep
            return daily.with(
                totalSleepMin: aggregate.totalSleepMin,
                efficiency: aggregate.efficiency,
                deepMin: aggregate.deepMin,
                remMin: aggregate.remMin,
                lightMin: aggregate.lightMin,
                restingHr: vitalFold.restingHr,
                avgHrv: vitalFold.avgHrv)
        }

        // Partial recovery: real RHR/HRV can be defensible even when motion was too sparse
        // to assert stages or total sleep. Preserve the existing sleep fields and update only
        // the vitals; unknown stage data remains unknown.
        guard vitalFold.didApply else { return daily }
        return daily.with(
            totalSleepMin: daily.totalSleepMin,
            efficiency: daily.efficiency,
            deepMin: daily.deepMin,
            remMin: daily.remMin,
            lightMin: daily.lightMin,
            restingHr: vitalFold.restingHr,
            avgHrv: vitalFold.avgHrv)
    }
'''
regex_replace_once(
    "Strand/Data/IntelligenceEngine.swift",
    r"    private func sleepEditedDaily\(_ daily: DailyMetric, detected: \[CachedSleepSession\],.*?(?=\n    private nonisolated static func effectiveSleepSessions)",
    new_sleep_edited_daily.rstrip(),
)

old_daily_copy = '''    func with(totalSleepMin tsm: Double?, efficiency eff: Double?,
              deepMin dm: Double?, remMin rm: Double?, lightMin lm: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: tsm, efficiency: eff, deepMin: dm, remMin: rm, lightMin: lm,
                    disturbances: disturbances, restingHr: restingHr, avgHrv: avgHrv, recovery: recovery,
                    strain: strain, exerciseCount: exerciseCount, spo2Pct: spo2Pct,
                    skinTempDevC: skinTempDevC, respRateBpm: respRateBpm, steps: steps,
                    activeKcalEst: activeKcalEst, spo2Red: spo2Red, spo2Ir: spo2Ir)
    }
'''
new_daily_copy = '''    func with(totalSleepMin tsm: Double?, efficiency eff: Double?,
              deepMin dm: Double?, remMin rm: Double?, lightMin lm: Double?,
              restingHr rhr: Int?, avgHrv hrv: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: tsm, efficiency: eff, deepMin: dm, remMin: rm, lightMin: lm,
                    disturbances: disturbances, restingHr: rhr, avgHrv: hrv, recovery: recovery,
                    strain: strain, exerciseCount: exerciseCount, spo2Pct: spo2Pct,
                    skinTempDevC: skinTempDevC, respRateBpm: respRateBpm, steps: steps,
                    activeKcalEst: activeKcalEst, spo2Red: spo2Red, spo2Ir: spo2Ir)
    }
'''
replace_once("Strand/Data/IntelligenceEngine.swift", old_daily_copy, new_daily_copy)

# ── Sleep screen state, sheet, retry, result alert and empty-state card ─────────
state_anchor = '''    @State private var addNap: AddNapSeed?
'''
state_replacement = '''    @State private var addNap: AddNapSeed?
    /// The bounded overnight interval currently being reviewed after auto-detection missed it.
    @State private var missedSleepWindow: MissedSleepWindowSeed?
    /// Prevent duplicate forced rescoring while the Retry button is active.
    @State private var retryingSleepDetection = false
    /// Honest result from retry/manual-window processing.
    @State private var sleepRecoveryNotice: SleepRecoveryNotice?
'''
replace_once("Strand/Screens/SleepView.swift", state_anchor, state_replacement)

sheet_insertion = '''            .sheet(item: $missedSleepWindow) { seed in
                SleepTimeEditor(
                    bedTs: Int(seed.start.timeIntervalSince1970),
                    wakeTs: Int(seed.end.timeIntervalSince1970),
                    title: "Recover missed sleep",
                    blurb: "Set the window you were in bed. NOOP will review the recorded physiology inside it, determine what it can defend, and regenerate Rest and Charge.",
                    bedLabel: "In bed",
                    wakeLabel: "Woke up"
                ) { startTs, endTs in
                    let result = await repo.recoverMissedSleep(startTs: startTs, endTs: endTs)
                    if result.savedSession {
                        await intelligence.analyzeRecent(maxDays: 3, force: true)
                        _ = await repo.refresh(.recentDashboard(days: 120))
                    }
                    let confidenceSuffix = result.confidence.map {
                        " Detection confidence: \\(Int(($0 * 100).rounded()))%."
                    } ?? ""
                    sleepRecoveryNotice = SleepRecoveryNotice(
                        title: result.title,
                        message: result.message + confidenceSuffix)
                }
            }
'''
sleep_view = read("Strand/Screens/SleepView.swift")
if ".sheet(item: $missedSleepWindow)" not in sleep_view:
    replace_once(
        "Strand/Screens/SleepView.swift",
        "            }\n        }\n        .paperToast(\n",
        "            }\n" + sheet_insertion + "        }\n        .paperToast(\n",
    )

replace_once(
    "Strand/Screens/SleepView.swift",
    '''        .onDisappear {
''',
    '''        .alert(item: $sleepRecoveryNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK")))
        }
        .onDisappear {
''',
)

replace_once(
    "Strand/Screens/SleepView.swift",
    '            ComingSoon(what: "No nights here yet. Import your WHOOP export in Data Sources to see every night, your sleep stages and trends straight away. Or open Intelligence to see last night computed from the strap after you wear it to bed.")\n',
    '''            MissedSleepRecoveryCard(
                isRetrying: retryingSleepDetection,
                onRetry: { Task { await retrySleepDetection() } },
                onSetWindow: { missedSleepWindow = .lastNight() })
''',
)

retry_method = '''    /// Give the unchanged automatic detector one explicit forced pass over the last three days.
    /// If it still cannot defend a session, the user can constrain the interval instead.
    private func retrySleepDetection() async {
        guard !retryingSleepDetection else { return }
        retryingSleepDetection = true
        defer { retryingSleepDetection = false }

        let seed = MissedSleepWindowSeed.lastNight()
        let requestedStart = Int(seed.start.timeIntervalSince1970)
        let requestedEnd = Int(seed.end.timeIntervalSince1970)
        await intelligence.analyzeRecent(maxDays: 3, force: true)
        _ = await repo.refresh(.recentDashboard(days: 120))

        let refreshed = await repo.allSleepSessions()
        let recovered = refreshed
            .filter { $0.effectiveStartTs < requestedEnd && requestedStart < $0.endTs }
            .max { lhs, rhs in
                (lhs.endTs - lhs.effectiveStartTs) < (rhs.endTs - rhs.effectiveStartTs)
            }
        await repo.recordSleepDetectionRetry(
            requestedStartTs: requestedStart,
            requestedEndTs: requestedEnd,
            recoveredSession: recovered)

        allSessions = refreshed
        habitualMidsleepSec = await repo.habitualMidsleepSec()
        motionByStart = await repo.sessionMotions(starts: refreshed.map(\\.startTs))
        nightOffset = 0
        navNight = nil
        selectedStage = nil
        modelKey = dataKey
        model = buildModel()

        if recovered != nil {
            sleepRecoveryNotice = SleepRecoveryNotice(
                title: "Sleep detected",
                message: "NOOP found the night on a fresh pass and regenerated the day's Rest and Charge from the recorded data.")
        } else {
            sleepRecoveryNotice = SleepRecoveryNotice(
                title: "Still not enough confidence",
                message: "Automatic detection still could not defend a sleep session. Set the sleep window to narrow the search without inventing stages or vitals.")
        }
    }

'''
sleep_view = read("Strand/Screens/SleepView.swift")
if "private func retrySleepDetection() async" not in sleep_view:
    replace_once(
        "Strand/Screens/SleepView.swift",
        "    // MARK: - 0. REST HERO — scenic backdrop + sleep-performance gauge (Bevel)\n",
        retry_method + "    // MARK: - 0. REST HERO — scenic backdrop + sleep-performance gauge (Bevel)\n",
    )

print("manual sleep recovery patches applied")
