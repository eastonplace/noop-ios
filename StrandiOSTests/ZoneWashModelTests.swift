import XCTest
import StrandDesign
@testable import NOOP

final class ZoneWashModelTests: XCTestCase {
    /// A maximum of 187: rest below 93.5, steady below 130.9, push from there.
    private let thresholds = HRZoneStyle.Thresholds(hrMax: 187)
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    func testTheFirstReadingIsShownAtOnce() {
        var wash = ZoneWashModel()
        XCTAssertEqual(wash.update(bpm: 150, thresholds: thresholds, now: at(0), isNeutral: false), 2)
    }

    func testANewZoneNeedsTheMarginAndTheDwell() {
        var wash = ZoneWashModel()
        wash.update(bpm: 110, thresholds: thresholds, now: at(0), isNeutral: false)   // steady
        // 132 is push but only 1.1 past the boundary (130.9): not enough, however long it stays.
        for second in stride(from: 1.0, through: 30, by: 1) {
            XCTAssertEqual(wash.update(bpm: 132, thresholds: thresholds, now: at(second), isNeutral: false), 1)
        }
        // 135 is past it by more than 3: the dwell starts here.
        XCTAssertEqual(wash.update(bpm: 135, thresholds: thresholds, now: at(31), isNeutral: false), 1)
        XCTAssertEqual(wash.update(bpm: 135, thresholds: thresholds, now: at(35), isNeutral: false), 1, "four seconds is not five")
        XCTAssertEqual(wash.update(bpm: 135, thresholds: thresholds, now: at(36), isNeutral: false), 2)
    }

    func testDippingBackBeforeTheDwellEndsStartsItOver() {
        var wash = ZoneWashModel()
        wash.update(bpm: 110, thresholds: thresholds, now: at(0), isNeutral: false)
        wash.update(bpm: 140, thresholds: thresholds, now: at(1), isNeutral: false)
        wash.update(bpm: 120, thresholds: thresholds, now: at(4), isNeutral: false)      // back in steady
        XCTAssertEqual(wash.update(bpm: 140, thresholds: thresholds, now: at(5), isNeutral: false), 1)
        XCTAssertEqual(wash.update(bpm: 140, thresholds: thresholds, now: at(9), isNeutral: false), 1, "only four seconds since 5")
        XCTAssertEqual(wash.update(bpm: 140, thresholds: thresholds, now: at(10), isNeutral: false), 2)
    }

    func testGoingDownIsAsReluctantAsGoingUp() {
        var wash = ZoneWashModel()
        wash.update(bpm: 150, thresholds: thresholds, now: at(0), isNeutral: false)      // push
        // 129 is steady but only 1.9 under the boundary.
        for second in stride(from: 1.0, through: 20, by: 1) {
            XCTAssertEqual(wash.update(bpm: 129, thresholds: thresholds, now: at(second), isNeutral: false), 2)
        }
        wash.update(bpm: 120, thresholds: thresholds, now: at(21), isNeutral: false)
        XCTAssertEqual(wash.update(bpm: 120, thresholds: thresholds, now: at(26), isNeutral: false), 1)
    }

    func testNeutralStatesShowNothingAndTheNextZoneIsShownAtOnce() {
        var wash = ZoneWashModel()
        wash.update(bpm: 150, thresholds: thresholds, now: at(0), isNeutral: false)
        XCTAssertNil(wash.update(bpm: 150, thresholds: thresholds, now: at(1), isNeutral: true), "paused, ending or stale")
        XCTAssertNil(wash.update(bpm: nil, thresholds: thresholds, now: at(2), isNeutral: false), "no reading")
        XCTAssertEqual(wash.update(bpm: 80, thresholds: thresholds, now: at(3), isNeutral: false), 0,
                       "coming back from neutral adopts the zone it finds, with no dwell")
    }

    func testAJumpAcrossTwoZonesWaitsForTheMarginOfTheZoneItLandsIn() {
        var wash = ZoneWashModel()
        wash.update(bpm: 80, thresholds: thresholds, now: at(0), isNeutral: false)       // rest
        wash.update(bpm: 160, thresholds: thresholds, now: at(1), isNeutral: false)
        XCTAssertEqual(wash.update(bpm: 160, thresholds: thresholds, now: at(6), isNeutral: false), 2)
    }
}
