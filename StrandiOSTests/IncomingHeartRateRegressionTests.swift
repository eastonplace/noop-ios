#if targetEnvironment(simulator)
import XCTest
@testable import NOOP

/// Run with the hosted iOS test target. These tests exercise the production Combine sinks.
/// They were authored during the audit but could not run without Xcode.
@MainActor
final class IncomingHeartRateRegressionTests: XCTestCase {
    func testFirstDirectReadingUsesIncomingPublishedValue() {
        let model = AppModel(startRuntimeTasks: false)
        model.resetSmoothing()
        model.live.heartRate = 88
        XCTAssertEqual(model.bpm, 88)
    }

    func testClearWithoutRRDropsSmoothedReading() {
        let model = AppModel(startRuntimeTasks: false)
        model.live.heartRate = 88
        model.live.heartRate = 90
        model.live.clearBiometrics()
        XCTAssertNil(model.bpm)
    }

    func testClearWithRRDropsSmoothedReadingAfterBothStreamsClear() {
        let model = AppModel(startRuntimeTasks: false)
        model.live.setRRIntervals([750])
        model.live.heartRate = 88
        model.live.heartRate = 90
        model.live.clearBiometrics()
        XCTAssertNil(model.bpm)
    }

    func testNewDirectReadingReplacesFallbackWithoutOneSampleDelay() {
        let model = AppModel(startRuntimeTasks: false)
        model.live.setRRIntervals([750])
        XCTAssertEqual(model.bpm, 80)
        model.live.heartRate = 120
        XCTAssertEqual(model.bpm, 120)
    }
}
#endif
