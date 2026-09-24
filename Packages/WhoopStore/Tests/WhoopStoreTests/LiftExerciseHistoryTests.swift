import XCTest
@testable import WhoopStore

final class LiftExerciseHistoryTests: XCTestCase {

    func testHistoryIsOwnerScopedExactFinishedSessionOrderedAndMuscleStable() async throws {
        let store = try await WhoopStore.inMemory()
        let owner = "device-a"
        let otherOwner = "device-b"
        let sport = "Strength Training"

        let sessions = [
            LiftSessionRow(id: "older", deviceId: owner, startTs: 1_000, endTs: 1_600,
                           sport: sport, programId: nil, programName: nil, sessionRpe: nil, note: nil),
            LiftSessionRow(id: "newer", deviceId: owner, startTs: 2_000, endTs: 2_600,
                           sport: sport, programId: nil, programName: nil, sessionRpe: nil, note: nil),
            LiftSessionRow(id: "unfinished", deviceId: owner, startTs: 3_000, endTs: nil,
                           sport: sport, programId: nil, programName: nil, sessionRpe: nil, note: nil),
            LiftSessionRow(id: "other-owner", deviceId: otherOwner, startTs: 4_000, endTs: 4_600,
                           sport: sport, programId: nil, programName: nil, sessionRpe: nil, note: nil),
        ]
        _ = try await store.upsertLiftSessions(sessions)
        _ = try await store.upsertLiftSets([
            makeSet(id: "old-0", deviceId: owner, sessionId: "older", ord: 0, startTs: 1_050),
            makeSet(id: "old-1", deviceId: owner, sessionId: "older", ord: 1, startTs: 1_100),
            makeSet(id: "new-1", deviceId: owner, sessionId: "newer", ord: 1, startTs: 2_050,
                    primary: .chest, secondary: [.chest, .triceps, .triceps]),
            makeSet(id: "new-0", deviceId: owner, sessionId: "newer", ord: 0, startTs: 2_010),
            makeSet(id: "unfinished-0", deviceId: owner, sessionId: "unfinished", ord: 0, startTs: 3_010),
            makeSet(id: "other-0", deviceId: otherOwner, sessionId: "other-owner", ord: 0, startTs: 4_010),
        ])

        let rows = try await store.liftExerciseHistory(deviceId: owner, exercise: "Bench press", limit: 2)

        XCTAssertEqual(rows.map(\.id), ["new-0", "new-1", "old-0", "old-1"])
        XCTAssertEqual(rows.map(\.sessionId), ["newer", "newer", "older", "older"])
        XCTAssertEqual(rows.map(\.startTs), [2_010, 2_050, 1_050, 1_100])
        XCTAssertEqual(rows[1].primaryMuscle, .chest)
        XCTAssertEqual(rows[1].secondaryMuscles, [.triceps], "catalog identity is canonical and de-duplicated")
        XCTAssertFalse(rows.contains { $0.sessionId == "unfinished" })
        XCTAssertFalse(rows.contains { $0.sessionId == "other-owner" })
    }

    func testHistoryUsesExactExerciseAndBoundsSessions() async throws {
        let store = try await WhoopStore.inMemory()
        let session = LiftSessionRow(id: "s1", deviceId: "device-a", startTs: 1_000, endTs: 1_600,
                                     sport: "Strength Training", programId: nil, programName: nil,
                                     sessionRpe: nil, note: nil)
        _ = try await store.upsertLiftSessions([session])
        _ = try await store.upsertLiftSets([
            makeSet(id: "bench", deviceId: "device-a", sessionId: session.id, ord: 0,
                    startTs: 1_050, exercise: "Bench press"),
            makeSet(id: "case", deviceId: "device-a", sessionId: session.id, ord: 1,
                    startTs: 1_060, exercise: "bench press"),
        ])

        let bounded = try await store.liftExerciseHistory(deviceId: "device-a", exercise: "Bench press", limit: 1)
        let differentCase = try await store.liftExerciseHistory(deviceId: "device-a", exercise: "bench press")
        let emptyLimit = try await store.liftExerciseHistory(deviceId: "device-a", exercise: "Bench press", limit: 0)
        XCTAssertEqual(bounded.map(\.id), ["bench"])
        XCTAssertFalse(differentCase.isEmpty)
        XCTAssertTrue(emptyLimit.isEmpty)
    }

    private func makeSet(
        id: String,
        deviceId: String,
        sessionId: String,
        ord: Int,
        startTs: Int,
        exercise: String = "Bench press",
        primary: LiftMuscle? = .chest,
        secondary: [LiftMuscle] = []
    ) -> LiftSetRow {
        LiftSetRow(id: id, deviceId: deviceId, sessionId: sessionId, ord: ord,
                   exercise: exercise, primaryMuscle: primary, secondaryMuscles: secondary,
                   setIndex: ord + 1, weightKg: 80, reps: 8, rpe: 8, isWarmup: false,
                   startTs: startTs, endTs: startTs + 60, restSec: 120, note: nil)
    }
}
