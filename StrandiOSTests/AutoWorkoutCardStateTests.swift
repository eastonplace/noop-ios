import XCTest
import StrandAnalytics
@testable import NOOP

final class AutoWorkoutCardStateTests: XCTestCase {
    private func suggestion(start: Int = 1_000, sport: String = "Running") -> AutoWorkoutSuggestion {
        AutoWorkoutSuggestion(
            window: DetectedWorkout(startSec: start, endSec: start + 1_237,
                                    avgBpm: 140, peakBpm: 170, durationMin: 20),
            prediction: .init(sport: sport, confidence: .likely, evidence: [.runningMovement]),
            sourceId: "source",
            context: .init(sourceContext: "context", sourceLineage: "lineage", invalidationEpoch: 0),
            databaseInstanceId: "database", sourceOwner: .init(deviceId: "source", lineage: "lineage"))
    }

    func testFailedSaveRetainsTheCandidateAndTheChosenTypeForRetry() throws {
        var state = AutoWorkoutCardState()
        let candidate = suggestion()
        let load = state.beginLoad()
        state.receive(candidate, for: load)
        state.selectedType = "Cycling"
        let save = try XCTUnwrap(state.beginSave())
        state.completeSave(.failed, for: save)
        XCTAssertEqual(state.candidate, candidate)
        XCTAssertEqual(state.selectedType, "Cycling")
        XCTAssertFalse(state.saving)
        XCTAssertEqual(state.saveResult, .failed)
        XCTAssertNotNil(state.beginSave())
    }

    func testACompletedOldSaveCannotClearANewerCandidate() throws {
        var state = AutoWorkoutCardState()
        let firstLoad = state.beginLoad()
        state.receive(suggestion(), for: firstLoad)
        let oldSave = try XCTUnwrap(state.beginSave())
        let next = suggestion(start: 10_000)
        let secondLoad = state.beginLoad()
        state.receive(next, for: secondLoad)
        state.completeSave(.saved, for: oldSave)
        XCTAssertEqual(state.candidate, next)
    }

    func testDelayedLoadCannotResurrectADismissedCandidate() {
        var state = AutoWorkoutCardState()
        let initial = state.beginLoad()
        state.receive(suggestion(), for: initial)
        let delayed = state.beginLoad()
        state.clear()
        state.receive(suggestion(), for: delayed)
        XCTAssertNil(state.candidate)
    }

    func testReloadOfTheSameWindowPreservesTheUserCorrection() {
        var state = AutoWorkoutCardState()
        let initial = state.beginLoad()
        state.receive(suggestion(), for: initial)
        state.selectedType = "Strength"
        let refresh = state.beginLoad()
        state.receive(suggestion(sport: "Walking"), for: refresh)
        XCTAssertEqual(state.selectedType, "Strength")
        XCTAssertEqual(state.candidate?.prediction.sport, "Walking")
    }

    func testOnlyOneSaveCanBeInFlightAndSuccessClearsTheCard() throws {
        var state = AutoWorkoutCardState()
        let load = state.beginLoad()
        state.receive(suggestion(), for: load)
        let save = try XCTUnwrap(state.beginSave())
        XCTAssertNil(state.beginSave())
        state.completeSave(.saved, for: save)
        XCTAssertNil(state.candidate)
        XCTAssertFalse(state.saving)
    }

    func testAnEmptyRefreshCannotHideAPendingOrFailedSave() throws {
        var state = AutoWorkoutCardState()
        let candidate = suggestion()
        let initial = state.beginLoad()
        state.receive(candidate, for: initial)
        let save = try XCTUnwrap(state.beginSave())
        let pendingRefresh = state.beginLoad()
        state.receive(nil, for: pendingRefresh)
        state.completeSave(.failed, for: save)
        XCTAssertEqual(state.candidate, candidate)
        XCTAssertEqual(state.saveResult, .failed)
        let failedRefresh = state.beginLoad()
        state.receive(nil, for: failedRefresh)
        XCTAssertEqual(state.candidate, candidate)
        XCTAssertNotNil(state.beginSave())
    }
}
