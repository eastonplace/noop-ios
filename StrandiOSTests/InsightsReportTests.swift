import XCTest
import StrandAnalytics
import WhoopStore
@testable import NOOP

final class InsightsReportTests: XCTestCase {

    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    private func day(_ offset: Int) -> String { ExploreDayKey.key(forDayNumber: ExploreDayKey.dayNumber(for: "2026-05-01")! + offset) }

    private func ts(_ offset: Int, minutes: Int) -> Int {
        let base = utc.date(from: DateComponents(year: 2026, month: 5, day: 1))!
        return Int(base.timeIntervalSince1970) + offset * 86_400 + minutes * 60
    }

    /// Sixty nights alternating 22:40 and 23:50 onsets; early nights are followed by a morning
    /// about 12 points better. Strain and steps carry no signal.
    private func inputs() -> InsightsInputs {
        var i = InsightsInputs()
        i.calendar = utc
        var recovery: [String: Double] = [:]
        var sleep: [String: Double] = [:]
        for n in 0..<60 {
            let early = n % 2 == 0
            let onset = ts(n, minutes: early ? 1360 : 1430)
            i.nights.append(AutoFactorNight(wakeDay: day(n + 1), onsetTs: onset, endTs: onset + 7 * 3600))
            let noise = Double((n * 7) % 5) - 2
            recovery[day(n + 1)] = (early ? 66 : 54) + noise
            sleep[day(n + 1)] = 80 + noise
            i.days.append(AutoFactorDay(day: day(n + 1), totalSleepMin: 400 + Double((n * 13) % 60),
                                        strain: 30 + Double((n * 11) % 40), steps: 6000 + Double((n * 17) % 5000)))
        }
        i.outcomes = [.recovery: recovery, .sleep: sleep]
        return i
    }

    func testEarlyBedtimeBecomesAPlainSentence() throws {
        let report = InsightsReportBuilder.build(inputs())
        XCTAssertTrue(report.hasEnoughData)
        let row = try XCTUnwrap(report.significant.first { $0.source == .data(.earlyBedtime) && $0.outcome == .recovery })
        func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{202F}", with: " ") }
        XCTAssertEqual(plain(row.bedtime ?? ""), "11:30 PM")
        XCTAssertTrue(plain(row.sentence).hasPrefix("On nights you went to bed before 11:30 PM, your recovery averaged 12 points higher ("))
        XCTAssertTrue(row.sentence.hasSuffix(")."))
        XCTAssertEqual(row.deltaText, "+12 pts")
        XCTAssertEqual(plain(row.rowTitle), "In bed before 11:30 PM")
        XCTAssertTrue(row.detailLine.hasSuffix("30 vs 30 nights · Solid"))
        XCTAssertEqual(row.headline, "Your bedtime is linked with your recovery")
        XCTAssertEqual(plain(row.withLabel), "Before 11:30 PM")
        XCTAssertEqual(row.countsText, "30 vs 30 nights")
        XCTAssertEqual(row.source.label, "From your data")
        XCTAssertNotNil(row.effect.adjustedP)
        XCTAssertEqual(row.effect.lag, 0)
    }

    func testSleepLengthIsNeverTestedAgainstTheSleepScore() {
        let report = InsightsReportBuilder.build(inputs())
        XCTAssertFalse(report.rows.contains { $0.source == .data(.sevenHours) && $0.outcome == .sleep })
        XCTAssertTrue(report.rows.contains { $0.source == .data(.sevenHours) && $0.outcome == .recovery })
    }

    func testFactorsWithNoSignalAreListedAsUnclear() {
        let report = InsightsReportBuilder.build(inputs())
        let names = report.unclear.map(\.name)
        XCTAssertTrue(names.contains("High-strain day"))
        XCTAssertFalse(names.contains("Early bedtime"))
    }

    func testJournalAnswersRunThroughTheSameFamily() throws {
        var i = inputs()
        for n in 0..<60 {
            i.journal.append(JournalEntry(day: day(n + 1), question: "Did you drink any alcohol?",
                                          answeredYes: n % 2 == 1, notes: nil))
        }
        let report = InsightsReportBuilder.build(i)
        let row = try XCTUnwrap(report.significant.first { $0.source.isJournal && $0.outcome == .recovery })
        XCTAssertTrue(row.sentence.hasPrefix("On days you logged Alcohol, your recovery averaged"))
        XCTAssertTrue(row.sentence.contains("points lower ("))
        XCTAssertEqual(row.rowTitle, "Alcohol")
        XCTAssertTrue(row.deltaText.hasPrefix("\u{2212}"))
        XCTAssertEqual(row.source.label, "From your Journal")
    }

    func testJournalFactorsUseTheTileNames() {
        XCTAssertEqual(InsightWords.journalQuestionTitle("Did you drink any alcohol?"), "Alcohol")
        XCTAssertEqual(InsightWords.journalQuestionTitle("Did you have caffeine late in the day?"), "Late caffeine")
    }

    func testDoseRowsStartFromTheTypicalClearDay() {
        let outcome = Dictionary(uniqueKeysWithValues: (0..<10).map { (day($0), $0 < 6 ? 60.0 : 40.0) })
        let doses = Dictionary(uniqueKeysWithValues: (6..<10).map { (day($0), 2) })
        XCTAssertEqual(InsightsHubViewModel.typicalClearDay(outcome, doses: doses), 60)
    }

    func testInvalidOutcomeDaysDoNotCountAsHistory() {
        var i = InsightsInputs()
        i.outcomes = [.recovery: Dictionary(uniqueKeysWithValues: (0..<30).map { (day($0), Double.infinity) }),
                      .hrv: [day(0): .nan, day(1): 60]]
        let report = InsightsReportBuilder.build(i)
        XCTAssertEqual(report.daysOfData, 1)
        XCTAssertFalse(report.hasEnoughData)
        XCTAssertTrue(report.rows.isEmpty)
    }

    func testOutcomeFormattingRejectsNonfiniteAndUnrepresentableNumbers() {
        for value in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, Double(Int.max)] {
            let effect = BehaviorEffect(behavior: "test", outcome: "test", meanWith: value, meanWithout: value,
                                        delta: value, pctChange: value, nWith: 5, nWithout: 5,
                                        cohensD: 1, pApprox: 0.01, significant: true)
            for outcome in InsightOutcome.allCases {
                XCTAssertEqual(outcome.format(value), "—")
                XCTAssertEqual(outcome.amount(effect), "—")
                XCTAssertEqual(outcome.signedAmount(effect), "—")
                XCTAssertEqual(outcome.pair(effect), "— vs —")
            }
        }
        XCTAssertEqual(InsightOutcome.recovery.format(63.7), "64%")
    }

    func testSolidFindingsSortBeforeLargerBuildingEffects() {
        func row(_ name: String, confidence: ScoreConfidence, magnitude: Double) -> InsightRow {
            let effect = BehaviorEffect(behavior: name, outcome: "recovery", meanWith: 80, meanWithout: 60,
                                        delta: 20, pctChange: 33, nWith: 10, nWithout: 10,
                                        cohensD: magnitude, pApprox: 0.001, significant: true)
            return InsightRow(source: .journal(question: name), outcome: .recovery,
                              effect: RankedEffect(behavior: name, outcome: "recovery", lag: 0,
                                                   effect: effect, confidence: confidence, adjustedP: 0.01), bedtime: nil)
        }
        let report = InsightsReport(rows: [row("building", confidence: .building, magnitude: 5),
                                           row("solid", confidence: .solid, magnitude: 1)],
                                    daysOfData: 30, unclear: [])
        XCTAssertEqual(report.significant.map(\.source.factorID), ["journal.solid", "journal.building"])
    }

    func testTooLittleHistoryIsNotEnoughData() {
        var i = InsightsInputs()
        i.outcomes = [.recovery: Dictionary(uniqueKeysWithValues: (0..<10).map { (day($0), 60.0) })]
        let report = InsightsReportBuilder.build(i)
        XCTAssertFalse(report.hasEnoughData)
        XCTAssertTrue(report.significant.isEmpty)
    }
}

@MainActor
final class InsightsHistoryRepositoryTests: XCTestCase {
    func testSharedLoaderRejectsSourceAdoptionDuringColdStorePreparation() async throws {
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(try await WhoopStore.inMemory())
        let refresh = repo.refreshSeq
        var reachedPreparation = false
        repo.todayHealthSnapshotDatabaseIdentityReadHook = {
            repo.todayHealthSnapshotDatabaseIdentityReadHook = nil
            reachedPreparation = true
            XCTAssertTrue(repo.adoptActiveDeviceId("replacement-during-insights-open"))
        }
        var reachedInputs = false
        let report = await InsightsLoader.loadForTesting(repo: repo, afterInputs: { reachedInputs = true })
        XCTAssertTrue(reachedPreparation)
        XCTAssertFalse(reachedInputs, "A replaced owner must be rejected before input reads begin")
        XCTAssertEqual(repo.refreshSeq, refresh)
        XCTAssertEqual(report, .empty)
    }

    func testSharedLoaderRejectsRestoreDuringColdStorePreparation() async throws {
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(try await WhoopStore.inMemory())
        var reachedPreparation = false
        repo.todayHealthSnapshotDatabaseIdentityReadHook = {
            repo.todayHealthSnapshotDatabaseIdentityReadHook = nil
            reachedPreparation = true
            do { try await repo.quiesceStoreForRestore() }
            catch { XCTFail("In-memory restore quiesce failed: \(error)") }
        }
        var reachedInputs = false
        let report = await InsightsLoader.loadForTesting(repo: repo, afterInputs: { reachedInputs = true })
        XCTAssertTrue(reachedPreparation)
        XCTAssertFalse(reachedInputs, "A replaced owner must be rejected before input reads begin")
        XCTAssertNil(repo.todayHealthSnapshotDatabaseIdentityForTesting())
        XCTAssertEqual(report, .empty)
    }

    func testSharedLoaderRejectsSourceChangeAfterReadsAndAfterBuild() async throws {
        for switchAfterBuild in [false, true] {
            let store = try await WhoopStore.inMemory()
            let repo = Repository(deviceId: "my-whoop")
            repo.setStoreForTesting(store)
            let day = Repository.localDayKey(Date())
            let source = try XCTUnwrap(repo.computedReadIds.first)
            try await store.upsertDailyMetrics([
                DailyMetric(day: day, totalSleepMin: 420, efficiency: nil, deepMin: nil, remMin: nil,
                            lightMin: nil, disturbances: nil, restingHr: 55, avgHrv: 60, recovery: 80,
                            strain: 45, exerciseCount: nil)
            ], deviceId: source)
            let current = await InsightsLoader.load(repo: repo)
            XCTAssertEqual(current.daysOfData, 1)
            let refresh = repo.refreshSeq
            let changeSource: @MainActor () async -> Void = {
                XCTAssertTrue(repo.adoptActiveDeviceId("replacement-insights-source"))
                XCTAssertEqual(repo.refreshSeq, refresh, "Source adoption does not require a wearable refresh")
            }
            let stale = await InsightsLoader.loadForTesting(
                repo: repo, afterInputs: switchAfterBuild ? nil : changeSource,
                afterBuild: switchAfterBuild ? changeSource : nil)
            XCTAssertEqual(stale, .empty, "The shared loader must protect Coach as well as mounted views")
        }
    }

    func testEditedSleepScoreAndTimingFactorUseTheSameSnapshotAuthority() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        let computed = try XCTUnwrap(repo.computedReadIds.first)
        let imported = try XCTUnwrap(repo.importedReadIds.first)
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let day = Repository.localDayKey(today)
        let end = Int(today.addingTimeInterval(7 * 3_600).timeIntervalSince1970)
        let editedOnset = end - 10 * 3_600
        let importedNights = (0..<7).map { offset -> CachedSleepSession in
            let wake = calendar.date(byAdding: .day, value: -offset, to: today)!
            let wakeTs = Int(wake.addingTimeInterval(7 * 3_600).timeIntervalSince1970)
            return CachedSleepSession(startTs: wakeTs - 8 * 3_600, endTs: wakeTs,
                                      efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil)
        }
        try await store.upsertSleepSessions(importedNights, deviceId: imported)
        try await store.upsertSleepSessions([
            CachedSleepSession(startTs: end - 8 * 3_600, endTs: end, efficiency: nil, restingHr: nil,
                               avgHrv: nil, stagesJSON: nil, userEdited: true, startTsAdjusted: editedOnset)
        ], deviceId: computed)
        try await store.upsertMetricSeries([MetricPoint(day: day, key: "sleep_performance", value: 67)], deviceId: imported)
        try await store.upsertMetricSeries([MetricPoint(day: day, key: Repository.sleepPerformanceV2Key, value: 85)], deviceId: computed)
        let key = "sleep.performance.v2.mode"
        let prior = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(prior, forKey: key) }
        UserDefaults.standard.set("on", forKey: key)
        let inputs = await InsightsLoader.readInputs(repo: repo, now: now)
        XCTAssertEqual(inputs.outcomes[.sleep]?[day], 85)
        XCTAssertEqual(inputs.nights.count, 7)
        XCTAssertEqual(inputs.nights.first { $0.wakeDay == day }?.onsetTs, editedOnset)
        let factors = AutoFactors.derive(nights: inputs.nights, days: inputs.days, workouts: [], calendar: calendar)
        XCTAssertTrue(factors.splits[.earlyBedtime]?.yes.contains(day) == true)
        XCTAssertFalse(factors.splits[.earlyBedtime]?.no.contains(day) == true)
    }

    func testBluetoothHistoryUsesAll180PersistedDaysAndSelectedSleepModel() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        let source = try XCTUnwrap(repo.computedReadIds.first)
        let now = Date()
        let today = Repository.localDayKey(now)
        let rows = (0..<180).map { offset in
            DailyMetric(day: DailyTrainingTargetEngine.offsetDay(today, by: -offset)!,
                        totalSleepMin: 420, efficiency: 0.9, deepMin: 80, remMin: 100, lightMin: 240,
                        disturbances: 2, restingHr: 55, avgHrv: 60, recovery: 80,
                        strain: 45, exerciseCount: 1, strainVersion: 2)
        }
        try await store.upsertDailyMetrics(rows, deviceId: source)
        try await store.upsertMetricSeries(rows.flatMap { row in [
            MetricPoint(day: row.day, key: Repository.sleepPerformanceV2Key, value: 85),
            MetricPoint(day: row.day, key: "sleep_performance", value: 70),
            MetricPoint(day: row.day, key: Repository.sleepNeedV2Key, value: 480),
            MetricPoint(day: row.day, key: "noop_sleep_debt_need_v2_min", value: 60)
        ] }, deviceId: source)
        repo.days = Array(rows.prefix(30))
        let key = "sleep.performance.v2.mode"
        let prior = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(prior, forKey: key) }
        for mode in ["on", "shadow", "off"] {
            UserDefaults.standard.set(mode, forKey: key)
            let inputs = await InsightsLoader.readInputs(repo: repo, now: now)
            XCTAssertEqual(inputs.days.count, 180)
            for outcome in InsightOutcome.allCases { XCTAssertEqual(inputs.outcomes[outcome]?.count, 180) }
            XCTAssertEqual(inputs.outcomes[.sleep]?[today], mode == "on" ? 85 : 70)
            XCTAssertEqual(inputs.sleepLedgerNeedsByDay[today], 420, "Repayment cannot count as new debt")
            let result = AutoFactors.derive(nights: inputs.nights, days: inputs.days, workouts: inputs.workouts,
                                            calendar: inputs.calendar, sleepLedgerNeedsByDay: inputs.sleepLedgerNeedsByDay)
            XCTAssertTrue(result.splits[.sleepDebt]?.no.contains(today) == true)
            XCTAssertFalse(result.splits[.sleepDebt]?.yes.contains(today) == true)
        }
        // Imported vitals retain their established precedence across the full requested history.
        let imported = try XCTUnwrap(repo.importedReadIds.first)
        try await store.upsertDailyMetrics([rows[0].replacing(avgHrv: .some(75), recovery: .some(90))], deviceId: imported)
        try await store.upsertMetricSeries([MetricPoint(day: today, key: "sleep_performance", value: 67)], deviceId: imported)
        let result = await InsightsLoader.readInputs(repo: repo, now: now)
        XCTAssertEqual(result.outcomes[.sleep]?[today], 67)
        XCTAssertEqual(result.outcomes[.recovery]?[today], 90)
        XCTAssertEqual(result.outcomes[.hrv]?[today], 75)
        XCTAssertEqual(result.days.count, 180)
    }
}
