import XCTest
import GRDB
@testable import WhoopStore

final class LiftLogAtomicSaveTests: XCTestCase {

    func testAtomicSaveIsRetryableAndPreservesExistingWorkoutMetrics() async throws {
        let store = try await WhoopStore.inMemory()
        let session = LiftSessionRow(
            id: "session-1", deviceId: "device-1", startTs: 1_700_000_000,
            endTs: 1_700_003_600, sport: "Strength Training", programId: nil,
            programName: "Upper A", sessionRpe: 7, note: nil)
        let set = LiftSetRow(
            id: "set-1", deviceId: "device-1", sessionId: session.id, ord: 0,
            exercise: "Bench press", primaryMuscle: .chest, secondaryMuscles: [.triceps],
            setIndex: 1, weightKg: 80, reps: 8, rpe: 8, isWarmup: false,
            startTs: session.startTs, endTs: session.startTs + 60, restSec: 120, note: nil)
        let measured = WorkoutRow(
            startTs: session.startTs, endTs: session.endTs!, sport: session.sport,
            source: "lifting", durationS: 3_600, energyKcal: 420, avgHr: 141, maxHr: 178,
            strain: 7.5, distanceM: 12, zonesJSON: "{\"z2\":42}", notes: "measured",
            strainVersion: 2)

        try await store.saveLiftSession(session: session, sets: [set], workout: measured)

        // This is the replay after a crash between commit and controller teardown. The retry has
        // no analyzer metrics, so it must not erase the measured values already committed.
        let replay = WorkoutRow(
            startTs: session.startTs, endTs: session.endTs!, sport: session.sport,
            source: "lifting", durationS: nil, energyKcal: nil, avgHr: nil, maxHr: nil,
            strain: nil, distanceM: nil, zonesJSON: nil, notes: nil, strainVersion: nil)
        try await store.saveLiftSession(session: session, sets: [set], workout: replay)

        let count = try await store.registryWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM liftSession WHERE id = ?", arguments: [session.id]) ?? 0
        }
        XCTAssertEqual(count, 1)
        let savedSets = try await store.liftSets(sessionId: session.id)
        XCTAssertEqual(savedSets.count, 1)

        let values = try await store.registryWriter.read { db -> (Double?, Int?, Int?, Double?, String?, String?) in
            (
                try Double.fetchOne(db, sql: "SELECT energyKcal FROM workout WHERE deviceId = ? AND startTs = ? AND sport = ?",
                                    arguments: [session.deviceId, session.startTs, session.sport]),
                try Int.fetchOne(db, sql: "SELECT avgHr FROM workout WHERE deviceId = ? AND startTs = ? AND sport = ?",
                                 arguments: [session.deviceId, session.startTs, session.sport]),
                try Int.fetchOne(db, sql: "SELECT maxHr FROM workout WHERE deviceId = ? AND startTs = ? AND sport = ?",
                                 arguments: [session.deviceId, session.startTs, session.sport]),
                try Double.fetchOne(db, sql: "SELECT strain FROM workout WHERE deviceId = ? AND startTs = ? AND sport = ?",
                                    arguments: [session.deviceId, session.startTs, session.sport]),
                try String.fetchOne(db, sql: "SELECT zonesJSON FROM workout WHERE deviceId = ? AND startTs = ? AND sport = ?",
                                    arguments: [session.deviceId, session.startTs, session.sport]),
                try String.fetchOne(db, sql: "SELECT notes FROM workout WHERE deviceId = ? AND startTs = ? AND sport = ?",
                                    arguments: [session.deviceId, session.startTs, session.sport])
            )
        }
        XCTAssertEqual(values.0, 420)
        XCTAssertEqual(values.1, 141)
        XCTAssertEqual(values.2, 178)
        XCTAssertEqual(values.3, 7.5)
        XCTAssertEqual(values.4, "{\"z2\":42}")
        XCTAssertEqual(values.5, "measured")
    }

    func testAtomicSaveRejectsWrongOwnerBeforeWritingAnything() async throws {
        let store = try await WhoopStore.inMemory()
        let session = LiftSessionRow(
            id: "session-2", deviceId: "device-1", startTs: 1_700_000_100,
            endTs: 1_700_000_200, sport: "Strength Training", programId: nil,
            programName: nil, sessionRpe: nil, note: nil)
        let wrongDeviceSet = LiftSetRow(
            id: "set-2", deviceId: "device-2", sessionId: session.id, ord: 0,
            exercise: "Squat", primaryMuscle: .quads, setIndex: 1, weightKg: 100,
            reps: 5, rpe: nil, isWarmup: false, startTs: nil, endTs: nil,
            restSec: nil, note: nil)
        let workout = WorkoutRow(
            startTs: session.startTs, endTs: session.endTs!, sport: session.sport,
            source: "lifting", durationS: nil, energyKcal: nil, avgHr: nil, maxHr: nil,
            strain: nil, distanceM: nil, zonesJSON: nil, notes: nil)

        do {
            try await store.saveLiftSession(session: session, sets: [wrongDeviceSet], workout: workout)
            XCTFail("a set owned by another device must be rejected")
        } catch let error as LiftLogStoreError {
            XCTAssertEqual(error, .setDeviceMismatch(setId: wrongDeviceSet.id))
        }

        let counts = try await store.registryWriter.read { db -> (Int, Int, Int) in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workout") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM liftSession") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM liftSet") ?? 0
            )
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
        XCTAssertEqual(counts.2, 0)
    }

    func testSaveLiftProgramReplacesItemsAtomically() async throws {
        let store = try await WhoopStore.inMemory()
        let program = LiftProgramRow(id: "program-1", deviceId: "device-1", name: "Upper A",
                                      note: nil, createdAt: 1, updatedAt: 2, archived: false)
        let item = LiftProgramItemRow(id: "item-1", deviceId: "device-1", programId: program.id,
                                      ord: 0, exercise: "Bench press", targetSets: 3,
                                      targetRepsLow: 8, targetRepsHigh: 10, targetRpe: 8,
                                      targetWeightKg: 80, restSec: 120, note: nil)
        try await store.saveLiftProgram(program: program, items: [item])
        let savedPrograms = try await store.liftPrograms(deviceId: program.deviceId)
        let savedItems = try await store.liftProgramItems(programId: program.id)
        XCTAssertEqual(savedPrograms.first, program)
        XCTAssertEqual(savedItems, [item])
    }
}
