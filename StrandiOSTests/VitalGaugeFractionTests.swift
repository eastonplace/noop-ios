import XCTest
@testable import NOOP
import WhoopStore

/// The vital-sign gauge fills by each vital's own physiological span. The Resp Rate and Skin Temp spans were keyed
/// "resp_rate" / "skin_temp" while the readings emit "resp" / "skin", so both fell through to the generic default
/// and read about two thirds full whatever the value was.
final class VitalGaugeFractionTests: XCTestCase {
    func testEachVitalReadsItsOwnSpan() {
        XCTAssertEqual(BodyVitalSigns.gaugeFraction(key: "hrv", value: 60)!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(BodyVitalSigns.gaugeFraction(key: "rhr", value: 50)!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(BodyVitalSigns.gaugeFraction(key: "resp", value: 12)!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(BodyVitalSigns.gaugeFraction(key: "spo2", value: 95)!, 0.5, accuracy: 1e-9)
    }

    func testRespirationMovesWithTheValueInsteadOfSittingAtTheDefault() {
        let low = BodyVitalSigns.gaugeFraction(key: "resp", value: 10)!
        let high = BodyVitalSigns.gaugeFraction(key: "resp", value: 20)!
        XCTAssertLessThan(low, high)
        XCTAssertEqual(low, 10.0 / 24.0, accuracy: 1e-9)
        XCTAssertEqual(high, 20.0 / 24.0, accuracy: 1e-9)
    }

    func testSkinTempReadsAcrossTheWristBandOrAroundTheDeviationCentre() {
        // Absolute °C (CSV imports) spans 33…38.
        XCTAssertEqual(BodyVitalSigns.gaugeFraction(key: "skin", value: 34.5)!, 0.3, accuracy: 1e-9)
        // A ±deviation (the on-device pipeline) is centred: 0 reads half full, +0.8 reads 0.7.
        XCTAssertEqual(BodyVitalSigns.gaugeFraction(key: "skin", value: 0)!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(BodyVitalSigns.gaugeFraction(key: "skin", value: 0.8)!, 0.7, accuracy: 1e-9)
    }

    func testNoValueReadsEmptyAndTheFractionIsClamped() {
        XCTAssertNil(BodyVitalSigns.gaugeFraction(key: "hrv", value: nil))
        XCTAssertEqual(BodyVitalSigns.gaugeFraction(key: "hrv", value: 500)!, 1, accuracy: 1e-9)
        XCTAssertEqual(BodyVitalSigns.gaugeFraction(key: "hrv", value: 0)!, 0.02, accuracy: 1e-9)
    }

    /// The keys the readings emit are the keys the gauge switches on: none may reach the generic default.
    func testEveryEmittedReadingKeyHasItsOwnSpan() {
        let day = DailyMetric(day: "2026-06-06", totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                              lightMin: nil, disturbances: nil, restingHr: 52, avgHrv: 74, recovery: nil,
                              strain: nil, exerciseCount: nil,
                              spo2Pct: 97, skinTempDevC: 0.3, respRateBpm: 14.6)
        let readings = BodyVitalSigns.readings(days: [day], today: nil, temperatureUnit: .celsius)
        XCTAssertEqual(Set(readings.map(\.key)), ["resp", "spo2", "rhr", "hrv", "skin"])
        for reading in readings {
            guard let value = reading.value else { return XCTFail("\(reading.key) has no value") }
            let generic = max(0.02, min(1, value / max(1, value * 1.5)))
            XCTAssertNotEqual(BodyVitalSigns.gaugeFraction(key: reading.key, value: value)!, generic,
                              accuracy: 1e-9, "\(reading.key) fell through to the generic default span")
        }
    }
}
