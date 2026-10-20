import Foundation
import ReceiptLiftFeature
import StrandAnalytics
import WhoopStore
import XCTest
@testable import NOOP

/// BF-R2-1: the day-key helpers, the computed-row builder and the backfill planner are callable off the main actor.
/// This is mostly a compile check (Swift 6 strict concurrency rejects a main-actor call here); the assertions only
/// confirm the off-actor results equal the main-actor ones.
final class StrengthStrainIsolationTests: XCTestCase {

    private nonisolated func offActorKey(_ date: Date) -> String { Repository.logicalDayKey(date) }

    private nonisolated func offActorComputed(_ workout: ReceiptLiftWorkout) -> LiftStrainComputed {
        StrengthStrainIntegration.computed(for: workout, frozen: nil, profileKg: 80)
    }

    private nonisolated func offActorPlan(_ data: Data) throws -> [LiftStrainChunkInput] {
        try StrengthStrainBackfill.plan(stateData: data, cursorDay: nil, frozen: [:], profileKg: 80)
    }

    func testHelpersRunOffTheMainActor() async throws {
        let lifts = [StrengthStrainFixtures.Lift(start: StrengthStrainFixtures.noon(daysAgo: 1)),
                     StrengthStrainFixtures.Lift(start: StrengthStrainFixtures.noon(daysAgo: 4))]
        let data = try StrengthStrainFixtures.stateData(lifts)
        let workout = try XCTUnwrap(StrengthStrainFixtures.workouts(lifts).first)

        let key = await Task.detached { Repository.logicalDayKey(workout.startedAt) }.value
        XCTAssertEqual(key, Repository.logicalDayKey(workout.startedAt))
        XCTAssertEqual(offActorKey(workout.startedAt), key)

        let computed = await Task.detached { StrengthStrainIntegration.computed(for: workout, frozen: nil, profileKg: 80) }.value
        XCTAssertEqual(computed, offActorComputed(workout))

        let planned = try await Task.detached { try StrengthStrainBackfill.plan(
            stateData: data, cursorDay: nil, frozen: [:], profileKg: 80) }.value
        XCTAssertEqual(planned, try offActorPlan(data))
        XCTAssertEqual(planned.flatMap(\.rows).count, 2)
    }
}
