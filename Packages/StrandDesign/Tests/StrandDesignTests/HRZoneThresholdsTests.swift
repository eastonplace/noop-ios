import SwiftUI
import XCTest
@testable import StrandDesign

final class HRZoneThresholdsTests: XCTestCase {
    func testWithNoProfileTheZonesAreTheOldFixedSplit() {
        let fixed = HRZoneStyle.Thresholds.default
        XCTAssertEqual(fixed.rest, 60)
        XCTAssertEqual(fixed.steady, 110)
        XCTAssertEqual([59.9, 60, 109.9, 110].map { HRZoneStyle.zone(for: $0) }, [0, 1, 1, 2])
        // The default ramp is the one the app always drew.
        for bpm in stride(from: 40.0, through: 180.0, by: 2.5) {
            XCTAssertEqual(HRZoneStyle.color(for: bpm),
                           StrandPalette.sample(stops: HRZoneStyle.stops, at: HRZoneStyle.unit(bpm)), "\(bpm)")
        }
    }

    /// 187 is the maximum the age estimate gives a 30-year-old: rest below 93.5, push from 130.9.
    func testTheBoundariesAreHalfAndSeventyPercentOfTheMaximum() {
        let zones = HRZoneStyle.Thresholds(hrMax: 187)
        XCTAssertEqual(zones.rest, 93.5)
        XCTAssertEqual(zones.steady, 130.9)
        XCTAssertEqual([93, 93.4, 93.5, 94, 130, 130.9, 131, 187].map { zones.zone(for: $0) }, [0, 0, 1, 1, 1, 2, 2, 2])
        XCTAssertEqual(zones.steadyStartBPM, 94)
        XCTAssertEqual(zones.pushStartBPM, 131)
    }

    func testAWholeNumberBoundaryBelongsToTheUpperZone() {
        let zones = HRZoneStyle.Thresholds(hrMax: 200)
        XCTAssertEqual(zones.rest, 100)
        XCTAssertEqual(zones.steady, 140, "200 * 7 / 10 is exact where 200 * 0.7 is a hair off")
        XCTAssertEqual([99, 99.99, 100, 139, 139.99, 140].map { zones.zone(for: $0) }, [0, 0, 1, 1, 1, 2])
        XCTAssertEqual(zones.steadyStartBPM, 100)
        XCTAssertEqual(zones.pushStartBPM, 140)
    }

    func testAHigherOverrideMovesEveryBoundaryUp() {
        let estimate = HRZoneStyle.Thresholds(hrMax: 187)
        let override = HRZoneStyle.Thresholds(hrMax: 205)
        XCTAssertGreaterThan(override.rest, estimate.rest)
        XCTAssertGreaterThan(override.steady, estimate.steady)
        // A reading that is push on the estimate is only steady on the higher maximum.
        XCTAssertEqual(estimate.zone(for: 135), 2)
        XCTAssertEqual(override.zone(for: 135), 1)
    }

    func testAnUnusableMaximumFallsBackToTheFixedSplit() {
        for hrMax in [Double.nan, .infinity, 0, -10, 40, 99, 261, 400] {
            XCTAssertEqual(HRZoneStyle.Thresholds(hrMax: hrMax), .default, "\(hrMax)")
        }
        XCTAssertNotEqual(HRZoneStyle.Thresholds(hrMax: 100), .default)
        XCTAssertNotEqual(HRZoneStyle.Thresholds(hrMax: 260), .default)
    }

    func testTheBoundariesNeverFoldTheRamp() {
        let degenerate = HRZoneStyle.Thresholds(rest: 120, steady: 100)
        XCTAssertGreaterThanOrEqual(degenerate.steady, degenerate.rest + 10)
        let nonFinite = HRZoneStyle.Thresholds(rest: .nan, steady: .nan)
        XCTAssertEqual(nonFinite, .default)
    }

    func testAnchorsKeepTheirPlaceInTheirZone() {
        let zones = HRZoneStyle.Thresholds(hrMax: 187)
        XCTAssertEqual(zones.anchor(HRZoneStyle.floor), HRZoneStyle.floor, accuracy: 1e-9)
        XCTAssertEqual(zones.anchor(60), zones.rest, accuracy: 1e-9)
        XCTAssertEqual(zones.anchor(110), zones.steady, accuracy: 1e-9)
        XCTAssertEqual(zones.anchor(HRZoneStyle.ceiling), HRZoneStyle.ceiling, accuracy: 1e-9)
        for bpm in stride(from: 40.0, through: 180.0, by: 5) {
            XCTAssertEqual(HRZoneStyle.Thresholds.default.anchor(bpm), bpm, accuracy: 1e-9, "the fixed split moves nothing")
        }
    }

    func testTheRampStaysOrderedForEveryMaximumTheAppAccepts() {
        for hrMax in stride(from: 100.0, through: 260.0, by: 5) {
            let locations = HRZoneStyle.stops(for: HRZoneStyle.Thresholds(hrMax: hrMax)).map(\.location)
            XCTAssertEqual(locations, locations.sorted(), "hrMax \(hrMax)")
            XCTAssertEqual(locations.first, 0)
            XCTAssertEqual(locations.last, 1)
        }
    }

    func testTheRampIsRestBelowTheZoneAndPushWellAboveIt() {
        let zones = HRZoneStyle.Thresholds(hrMax: 187)
        // A sampled colour is a new value, so compare what it paints.
        func paint(_ color: Color) -> String { String(describing: color) }
        XCTAssertEqual(paint(HRZoneStyle.color(for: 45, thresholds: zones)), paint(HRZoneStyle.rest))
        XCTAssertEqual(paint(HRZoneStyle.color(for: 180, thresholds: zones)), paint(HRZoneStyle.push))
        // 100 bpm is steady on this wearer's zones (their rest ends at 93.5), not the rest blue it is on the fixed split.
        XCTAssertNotEqual(paint(HRZoneStyle.color(for: 100, thresholds: zones)), paint(HRZoneStyle.color(for: 100)))
    }
}
