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
        XCTAssertEqual(WorkoutJourneyPhase.countdown(sport: "A").kind, WorkoutJourneyPhase.countdown(sport: "B").kind)
        XCTAssertEqual(Set([WorkoutJourneyPhase.setup(initialSport: nil).kind, WorkoutJourneyPhase.live.kind,
                            WorkoutJourneyPhase.summary(row()).kind, WorkoutJourneyPhase.countdown(sport: "A").kind]).count, 4)
    }

    // MARK: Countdown

    func testStartWithTheCountdownOnMovesSetupToTheCountdownOnThatSport() {
        XCTAssertEqual(WorkoutJourneyPhase.reduce(.setup(initialSport: nil), .startTapped(sport: "Cycling", countdown: true)),
                       .phase(.countdown(sport: "Cycling")))
    }

    func testStartWithTheCountdownOffLeavesSetupForTheHostToStartTheWorkout() {
        let setup = WorkoutJourneyPhase.setup(initialSport: "Running")
        XCTAssertEqual(WorkoutJourneyPhase.reduce(setup, .startTapped(sport: "Running", countdown: false)), .phase(setup))
    }

    func testCancellingTheCountdownReturnsToSetupOnTheSameSport() {
        XCTAssertEqual(WorkoutJourneyPhase.reduce(.countdown(sport: "Rowing"), .countdownCancelled),
                       .phase(.setup(initialSport: "Rowing")))
    }

    func testAStartThatIsRefusedAtZeroReturnsToSetupToShowWhy() {
        XCTAssertEqual(WorkoutJourneyPhase.reduce(.countdown(sport: "Running"), .startRefused),
                       .phase(.setup(initialSport: "Running")))
    }

    func testTheWorkoutStartingAtZeroMovesTheCountdownToLive() {
        XCTAssertEqual(WorkoutJourneyPhase.reduce(.countdown(sport: "Running"), .workoutBecameActive), .phase(.live))
    }

    func testNothingButTheCountdownsOwnEventsMovesIt() {
        let countdown = WorkoutJourneyPhase.countdown(sport: "Running")
        XCTAssertEqual(WorkoutJourneyPhase.reduce(countdown, .done), .phase(countdown))
        XCTAssertEqual(WorkoutJourneyPhase.reduce(countdown, .saved(row())), .phase(countdown))
        XCTAssertEqual(WorkoutJourneyPhase.reduce(countdown, .workoutGoneWithoutSave), .phase(countdown))
        XCTAssertEqual(WorkoutJourneyPhase.reduce(countdown, .startTapped(sport: "Running", countdown: true)), .phase(countdown))
        XCTAssertTrue(countdown.isCountingDown)
        XCTAssertFalse(WorkoutJourneyPhase.live.isCountingDown)
    }

    func testTheCountdownFlagNamesADigitWithinTheCount() {
        XCTAssertEqual(WorkoutCountdown.seconds, 3)
        XCTAssertEqual(WorkoutCountdown.frozenDigit(arguments: ["--demo-countdown-frozen", "3"]), 3)
        XCTAssertEqual(WorkoutCountdown.frozenDigit(arguments: ["x", "--demo-countdown-frozen", "1"]), 1)
        XCTAssertNil(WorkoutCountdown.frozenDigit(arguments: ["--demo-countdown-frozen", "4"]))
        XCTAssertNil(WorkoutCountdown.frozenDigit(arguments: ["--demo-countdown-frozen", "0"]))
        XCTAssertNil(WorkoutCountdown.frozenDigit(arguments: ["--demo-countdown-frozen"]))
        XCTAssertNil(WorkoutCountdown.frozenDigit(arguments: []))
    }

    func testAFullPathThroughTheCountdown() {
        var phase = WorkoutJourneyPhase.initial(.setup(initialSport: nil), hasActiveWorkout: false)
        func step(_ event: WorkoutJourneyEvent) {
            if case .phase(let next) = WorkoutJourneyPhase.reduce(phase, event) { phase = next }
        }
        step(.startTapped(sport: "Running", countdown: true))
        XCTAssertEqual(phase, .countdown(sport: "Running"))
        step(.countdownCancelled)
        XCTAssertEqual(phase, .setup(initialSport: "Running"))
        step(.startTapped(sport: "Running", countdown: true))
        step(.workoutBecameActive)
        XCTAssertEqual(phase, .live)
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
