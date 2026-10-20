import Foundation
import ReceiptLiftFeature
import StrandAnalytics
import WhoopStore
import XCTest
@testable import NOOP

/// What a Strength Training session's detail says about the sets in its Strain: the state to copy matrix, and the
/// rule that a stored row which no longer matches the workout never shows a split.
final class WorkoutDetailLiftStrainTests: XCTestCase {

    private let sport = "Strength Training"

    private func snapshot(_ state: LiftStrainSummaryState, hr: Double? = nil, combined: Double? = nil,
                          working: Int = 18) -> LiftStrainSnapshot {
        LiftStrainSnapshot(state: state, heartRateDisplay: hr, combinedDisplay: combined,
                           workingSets: working, warmupSets: 3, countedSets: working, bodyweightIsDefault: false)
    }

    // MARK: State -> copy

    func testScoredShowsTheSplitAndWhatItIncludes() throws {
        let note = try XCTUnwrap(WorkoutLiftStrainNote.make(
            sport: sport, source: "manual", snapshot: snapshot(.scored, hr: 10.0, combined: 15.1)))
        XCTAssertEqual(note.line, "Heart rate only 10.0 → With your sets 15.1")
        XCTAssertEqual(note.caption, "Includes your logged sets")
        XCTAssertEqual(note.spoken, "Strain 15.1 of 21. Heart rate only 10.0. Your sets add 5.1.")
    }

    func testTheSpokenAddIsTheDifferenceOfThePrintedFigures() throws {
        // 10.04 prints 10.0 and 15.06 prints 15.1: the gap read aloud is 5.1, not the 5.02 underneath.
        let note = try XCTUnwrap(WorkoutLiftStrainNote.make(
            sport: sport, source: "manual", snapshot: snapshot(.scored, hr: 10.04, combined: 15.06)))
        XCTAssertEqual(note.line, "Heart rate only 10.0 → With your sets 15.1")
        XCTAssertEqual(note.spoken, "Strain 15.1 of 21. Heart rate only 10.0. Your sets add 5.1.")
    }

    func testEveryOtherStateHasOneCaptionAndNoLine() throws {
        let matrix: [(LiftStrainSummaryState, String)] = [
            (.noSets, "Log sets to count lifting"),
            (.notScored, "Not scored yet · wear your strap during lifts"),
            (.pending, "Scoring…"),
        ]
        for (state, copy) in matrix {
            let note = try XCTUnwrap(WorkoutLiftStrainNote.make(
                sport: sport, source: "manual", snapshot: snapshot(state, working: state == .noSets ? 0 : 18)), "\(state)")
            XCTAssertNil(note.line, "\(state)")
            XCTAssertEqual(note.caption, copy, "\(state)")
            XCTAssertEqual(note.spoken, copy, "\(state)")
        }
    }

    func testNoSnapshotAddsNothing() {
        XCTAssertNil(WorkoutLiftStrainNote.make(sport: sport, source: "manual", snapshot: nil))
    }

    func testAnotherSportNeverShowsTheNote() {
        XCTAssertNil(WorkoutLiftStrainNote.make(
            sport: "Running", source: "manual", snapshot: snapshot(.scored, hr: 10, combined: 15)))
    }

    func testAnImportedLiftSaysItIsHeartRateOnlyWithOrWithoutARow() throws {
        for lifted in [nil, snapshot(.scored, hr: 10, combined: 15)] {
            let note = try XCTUnwrap(WorkoutLiftStrainNote.make(sport: sport, source: "lifting", snapshot: lifted))
            XCTAssertEqual(note, .state(.imported))
            XCTAssertNil(note.line)
            XCTAssertEqual(note.caption, "Imported lifts only have totals, so this is heart rate only.")
        }
    }

    func testAScoredSnapshotMissingAFigureShowsNothingRatherThanAWrongSplit() {
        XCTAssertNil(WorkoutLiftStrainNote.make(sport: sport, source: "manual", snapshot: snapshot(.scored, hr: nil, combined: 15)))
        XCTAssertNil(WorkoutLiftStrainNote.make(sport: sport, source: "manual", snapshot: snapshot(.scored, hr: 10, combined: nil)))
    }

    // MARK: The stale-row rule (the split shows only while the stored row and the workout agree)

    private func row(state: LiftStrainRowState, hrOnly: Double?, combined: Double?, counted: Int = 18) -> LiftStrainRow {
        LiftStrainRow(
            deviceId: "my-whoop", liftSessionId: "S1", workoutStartTs: 1_800_000_000, workoutSport: sport,
            dayKey: "2027-01-15", formulaVersion: StrengthStrain.version, bodyweightKg: 75, bodyweightIsDefault: false,
            dose: 1, volume: 1, muscularLoad: 10, workingSets: counted, warmupSets: 3, countedSets: counted,
            skippedJSON: "{}", unmappedSets: 0, hrOnlyStrain: hrOnly, combinedStrain: combined,
            appliedMuscularLoad: 10, state: state, computedAt: 1, updatedAt: 1)
    }

    private func note(row: LiftStrainRow?, workoutStored: Double?) -> WorkoutLiftStrainNote? {
        WorkoutLiftStrainNote.make(
            sport: sport, source: "manual",
            snapshot: LiftStrainSnapshotMapper.snapshot(row: row, workoutStored: workoutStored))
    }

    func testAnAppliedRowThatMatchesTheWorkoutShowsTheSplit() throws {
        let hrOnly = StrainScorerV2.storedValue(fromDisplay: 10.0)
        let combined = StrainScorerV2.storedValue(fromDisplay: 15.1)
        let shown = try XCTUnwrap(note(row: row(state: .applied, hrOnly: hrOnly, combined: combined), workoutStored: combined))
        XCTAssertEqual(shown.line, "Heart rate only 10.0 → With your sets 15.1")
    }

    func testAnAppliedRowThatNoLongerMatchesTheWorkoutIsScoringNotASplit() throws {
        let hrOnly = StrainScorerV2.storedValue(fromDisplay: 10.0)
        let combined = StrainScorerV2.storedValue(fromDisplay: 15.1)
        // The workout was rescored from heart rate after the apply: its stored value is no longer the combined one.
        let stale = try XCTUnwrap(note(row: row(state: .applied, hrOnly: hrOnly, combined: combined),
                                       workoutStored: StrainScorerV2.storedValue(fromDisplay: 11.0)))
        XCTAssertEqual(stale, .state(.scoring))
        // And one the workout row has lost altogether.
        let missing = try XCTUnwrap(note(row: row(state: .applied, hrOnly: hrOnly, combined: combined), workoutStored: nil))
        XCTAssertEqual(missing, .state(.scoring))
    }

    func testRowStatesMapToTheirLines() throws {
        let stored = StrainScorerV2.storedValue(fromDisplay: 12.0)
        XCTAssertEqual(note(row: row(state: .pending, hrOnly: nil, combined: nil), workoutStored: stored), .state(.scoring))
        XCTAssertEqual(note(row: row(state: .notScored, hrOnly: nil, combined: nil), workoutStored: nil), .state(.notScored))
        XCTAssertEqual(note(row: row(state: .detached, hrOnly: nil, combined: nil), workoutStored: nil), .state(.notScored))
        XCTAssertEqual(note(row: row(state: .applied, hrOnly: stored, combined: stored, counted: 0), workoutStored: stored),
                       .state(.noSets))
        XCTAssertNil(note(row: nil, workoutStored: stored))
    }
}
