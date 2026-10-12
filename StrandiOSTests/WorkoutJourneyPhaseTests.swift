import XCTest
import WhoopStore
@testable import NOOP

/// The workout journey's phase machine: where a request opens, and every transition. Pure, so no view is needed.
final class WorkoutJourneyPhaseTests: XCTestCase {
    private func row() -> WorkoutRow {
        WorkoutRow(startTs: 1_000, endTs: 3_000, sport: "Running", source: "manual", durationS: 2_000,
                   energyKcal: 402, avgHr: 148, maxHr: 171, strain: 12.4, distanceM: nil,
                   zonesJSON: nil, notes: nil, strainVersion: 2)
    }

    // MARK: Where a request opens

    func testASetupRequestOpensSetupOnTheChosenSport() {
        XCTAssertEqual(WorkoutJourneyPhase.initial(.setup(initialSport: "Running"), hasActiveWorkout: false),
                       .setup(initialSport: "Running"))
        XCTAssertEqual(WorkoutJourneyPhase.initial(.setup(initialSport: nil), hasActiveWorkout: false),
                       .setup(initialSport: nil))
    }

    func testAWorkoutAlreadyRecordingAlwaysOpensTheLiveScreenNeverASecondSetup() {
        XCTAssertEqual(WorkoutJourneyPhase.initial(.setup(initialSport: "Running"), hasActiveWorkout: true), .live)
        XCTAssertEqual(WorkoutJourneyPhase.initial(.live, hasActiveWorkout: true), .live)
    }

    func testALiveRequestWithNothingRecordingOpensSetupRatherThanAnEmptyScreen() {
        XCTAssertEqual(WorkoutJourneyPhase.initial(.live, hasActiveWorkout: false), .setup(initialSport: nil))
    }

    // MARK: Transitions

    func testStartingMovesSetupToLive() {
        XCTAssertEqual(WorkoutJourneyPhase.reduce(.setup(initialSport: nil), .workoutBecameActive), .phase(.live))
    }

    func testARefusedStartStaysOnSetup() {
        let setup = WorkoutJourneyPhase.setup(initialSport: "Running")
        XCTAssertEqual(WorkoutJourneyPhase.reduce(setup, .startRefused), .phase(setup))
    }

    func testASaveMovesLiveToTheSummaryAndOnlyFromLive() {
        let saved = row()
        XCTAssertEqual(WorkoutJourneyPhase.reduce(.live, .saved(saved)), .phase(.summary(saved)))
        // A saved row that arrives on any other phase changes nothing.
        let setup = WorkoutJourneyPhase.setup(initialSport: nil)
        XCTAssertEqual(WorkoutJourneyPhase.reduce(setup, .saved(saved)), .phase(setup))
        XCTAssertEqual(WorkoutJourneyPhase.reduce(.summary(saved), .saved(saved)), .phase(.summary(saved)))
    }

    func testAWorkoutThatVanishedWithoutASaveClosesTheCoverWithTheDiscardToast() {
        XCTAssertEqual(WorkoutJourneyPhase.reduce(.live, .workoutGoneWithoutSave),
                       .close(toast: String(localized: "Workout discarded")))
        XCTAssertNotEqual(String(localized: "Workout discarded"), "", "the toast has words")
    }

    func testDoneClosesTheCoverWithoutAToast() {
        XCTAssertEqual(WorkoutJourneyPhase.reduce(.summary(row()), .done), .close(toast: nil))
        XCTAssertEqual(WorkoutJourneyPhase.reduce(.setup(initialSport: nil), .done), .close(toast: nil))
    }

    func testEventsThatDoNotApplyLeaveThePhaseWhereItIs() {
        let saved = row()
        XCTAssertEqual(WorkoutJourneyPhase.reduce(.live, .workoutBecameActive), .phase(.live))
        XCTAssertEqual(WorkoutJourneyPhase.reduce(.live, .startRefused), .phase(.live))
        XCTAssertEqual(WorkoutJourneyPhase.reduce(.live, .done), .phase(.live), "Done is the summary's, not the live screen's")
        XCTAssertEqual(WorkoutJourneyPhase.reduce(.summary(saved), .workoutGoneWithoutSave), .phase(.summary(saved)))
        XCTAssertEqual(WorkoutJourneyPhase.reduce(.summary(saved), .workoutBecameActive), .phase(.summary(saved)))
    }

    func testTheKindChangesWithThePhaseNotWithItsPayload() {
        XCTAssertEqual(WorkoutJourneyPhase.setup(initialSport: "A").kind, WorkoutJourneyPhase.setup(initialSport: "B").kind)
        XCTAssertEqual(Set([WorkoutJourneyPhase.setup(initialSport: nil).kind, WorkoutJourneyPhase.live.kind,
                            WorkoutJourneyPhase.summary(row()).kind]).count, 3)
    }

    func testAFullPathStartLiveSaveDone() {
        var phase = WorkoutJourneyPhase.initial(.setup(initialSport: nil), hasActiveWorkout: false)
        func step(_ event: WorkoutJourneyEvent) -> WorkoutJourneyOutcome {
            let outcome = WorkoutJourneyPhase.reduce(phase, event)
            if case .phase(let next) = outcome { phase = next }
            return outcome
        }
        _ = step(.workoutBecameActive)
        XCTAssertEqual(phase, .live)
        _ = step(.saved(row()))
        XCTAssertEqual(phase, .summary(row()))
        XCTAssertEqual(step(.done), .close(toast: nil))
    }
}
