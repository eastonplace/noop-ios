import Foundation
import StrandAnalytics
import WhoopStore
import XCTest
@testable import NOOP

/// The save follow-up and the settle: how a freshly saved lift turns from pending into a stored combined value.
@MainActor
final class StrengthStrainSettleTests: XCTestCase {

    private typealias Fixtures = StrengthStrainFixtures

    func testSaveFollowUpSettlesWhenAnalyzeReturnsFalse() async {
        var order: [String] = []
        await LiftStrainSaveFollowUp.run(
            analyze: { order.append("analyze"); return false },
            settle: { order.append("settle") },
            refresh: { order.append("refresh") })
        XCTAssertEqual(order, ["analyze", "settle", "refresh"])
    }

    private func pendingStore(workoutStrain: Double?, dayStrain: Double?,
                              lift: Fixtures.Lift) async throws -> (WhoopStore, ReceiptLiftWorkoutBox) {
        let store = try await WhoopStore.inMemory()
        try Fixtures.register(store, ids: [Fixtures.owner])
        let workouts = try await Fixtures.seed(
            store, lifts: [lift], workoutStrain: workoutStrain, dayStrain: dayStrain)
        let workout = try XCTUnwrap(workouts.first)
        let computed = StrengthStrainIntegration.computed(for: workout, frozen: nil, profileKg: 80)
        try await store.upsertLiftStrainComputed(deviceId: Fixtures.owner, rows: [computed], now: 10)
        return (store, ReceiptLiftWorkoutBox(computed: computed, startTs: Int(workout.startedAt.timeIntervalSince1970)))
    }

    struct ReceiptLiftWorkoutBox {
        let computed: LiftStrainComputed
        let startTs: Int
    }

    func testPendingWithHRBecomesAppliedOnSettle() async throws {
        let lift = Fixtures.Lift(start: Fixtures.noon(daysAgo: 1))
        let (store, box) = try await pendingStore(workoutStrain: 30, dayStrain: 40, lift: lift)
        let pending = try await Fixtures.liftRow(store, id: lift.id)
        XCTAssertEqual(pending?.state, .pending)

        let (engine, _) = Fixtures.makeEngine(store: store)
        let result = await engine.settleLiftStrain()
        XCTAssertNotNil(result)
        XCTAssertGreaterThan(result?.workoutWrites ?? 0, 0)

        let row = try await Fixtures.liftRow(store, id: lift.id)
        XCTAssertEqual(row?.state, .applied)
        let expected = StrengthStrain.combine(hrStored: 30, muscularLoad: box.computed.muscularLoad)
        let stored = try await Fixtures.workoutBits(store, start: box.startTs)
        XCTAssertEqual(stored, Fixtures.Bits(expected, 2))
        XCTAssertEqual(row?.combinedStrain?.bitPattern, expected.bitPattern)
        XCTAssertEqual(row?.hrOnlyStrain?.bitPattern, Double(30).bitPattern)

        // A second settle changes nothing.
        let dumpBefore = try await Fixtures.strainDump(store)
        _ = await engine.settleLiftStrain()
        let dumpAfter = try await Fixtures.strainDump(store)
        XCTAssertEqual(dumpAfter, dumpBefore)
    }

    func testPendingWithoutHRBecomesNotScoredThenAppliedWhenHRArrives() async throws {
        let lift = Fixtures.Lift(start: Fixtures.noon(daysAgo: 1))
        let (store, box) = try await pendingStore(workoutStrain: nil, dayStrain: nil, lift: lift)
        let (engine, _) = Fixtures.makeEngine(store: store)

        _ = await engine.settleLiftStrain()
        let provisional = try await Fixtures.liftRow(store, id: lift.id)
        XCTAssertEqual(provisional?.state, .notScored)
        let untouched = try await Fixtures.workoutBits(store, start: box.startTs)
        XCTAssertEqual(untouched, Fixtures.Bits(nil, nil))

        // The heart rate arrives: the strap offloads and the analysis stores the workout's heart-rate Strain.
        try await Fixtures.setWorkoutStrain(store, starts: [box.startTs], strain: 30)
        _ = await engine.settleLiftStrain()
        let applied = try await Fixtures.liftRow(store, id: lift.id)
        XCTAssertEqual(applied?.state, .applied)
        let expected = StrengthStrain.combine(hrStored: 30, muscularLoad: box.computed.muscularLoad)
        let stored = try await Fixtures.workoutBits(store, start: box.startTs)
        XCTAssertEqual(stored, Fixtures.Bits(expected, 2))
    }

    func testSettleSkipsWhileComputing() async throws {
        let lift = Fixtures.Lift(start: Fixtures.noon(daysAgo: 1))
        let (store, box) = try await pendingStore(workoutStrain: 30, dayStrain: 40, lift: lift)
        let (engine, _) = Fixtures.makeEngine(store: store)
        engine.computing = true
        let skipped = await engine.settleLiftStrain()
        XCTAssertNil(skipped)
        let row = try await Fixtures.liftRow(store, id: lift.id)
        XCTAssertEqual(row?.state, .pending)
        let stored = try await Fixtures.workoutBits(store, start: box.startTs)
        XCTAssertEqual(stored, Fixtures.Bits(30, 2))

        engine.computing = false
        let settled = await engine.settleLiftStrain()
        XCTAssertNotNil(settled)
        let after = try await Fixtures.liftRow(store, id: lift.id)
        XCTAssertEqual(after?.state, .applied)
    }
}
