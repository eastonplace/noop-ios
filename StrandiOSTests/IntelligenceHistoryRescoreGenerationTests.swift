#if targetEnvironment(simulator)
import XCTest
import GRDB
import StrandAnalytics
import WhoopProtocol
import WhoopStore
@testable import NOOP

/// A completed older upgrade must not strand rows scored with the earlier R-R and nightly physiology rules.
/// Exercise real durable progress and AppModel background admission with autonomous startup disabled.
/// Launch bootstrap is separate; old rows and defaults stay intact.
@MainActor
final class IntelligenceHistoryRescoreGenerationTests: XCTestCase {
    private let oldDoneKey = "intelligence.strainV2CalendarHistory.v3.done"
    private let oldOffsetKey = "intelligence.strainV2CalendarHistory.v3.offset"
    private let oldMainKey = "effort-rescore-v3"
    private let oldSettleKey = "effort-rescore-v3-settle"
    private let oldCompletedOffset = 4_000

    private func withCompletedPreviousDefaults(_ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let keys = [oldDoneKey, oldOffsetKey,
                    IntelligenceEngine.effortRescoreFlagKey, IntelligenceEngine.effortRescoreOffsetKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        for key in keys { defaults.removeObject(forKey: key) }
        defaults.set(true, forKey: oldDoneKey)
        defaults.set(oldCompletedOffset, forKey: oldOffsetKey)
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        try await body()
    }

    private func upgradedModel() async throws -> (store: WhoopStore, model: AppModel) {
        let store = try await WhoopStore.inMemory()
        _ = try await store.markDurableMigrationComplete(key: oldMainKey, nextOffset: oldCompletedOffset)
        _ = try await store.markDurableMigrationComplete(key: oldSettleKey, nextOffset: oldCompletedOffset)
        let now = Int(Date().timeIntervalSince1970)
        var streams = Streams()
        for ts in stride(from: now - 3 * 86_400, to: now - 600, by: 60) {
            streams.hr.append(HRSample(ts: ts, bpm: 58 + ts % 9))
            streams.gravity.append(GravitySample(ts: ts, x: 0, y: 0, z: 1))
        }
        _ = try await store.insert(streams, deviceId: Repository.whoopSource)
        let model = AppModel(startRuntimeTasks: false)
        model.repo.setStoreForTesting(store)
        model.repo.loaded = true
        model.isGenuinelyBackground = { true }
        model.isLowPowerModeEnabled = { false }
        return (store, model)
    }

    private func dispositionAfterReceiptDrain(historyPending: Bool)
        -> HistoricalScoringBackgroundTaskRegistrar.CompletionDisposition {
        HistoricalScoringBackgroundTaskRegistrar.completionDisposition(
            for: HistoricalPipelineRuntimeResult(
                admittedReceipts: 0, completedWork: 1, deferredWork: 0, pendingWork: 0, alreadyRunning: false),
            healthImportPending: false,
            healthScoringPending: false,
            effortRescorePending: historyPending)
    }

    func testCompletedPreviousGenerationRunsNewMainThenSettleWithoutInheritingItsCursor() async throws {
        try await withCompletedPreviousDefaults {
            let (store, model) = try await upgradedModel()
            let mainKey = IntelligenceEngine.effortRescoreDurableProgressKey
            let settleKey = IntelligenceEngine.effortRescoreSettleDurableProgressKey

            let initiallyPending = await model.effortRescoreIsPending()
            XCTAssertTrue(initiallyPending, "old completion must not suppress the corrected analytics generation")
            XCTAssertEqual(dispositionAfterReceiptDrain(historyPending: initiallyPending), .retry,
                           "drained receipts must keep the shared request armed for the new main pass")

            await model.runEffortRescoreForBackgroundTask(maxChunks: 1)
            let main = try await store.durableMigrationProgress(key: mainKey)
            XCTAssertEqual(main?.state, .complete, "three days finish in one existing grant")
            XCTAssertGreaterThan(main?.nextOffset ?? 0, 0)
            XCTAssertLessThanOrEqual(main?.nextOffset ?? Int.max, IntelligenceEngine.effortRescoreChunkDays,
                                    "the prior 4,000-day cursor must not skip the new source-backed pass")
            let settleBeforeItsGrant = try await store.durableMigrationProgress(key: settleKey)
            XCTAssertNil(settleBeforeItsGrant, "settlement starts on a later grant after the new main pass")
            let pendingSettlement = await model.effortRescoreIsPending()
            XCTAssertTrue(pendingSettlement, "old settlement completion must not suppress the new settlement")
            XCTAssertEqual(dispositionAfterReceiptDrain(historyPending: pendingSettlement), .retry,
                           "the same request stays armed until the new settlement completes")

            await model.runEffortRescoreForBackgroundTask(maxChunks: 1)
            let settle = try await store.durableMigrationProgress(key: settleKey)
            XCTAssertEqual(settle?.state, .complete)
            XCTAssertEqual(settle?.nextOffset, main?.nextOffset)
            let finallyPending = await model.effortRescoreIsPending()
            XCTAssertFalse(finallyPending)
            XCTAssertEqual(dispositionAfterReceiptDrain(historyPending: finallyPending), .complete)

            for key in [oldMainKey, oldSettleKey] {
                let old = try await store.durableMigrationProgress(key: key)
                XCTAssertEqual(old?.state, .complete)
                XCTAssertEqual(old?.nextOffset, oldCompletedOffset, "the upgrade keeps the old durable record")
            }
            XCTAssertTrue(UserDefaults.standard.bool(forKey: oldDoneKey))
            XCTAssertEqual(UserDefaults.standard.integer(forKey: oldOffsetKey), oldCompletedOffset)
        }
    }

    func testNewGenerationStaysPendingInForegroundAndRunsAfterBackgroundAdmission() async throws {
        try await withCompletedPreviousDefaults {
            let (store, model) = try await upgradedModel()
            model.isGenuinelyBackground = { false }
            await model.runEffortRescoreForBackgroundTask(maxChunks: 1)

            let mainBeforeBackground = try await store.durableMigrationProgress(
                key: IntelligenceEngine.effortRescoreDurableProgressKey)
            let settleBeforeBackground = try await store.durableMigrationProgress(
                key: IntelligenceEngine.effortRescoreSettleDurableProgressKey)
            XCTAssertNil(mainBeforeBackground, "an upgrade does not bypass genuine-background admission")
            XCTAssertNil(settleBeforeBackground)
            let stillPending = await model.effortRescoreIsPending()
            XCTAssertTrue(stillPending)

            model.isGenuinelyBackground = { true }
            await model.runEffortRescoreForBackgroundTask(maxChunks: 1)
            let admittedMain = try await store.durableMigrationProgress(
                key: IntelligenceEngine.effortRescoreDurableProgressKey)
            XCTAssertEqual(admittedMain?.state, .complete,
                           "a cold background launch uses the existing entry without a scene edge")
        }
    }
    private typealias StrengthFixtures = StrengthStrainFixtures

    /// Two complete civil days give a lift day and a non-lift day. Today is the third bounded history day.
    /// No fixture sample crosses into a fourth day, and the two grants use production's own clock/calendar.
    private func strengthHistoryStore(reference: Date, lift: StrengthFixtures.Lift) async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.add(PairedDevice(
            id: Repository.whoopSource, brand: "WHOOP", model: "WHOOP 5.0", sourceKind: .liveBLE,
            capabilities: [.hr, .hrv, .skinTemp, .sleep], status: .active, addedAt: 0, lastSeenAt: 0))
        try registry.setActive(Repository.whoopSource)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: reference)
        for daysAgo in [2, 1] {
            let start = try XCTUnwrap(calendar.date(byAdding: .day, value: -daysAgo, to: today))
            let next = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
            let startTs = Int(start.timeIntervalSince1970)
            let endTs = Int(next.timeIntervalSince1970)
            var streams = Streams()
            for ts in stride(from: startTs, to: endTs, by: 30) {
                let hour = calendar.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(ts)))
                let asleep = hour < 6 || hour >= 23
                let exercising = hour == 17
                streams.hr.append(HRSample(ts: ts, bpm: asleep ? 52 : exercising ? 135 + ts % 11 : 78 + ts % 9))
                let wobble = asleep ? 0 : Double(ts % 11) * 0.2
                streams.gravity.append(GravitySample(ts: ts, x: wobble, y: asleep ? 0 : 0.3 - wobble,
                                                     z: asleep ? 1 : 0.8))
                if asleep { streams.skinTemp.append(SkinTempSample(ts: ts, raw: 1_300 + ts % 3)) }
            }
            // A supported historical source with stable order, never the legacy default or realtime echo path.
            for (ordinal, ts) in stride(from: startTs + 3_600, to: startTs + 7_200, by: 2).enumerated() {
                streams.rr.append(RRInterval(ts: ts, rrMs: ordinal.isMultiple(of: 2) ? 1_138 : 1_162,
                                             sourceOrdinal: ordinal, source: .whoop5Historical))
            }
            _ = try await store.insert(streams, deviceId: Repository.whoopSource)
        }
        try await StrengthFixtures.seed(store, lifts: [lift], workoutStrain: 30, dayStrain: 40)
        return store
    }

    /// Compare persisted doubles by their bits, including original target snapshots, without pinning HR values
    /// that the history repair is supposed to replace. SQL always supplies a stable row and column order.
    private func snapshot(_ store: WhoopStore, sql: String) async throws -> [String] {
        try await store.registryWriter.read { db in
            try Row.fetchAll(db, sql: sql).map { row in
                row.columnNames.map { name in
                    let value: DatabaseValue = row[name]
                    switch value.storage {
                    case .null: return "\(name)=null"
                    case .int64(let value): return "\(name)=i\(value)"
                    case .double(let value): return "\(name)=d\(value.bitPattern)"
                    case .string(let value): return "\(name)=s\(value)"
                    case .blob(let value): return "\(name)=b\(value.base64EncodedString())"
                    }
                }.joined(separator: "|")
            }
        }
    }

    private func strengthInvariantSnapshot(_ store: WhoopStore) async throws -> [[String]] {
        var result: [[String]] = []
        for sql in [
            """
            SELECT deviceId, liftSessionId, workoutStartTs, workoutSport, dayKey, formulaVersion,
                   bodyweightKg, bodyweightIsDefault, dose, volume, muscularLoad, workingSets, warmupSets,
                   countedSets, skippedJSON, unmappedSets, computedAt
            FROM liftStrain ORDER BY deviceId, liftSessionId
            """,
            """
            SELECT deviceId, kind, keyTs, keyText, origStrain, origStrainVersion, formulaVersion, snapshotAt
            FROM liftStrainTarget ORDER BY deviceId, kind, keyTs, keyText
            """,
            "SELECT * FROM liftStrainJob ORDER BY jobKey",
            "SELECT * FROM liftStrainControl ORDER BY scope"
        ] {
            result.append(try await snapshot(store, sql: sql))
        }
        return result
    }

    private func assertRepairedStrength(
        store: WhoopStore, model: AppModel, controlStore: WhoopStore, control: IntelligenceEngine,
        controlRepo: Repository, lift: StrengthFixtures.Lift, initial: LiftStrainRow,
        reference: Date, invariants: [[String]]
    ) async throws {
        let day = Repository.logicalDayKey(lift.start)
        let baselineRows = try await controlStore.dailyMetrics(
            deviceId: StrengthFixtures.canonical, from: "0000-01-01", to: "9999-12-31")
        let basis = try XCTUnwrap(baselineRows.first { $0.day == day })
        let hrOnly = try XCTUnwrap(basis.strain)
        let request = StrainDayRequest(
            dayKey: day, logicalStart: Calendar.current.startOfDay(for: lift.start), isToday: false,
            maxHR: model.profile.hrMaxForBatchScoring,
            restingHR: basis.restingHr.map(Double.init) ?? StrainScorerV2.defaultRestingHR,
            steps: basis.steps, stepTicksPerStep: model.profile.stepTicksPerStep,
            sleepMinutes: basis.totalSleepMin, heroTenths: nil, refreshSeq: controlRepo.refreshSeq)
        let fresh = await StrainDayLoader.load(request, repo: controlRepo, useCache: false)
        let components = try XCTUnwrap(fresh?.analysis.components, "source-backed day parts must be available")
        let componentScore = try XCTUnwrap(components.score)
        XCTAssertLessThanOrEqual(
            abs(StrainScorerV2.displayValue(fromStored: componentScore) - StrainScorerV2.displayValue(fromStored: hrOnly)),
            StrengthStrainIntegration.dayPartsTolerance, "the fresh parts must describe the repaired HR baseline")
        let muscularLoad = StrengthStrain.dayMuscularLoad([initial.muscularLoad])
        let expected = StrengthStrainIntegration.dayCombine(
            hrStored: hrOnly, muscularLoad: muscularLoad, components: components)
        XCTAssertGreaterThan(expected, hrOnly, "the fixture must expose a lost muscular contribution")
        let dayBits = try await StrengthFixtures.dayBits(store, day: day)
        XCTAssertEqual(dayBits, StrengthFixtures.Bits(expected, 2))
        let shown = try XCTUnwrap(model.intelligence.results.first { $0.day == day }?.strain)
        XCTAssertEqual(shown.bitPattern, expected.bitPattern)
        let targets = try await store.liftStrainDayTargets(
            computedDeviceIds: [StrengthFixtures.canonical], fromDay: day, toDay: day)
        let target = try XCTUnwrap(targets.first { $0.dayKey == day })
        let targetLoad = try await store.registryWriter.read { db in
            try Double.fetchOne(db, sql: """
                SELECT appliedMuscularLoad FROM liftStrainTarget
                WHERE deviceId = ? AND kind = 'day' AND keyText = ?
                """, arguments: [StrengthFixtures.canonical, day])
        }
        XCTAssertEqual(targetLoad?.bitPattern, muscularLoad.bitPattern, "the day contains exactly one lift's load")
        XCTAssertEqual(target.hrOnlyStrain?.bitPattern, hrOnly.bitPattern,
                       "the repair must replace its baseline from fresh independent HR-only analysis")
        let currentRow = try await StrengthFixtures.liftRow(store, id: lift.id)
        let current = try XCTUnwrap(currentRow)
        XCTAssertEqual(current.state, .applied)
        XCTAssertEqual(current.appliedMuscularLoad.bitPattern, initial.muscularLoad.bitPattern)
        let workoutBase = try await StrengthFixtures.workoutBits(
            controlStore, start: Int(lift.start.timeIntervalSince1970))
        let workoutHR = try XCTUnwrap(workoutBase?.value)
        let expectedWorkout = StrengthStrain.combine(hrStored: workoutHR, muscularLoad: initial.muscularLoad)
        let workout = try await StrengthFixtures.workoutBits(store, start: Int(lift.start.timeIntervalSince1970))
        XCTAssertEqual(current.hrOnlyStrain?.bitPattern, workoutHR.bitPattern)
        XCTAssertEqual(current.combinedStrain?.bitPattern, expectedWorkout.bitPattern)
        XCTAssertEqual(workout, StrengthFixtures.Bits(expectedWorkout, 2))
        let otherDate = StrengthFixtures.noon(daysAgo: 2, reference: reference)
        let otherDay = Repository.logicalDayKey(otherDate)
        let otherHR = try XCTUnwrap(control.results.first { $0.day == otherDay }?.strain)
        let otherStored = try await StrengthFixtures.dayBits(store, day: otherDay)
        XCTAssertEqual(otherStored, StrengthFixtures.Bits(otherHR, 2))
        XCTAssertEqual(model.intelligence.results.first { $0.day == otherDay }?.strain?.bitPattern, otherHR.bitPattern)
        let after = try await strengthInvariantSnapshot(store)
        XCTAssertEqual(after, invariants, "repair preserves formula inputs, original targets, job and control")
    }

    func testNewHistoryGenerationPreservesOneAppliedLiftThroughMainAndSettle() async throws {
        try await withCompletedPreviousDefaults {
            let reference = Date()
            let lift = StrengthFixtures.Lift(start: StrengthFixtures.noon(daysAgo: 1, hour: 17, reference: reference),
                                             kg: 100, sets: 6)
            let store = try await strengthHistoryStore(reference: reference, lift: lift)
            let controlStore = try await strengthHistoryStore(reference: reference, lift: lift)
            let (control, controlRepo) = StrengthFixtures.makeEngine(store: controlStore, primary: false)
            let model = AppModel(startRuntimeTasks: false)
            model.repo.setStoreForTesting(store)
            model.repo.loaded = true
            model.isGenuinelyBackground = { true }
            model.isLowPowerModeEnabled = { false }
            _ = try await store.markDurableMigrationComplete(key: oldMainKey, nextOffset: oldCompletedOffset)
            _ = try await store.markDurableMigrationComplete(key: oldSettleKey, nextOffset: oldCompletedOffset)
            // Explicit enabled control gives the preservation assertion a real row to protect.
            try await store.enableLiftStrain(now: 10)
            await model.intelligence.runStrengthStrainBackfillIfNeeded()
            let initialRow = try await StrengthFixtures.liftRow(store, id: lift.id)
            let initial = try XCTUnwrap(initialRow)
            XCTAssertEqual(initial.state, .applied)
            XCTAssertGreaterThan(initial.muscularLoad, 0)
            let job = try await store.liftStrainJob(jobKey: StrengthFixtures.jobKey())
            XCTAssertEqual(job?.state, .complete)
            let invariants = try await strengthInvariantSnapshot(store)
            XCTAssertEqual(invariants[0].count, 1)
            XCTAssertEqual(invariants[1].count, 2, "one workout target and one day target")
            XCTAssertEqual(invariants[2].count, 1)
            XCTAssertEqual(invariants[3].count, 1)

            for (index, progressKey) in [IntelligenceEngine.effortRescoreDurableProgressKey,
                                         IntelligenceEngine.effortRescoreSettleDurableProgressKey].enumerated() {
                // The control has identical workouts/raw input but no applied lift and no primary-engine overlay.
                let controlOK = await control.analyzeRecent(
                    maxDays: 3, force: true, refreshRepository: false, analysisReference: reference,
                    analysisCalendar: .current, keepUnproducedHistory: true)
                XCTAssertTrue(controlOK)
                await model.runEffortRescoreForBackgroundTask(maxChunks: 1)
                let progress = try await store.durableMigrationProgress(key: progressKey)
                XCTAssertEqual(progress?.state, .complete)
                XCTAssertEqual(progress?.nextOffset, 3, "the new generation must not inherit v3's 4,000-day cursor")
                try await assertRepairedStrength(
                    store: store, model: model, controlStore: controlStore, control: control,
                    controlRepo: controlRepo, lift: lift, initial: initial, reference: reference, invariants: invariants)
                let pending = await model.effortRescoreIsPending()
                XCTAssertEqual(pending, index == 0)
                if index == 0 {
                    let settle = try await store.durableMigrationProgress(
                        key: IntelligenceEngine.effortRescoreSettleDurableProgressKey)
                    XCTAssertNil(settle, "the real background entry gives settlement its own later grant")
                }
            }
            for key in [oldMainKey, oldSettleKey] {
                let old = try await store.durableMigrationProgress(key: key)
                XCTAssertEqual(old?.state, .complete)
                XCTAssertEqual(old?.nextOffset, oldCompletedOffset)
            }
            XCTAssertTrue(UserDefaults.standard.bool(forKey: oldDoneKey))
            XCTAssertEqual(UserDefaults.standard.integer(forKey: oldOffsetKey), oldCompletedOffset)
            let controlLifts = try await snapshot(controlStore, sql: "SELECT * FROM liftStrain")
            XCTAssertTrue(controlLifts.isEmpty, "the independent comparator remains HR-only")
            let completedStrain = try await StrengthFixtures.strainDump(store)
            let completedLiftRows = try await snapshot(store, sql: "SELECT * FROM liftStrain ORDER BY liftSessionId")
            let completedTargets = try await snapshot(store, sql: "SELECT * FROM liftStrainTarget ORDER BY kind, keyTs, keyText")
            let serial = model.intelligence.analysisCompletionSerial
            let shown = model.intelligence.results.map { "\($0.day):\($0.strain?.bitPattern.description ?? "nil")" }
            await model.runEffortRescoreForBackgroundTask(maxChunks: 2)
            let reenteredStrain = try await StrengthFixtures.strainDump(store)
            let reenteredLiftRows = try await snapshot(store, sql: "SELECT * FROM liftStrain ORDER BY liftSessionId")
            let reenteredTargets = try await snapshot(store, sql: "SELECT * FROM liftStrainTarget ORDER BY kind, keyTs, keyText")
            let reenteredInvariants = try await strengthInvariantSnapshot(store)
            XCTAssertEqual(reenteredStrain, completedStrain)
            XCTAssertEqual(reenteredLiftRows, completedLiftRows)
            XCTAssertEqual(reenteredTargets, completedTargets)
            XCTAssertEqual(reenteredInvariants, invariants)
            XCTAssertEqual(model.intelligence.analysisCompletionSerial, serial)
            XCTAssertEqual(model.intelligence.results.map { "\($0.day):\($0.strain?.bitPattern.description ?? "nil")" }, shown)
        }
    }

}
#endif
