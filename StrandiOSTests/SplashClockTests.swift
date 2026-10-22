import Foundation
import XCTest
@testable import NOOP

@MainActor
final class SplashClockTests: XCTestCase {
    private let firstRender = Date(timeIntervalSince1970: 1_700_000_000)

    func testFirstRenderStartsAtZeroRegardlessOfItsDate() {
        let clock = SplashClock()
        // The process can exist during a background launch before this first rendered frame.
        XCTAssertEqual(clock.advance(to: firstRender.addingTimeInterval(3_600)), 0)
        XCTAssertEqual(clock.advance(to: firstRender.addingTimeInterval(3_600.1)), 0.1, accuracy: 0.000_001)
    }

    func testTenHertzFramesReachNormalDurationAtWallClockThreshold() {
        let clock = SplashClock()
        for frame in 0...22 {
            let seconds = Double(frame) / 10
            XCTAssertEqual(clock.advance(to: firstRender.addingTimeInterval(seconds)), seconds, accuracy: 0.000_001)
        }
        XCTAssertEqual(clock.advance(to: firstRender.addingTimeInterval(2.25)), 2.25, accuracy: 0.000_001)
    }

    func testReduceMotionThresholdDoesNotStretchAtLowFrameRate() {
        let clock = SplashClock()
        _ = clock.advance(to: firstRender)
        for frame in 1...7 {
            _ = clock.advance(to: firstRender.addingTimeInterval(Double(frame) / 10))
        }
        XCTAssertEqual(clock.advance(to: firstRender.addingTimeInterval(0.75)), 0.75, accuracy: 0.000_001)
    }

    func testLongFrameStallSkipsAheadInsteadOfExtendingSplash() {
        let clock = SplashClock()
        XCTAssertEqual(clock.advance(to: firstRender), 0)
        XCTAssertEqual(clock.advance(to: firstRender.addingTimeInterval(0.02)), 0.02, accuracy: 0.000_001)
        XCTAssertEqual(clock.advance(to: firstRender.addingTimeInterval(5)), 5, accuracy: 0.000_001)
    }

    func testRepeatedAndBackwardsDatesNeverRewindOrDoubleCount() {
        let clock = SplashClock()
        _ = clock.advance(to: firstRender)
        XCTAssertEqual(clock.advance(to: firstRender.addingTimeInterval(0.04)), 0.04, accuracy: 0.000_001)
        XCTAssertEqual(clock.advance(to: firstRender.addingTimeInterval(0.04)), 0.04, accuracy: 0.000_001)
        XCTAssertEqual(clock.advance(to: firstRender.addingTimeInterval(-10)), 0.04, accuracy: 0.000_001)
        XCTAssertEqual(clock.advance(to: firstRender.addingTimeInterval(0.03)), 0.04, accuracy: 0.000_001)
        XCTAssertEqual(clock.advance(to: firstRender.addingTimeInterval(0.08)), 0.08, accuracy: 0.000_001)
    }
}
