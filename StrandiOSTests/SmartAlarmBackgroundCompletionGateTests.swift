import Foundation
import XCTest
@testable import NOOP

final class SmartAlarmBackgroundCompletionGateTests: XCTestCase {
    func testSuccessCompletesExactlyOnce() {
        let recorder = CompletionRecorder()
        let gate = SmartAlarmBackgroundCompletionGate { recorder.append($0) }

        XCTAssertTrue(gate.complete(.success))
        XCTAssertFalse(gate.complete(.failure))
        XCTAssertFalse(gate.complete(.expired))
        XCTAssertEqual(recorder.values, [true])
        XCTAssertEqual(gate.terminalEvent, .success)
    }

    func testFailureCompletesExactlyOnce() {
        let recorder = CompletionRecorder()
        let gate = SmartAlarmBackgroundCompletionGate { recorder.append($0) }

        XCTAssertTrue(gate.complete(.failure))
        XCTAssertFalse(gate.complete(.success))
        XCTAssertEqual(recorder.values, [false])
        XCTAssertEqual(gate.terminalEvent, .failure)
    }

    func testEveryExceptionalTerminalEventCompletesFalse() {
        let exceptionalEvents: [SmartAlarmBackgroundTerminalEvent] = [
            .missingRuntime,
            .missingRequest,
            .malformedRequest,
            .cancelled,
            .expired,
            .evaluationError,
        ]

        for event in exceptionalEvents {
            let recorder = CompletionRecorder()
            let gate = SmartAlarmBackgroundCompletionGate { recorder.append($0) }
            XCTAssertTrue(gate.complete(event), "Expected first \(event) completion to be accepted")
            XCTAssertEqual(recorder.values, [false])
            XCTAssertEqual(gate.terminalEvent, event)
        }
    }

    func testExpirationWinsOverLateSuccess() {
        let recorder = CompletionRecorder()
        let gate = SmartAlarmBackgroundCompletionGate { recorder.append($0) }

        XCTAssertTrue(gate.complete(.expired))
        XCTAssertFalse(gate.complete(.success))
        XCTAssertEqual(recorder.values, [false])
        XCTAssertEqual(gate.terminalEvent, .expired)
    }

    func testCancellationWinsOverLateFailure() {
        let recorder = CompletionRecorder()
        let gate = SmartAlarmBackgroundCompletionGate { recorder.append($0) }

        XCTAssertTrue(gate.complete(.cancelled))
        XCTAssertFalse(gate.complete(.failure))
        XCTAssertEqual(recorder.values, [false])
        XCTAssertEqual(gate.terminalEvent, .cancelled)
    }

    func testStateMachineAcceptsOnlyFirstTerminalEvent() {
        var state = SmartAlarmBackgroundCompletionState()
        XCTAssertTrue(state.complete(.malformedRequest))
        XCTAssertFalse(state.complete(.success))
        XCTAssertFalse(state.complete(.expired))
        XCTAssertEqual(state.terminalEvent, .malformedRequest)
    }
}

private final class CompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []

    func append(_ value: Bool) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Bool] {
        lock.lock()
        let copy = storage
        lock.unlock()
        return copy
    }
}
