import Foundation
import GRDB
import ReceiptLiftFeature
import StrandAnalytics
import WhoopStore
import XCTest
@testable import NOOP

/// The one-time, per-owner, resumable backfill of Strength Strain over the lifts already logged.
@MainActor
final class StrengthStrainBackfillTests: XCTestCase {

    private typealias Fixtures = StrengthStrainFixtures

    private func lifts(days: Int, perDay: Int = 1, firstDaysAgo: Int = 2) -> [Fixtures.Lift] {
        var result: [Fixtures.Lift] = []
        for day in 0..<days {
            for slot in 0..<perDay {
                result.append(Fixtures.Lift(start: Fixtures.noon(daysAgo: firstDaysAgo + day, hour: 9 + slot)))
            }
        }
        return result
    }

    private func workout(_ id: String, _ start: Date) -> ReceiptLiftWorkout {
        ReceiptLiftWorkout(id: id, title: "Lift", startedAt: start, endedAt: start.addingTimeInterval(1_800), sets: [])
    }

    private func newStore(_ lifts: [Fixtures.Lift], owner: String = Fixtures.owner) async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        try Fixtures.register(store, ids: [owner])
        try await Fixtures.seed(store, owner: owner, lifts: lifts)
        return store
    }

    private func job(_ store: WhoopStore, owner: String = Fixtures.owner) async throws -> LiftStrainJobRow? {
        try await store.liftStrainJob(jobKey: Fixtures.jobKey(owner: owner))
    }

    private func finish(_ engine: IntelligenceEngine) async {
        await engine.runStrengthStrainBackfillIfNeeded()
    }

    // MARK: Chunk bounds

    func testChunkBounds() {
        let utcDay: (Date) -> String = { Repository.localDayKey($0) }
        let base = Fixtures.noon(daysAgo: 40)
        func lift(_ day: Int, _ slot: Int) -> ReceiptLiftWorkout {
            workout("d\(day)s\(slot)", base.addingTimeInterval(Double(day) * 86_400 + Double(slot) * 600))
        }

        // 20 days, one lift a day: at most 7 days a chunk, in order, nothing dropped.
        let spread = StrengthStrainBackfill.chunks(workouts: (0..<20).map { lift($0, 0) }, cursorDay: nil, dayKey: utcDay)
        XCTAssertEqual(spread.map(\.count), [7, 7, 6])

        // 5 lifts a day: the 30-lift cap cuts the chunk at 6 days.
        let dense = StrengthStrainBackfill.chunks(
            workouts: (0..<8).flatMap { day in (0..<5).map { lift(day, $0) } }, cursorDay: nil, dayKey: utcDay)
        XCTAssertEqual(dense.map(\.count), [30, 10])

        // A day with more than 30 lifts is a chunk of its own and is never split.
        let crowded = StrengthStrainBackfill.chunks(
            workouts: (0..<35).map { lift(3, $0) } + [lift(4, 0), lift(1, 0)], cursorDay: nil, dayKey: utcDay)
        XCTAssertEqual(crowded.map(\.count), [1, 35, 1])
        for chunk in crowded {
            let days = Set(chunk.map { utcDay($0.startedAt) })
            XCTAssertTrue(chunk.allSatisfy { utcDay($0.startedAt) == days.sorted().first || days.count > 1 })
        }

        // The cursor drops every day up to and including it.
        let cursor = utcDay(lift(9, 0).startedAt)
        let resumed = StrengthStrainBackfill.chunks(workouts: (0..<20).map { lift($0, 0) }, cursorDay: cursor, dayKey: utcDay)
        XCTAssertEqual(resumed.flatMap { $0 }.count, 10)
        XCTAssertEqual(resumed.first?.first?.id, "d10s0")
    }

    // MARK: Resume equals uninterrupted

    func testKillAndResumeEqualsUninterrupted() async throws {
        let all = lifts(days: 10)
        let whole = try await newStore(all)
        let (wholeEngine, _) = Fixtures.makeEngine(store: whole)
        await finish(wholeEngine)
        let wholeJob = try await job(whole)
        XCTAssertEqual(wholeJob?.state, .complete)

        // The same inputs, but the first chunk is applied by a runner that is then killed.
        let split = try await newStore(all)
        let key = Fixtures.jobKey()
        try await split.startLiftStrainJob(
            jobKey: key, deviceId: Fixtures.owner, formulaVersion: StrengthStrain.version,
            upperDay: Repository.logicalDayKey(Date()), now: 1)
        let scope = try await split.liftStrainOwnerScope(deviceId: Fixtures.owner)
        let data = try Fixtures.stateData(all)
        let chunks = try StrengthStrainBackfill.plan(
            stateData: data, cursorDay: nil, frozen: [:], profileKg: ProfileStore.storedWeightKg())
        XCTAssertGreaterThan(chunks.count, 1)
        _ = try await split.applyLiftStrainBackfillChunk(
            sourceOwner: scope, canonicalComputedDeviceId: Fixtures.canonical, chunk: chunks[0], jobKey: key, now: 2,
            combine: StrengthStrainIntegration.combine)
        let midJob = try await job(split)
        XCTAssertEqual(midJob?.state, .running)
        XCTAssertEqual(midJob?.cursorDay, chunks[0].lastDay)

        let (resumeEngine, _) = Fixtures.makeEngine(store: split)
        await finish(resumeEngine)
        let resumedJob = try await job(split)
        XCTAssertEqual(resumedJob?.state, .complete)

        let wholeDump = try await Fixtures.strainDump(whole)
        let splitDump = try await Fixtures.strainDump(split)
        XCTAssertEqual(splitDump, wholeDump)
        XCTAssertFalse(wholeDump.isEmpty)
    }

    func testRerunCompleteJobWritesNothing() async throws {
        let store = try await newStore(lifts(days: 3))
        let (engine, _) = Fixtures.makeEngine(store: store)
        await finish(engine)
        XCTAssertTrue(engine.strengthBackfillDone)
        let before = try await Fixtures.strainDump(store)
        let jobBefore = try await job(store)

        let (again, _) = Fixtures.makeEngine(store: store)
        await finish(again)
        let after = try await Fixtures.strainDump(store)
        let jobAfter = try await job(store)
        XCTAssertEqual(after, before)
        XCTAssertEqual(jobAfter, jobBefore)
        XCTAssertTrue(again.strengthBackfillDone)
    }

    func testBackfillNeverCallsAnalyzeRecent() async throws {
        let store = try await newStore(lifts(days: 4))
        let (engine, _) = Fixtures.makeEngine(store: store)
        let before = engine.analysisCompletionSerial
        await finish(engine)
        XCTAssertEqual(engine.analysisCompletionSerial, before)
        let finished = try await job(store)
        XCTAssertEqual(finished?.state, .complete)
        XCTAssertFalse(engine.computing)
    }

    // MARK: Suppress inheritance

    func testBackfillCompletesInsideSuppressTaskAndRefreshSeqAdvances() async throws {
        let store = try await newStore(lifts(days: 3))
        let (engine, repo) = Fixtures.makeEngine(store: store)
        let seqBefore = repo.refreshSeq

        RepositoryRefreshContext.$disposition.withValue(.suppress) {
            engine.kickStrengthStrainBackfillIfNeeded()
        }

        let refreshed = try await Fixtures.eventually {
            try await self.job(store)?.refreshedAt != nil
        }
        XCTAssertTrue(refreshed, "the backfill must refresh even though it was kicked under .suppress")
        XCTAssertGreaterThan(repo.refreshSeq, seqBefore)
        let done = try await job(store)
        XCTAssertEqual(done?.state, .complete)
    }

    // MARK: Primary only

    func testTransientEngineNeverRunsBackfillOrSettle() async throws {
        let store = try await newStore(lifts(days: 2))
        let (engine, _) = Fixtures.makeEngine(store: store, primary: false)
        let settled = await engine.settleLiftStrain()
        XCTAssertNil(settled)
        engine.kickStrengthStrainBackfillIfNeeded()
        await engine.runStrengthStrainBackfillIfNeeded()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let none = try await job(store)
        XCTAssertNil(none)
        let rows = try await store.registryWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM liftStrain") ?? -1
        }
        XCTAssertEqual(rows, 0)
        XCTAssertFalse(engine.strengthBackfillDone)
    }

    func testCompleteWithoutRefreshIsRefreshedNextRun() async throws {
        let store = try await newStore(lifts(days: 2))
        let (engine, _) = Fixtures.makeEngine(store: store)
        await finish(engine)
        try await store.registryWriter.write { db in
            try db.execute(sql: "UPDATE liftStrainJob SET refreshedAt = NULL")
        }
        let cleared = try await job(store)
        XCTAssertNil(cleared?.refreshedAt)
        XCTAssertEqual(cleared?.state, .complete)
        let dumpBefore = try await Fixtures.strainDump(store)

        let (next, _) = Fixtures.makeEngine(store: store)
        await finish(next)
        let healed = try await job(store)
        XCTAssertNotNil(healed?.refreshedAt)
        XCTAssertEqual(healed?.state, .complete)
        let dumpAfter = try await Fixtures.strainDump(store)
        XCTAssertEqual(dumpAfter, dumpBefore, "a refresh-only run writes no Strain")
    }

    // MARK: Owners

    func testBackfillRunsPerOwner() async throws {
        let second = "whoop-abc"
        let store = try await WhoopStore.inMemory()
        try Fixtures.register(store, ids: [Fixtures.owner, second])
        let day = Fixtures.noon(daysAgo: 3)
        let first = Fixtures.Lift(start: day, kg: 60)
        let other = Fixtures.Lift(start: Fixtures.noon(daysAgo: 3, hour: 15), kg: 90)
        try await Fixtures.seed(store, owner: Fixtures.owner, lifts: [first], workoutStrain: 30, dayStrain: 40)
        try await Fixtures.seed(store, owner: second, lifts: [other], workoutStrain: 30, dayStrain: 40)

        let (engine, _) = Fixtures.makeEngine(store: store)
        await finish(engine)

        let firstJob = try await job(store, owner: Fixtures.owner)
        let secondJob = try await job(store, owner: second)
        XCTAssertEqual(firstJob?.state, .complete)
        XCTAssertEqual(secondJob?.state, .complete)

        let rowA = try await Fixtures.liftRow(store, id: first.id, owner: Fixtures.owner)
        let rowB = try await Fixtures.liftRow(store, id: other.id, owner: second)
        let a = try XCTUnwrap(rowA)
        let b = try XCTUnwrap(rowB)
        XCTAssertEqual(a.state, .applied)
        XCTAssertEqual(b.state, .applied)
        let dayKey = Repository.logicalDayKey(day)
        let dayBits = try await Fixtures.dayBits(store, day: dayKey)
        let expected = StrengthStrain.combine(
            hrStored: 40, muscularLoad: StrengthStrain.dayMuscularLoad([a.muscularLoad, b.muscularLoad]))
        XCTAssertEqual(dayBits, Fixtures.Bits(expected, 2), "the canonical day combines both owners' lifts")
    }

    func testDeletingOwnerIsSkippedAndRetried() async throws {
        let store = try await newStore(lifts(days: 2))
        try await store.registryWriter.write { db in
            try db.execute(sql: """
                INSERT INTO sourceTransitionJournal (
                    transitionId, version, mutationKind, sourceDeviceId,
                    contributorIdsJSON, transitionScope, historicalEpoch,
                    externalEpoch, sinkEpoch, stage, createdAt, updatedAt
                ) VALUES (?, ?, 'deleteData', ?, ?, 'targetOnly', ?, ?, ?, 'prepared', ?, ?)
                """, arguments: ["transition-delete-lift", 2, Fixtures.owner, Data("[\"my-whoop\"]".utf8), 1, 1, 1, 1, 1])
        }
        let before = try await Fixtures.strainDump(store)
        let (engine, _) = Fixtures.makeEngine(store: store)
        await finish(engine)

        let after = try await Fixtures.strainDump(store)
        XCTAssertEqual(after, before, "a deleting owner gets no Strain writes")
        XCTAssertFalse(engine.strengthBackfillDone, "the skipped owner is retried on a later run")
        let rows = try await store.registryWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM liftStrain") ?? -1
        }
        XCTAssertEqual(rows, 0)
    }
}
