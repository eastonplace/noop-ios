import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class ManualWorkoutRescoreRestingHRTests: XCTestCase {
    private let profile = UserProfile(weightKg: 70, heightCm: 175, age: 35, sex: "male")
    private let hrMax = 190.0

    private func window(bpm: Int = 148, count: Int = 120) -> [HRSample] {
        (0..<count).map { HRSample(ts: 1_700_000_000 + $0 * 30, bpm: bpm) }
    }

    func testMeasuredRestingChangesV2Strain() throws {
        let baseline = try XCTUnwrap(ManualWorkoutRescore.scored(
            windowSamples: window(), profile: profile, hrMax: hrMax
        )?.strain)
        let measured = try XCTUnwrap(ManualWorkoutRescore.scored(
            windowSamples: window(), profile: profile, hrMax: hrMax, restingHR: 45
        )?.strain)
        XCTAssertGreaterThan(measured, baseline)
    }

    func testNilRestingPreservesPriorBehavior() {
        XCTAssertEqual(
            ManualWorkoutRescore.scored(windowSamples: window(), profile: profile, hrMax: hrMax),
            ManualWorkoutRescore.scored(windowSamples: window(), profile: profile, hrMax: hrMax, restingHR: nil)
        )
    }

    func testMeasuredRestingAlsoReachesCaloriesThreshold() throws {
        let mixed = window(bpm: 95, count: 40) + (40..<160).map {
            HRSample(ts: 1_700_000_000 + $0 * 30, bpm: 148)
        }
        let baseline = try XCTUnwrap(ManualWorkoutRescore.scored(
            windowSamples: mixed, profile: profile, hrMax: hrMax
        ))
        let measured = try XCTUnwrap(ManualWorkoutRescore.scored(
            windowSamples: mixed, profile: profile, hrMax: hrMax, restingHR: 45
        ))
        XCTAssertNotEqual(baseline.kcal, measured.kcal)
    }

    func testInvalidMeasuredRestingHRFallsBackToPriorBehavior() {
        let baseline = ManualWorkoutRescore.scored(windowSamples: window(), profile: profile, hrMax: hrMax)
        for invalid in [Double.nan, .infinity, 19, 221, hrMax] {
            XCTAssertEqual(
                ManualWorkoutRescore.scored(
                    windowSamples: window(), profile: profile, hrMax: hrMax, restingHR: invalid
                ),
                baseline,
                "invalid RHR \(invalid) must preserve the old defaults"
            )
        }
    }

    func testRestingHRSelectionUsesSameCivilDayAndRejectsOverlap() {
        let days: [ManualWorkoutRescore.DailyRestingHR] = [
            .init(sourceId: "canonical", startTs: 0, endTs: 86_400, restingHR: 50),
            .init(sourceId: "canonical", startTs: 86_400, endTs: 169_200, restingHR: 60), // 23-hour DST day
        ]
        XCTAssertEqual(ManualWorkoutRescore.restingHR(
            forWorkoutStartingAt: 1_000, sourceId: "canonical", daily: days, hrMax: hrMax), 50)
        XCTAssertEqual(ManualWorkoutRescore.restingHR(
            forWorkoutStartingAt: 86_400, sourceId: "canonical", daily: days, hrMax: hrMax), 60)
        XCTAssertNil(ManualWorkoutRescore.restingHR(
            forWorkoutStartingAt: 200_000, sourceId: "canonical", daily: days, hrMax: hrMax))
        XCTAssertNil(ManualWorkoutRescore.restingHR(
            forWorkoutStartingAt: 1_000,
            sourceId: "canonical",
            daily: days + [.init(sourceId: "canonical", startTs: 500, endTs: 2_000, restingHR: 55)],
            hrMax: hrMax))
    }

    func testRestingHRSelectionStaysInsideWorkoutSource() {
        let days: [ManualWorkoutRescore.DailyRestingHR] = [
            .init(sourceId: "canonical", startTs: 0, endTs: 86_400, restingHR: 50),
            .init(sourceId: "active-repair", startTs: 0, endTs: 86_400, restingHR: 63),
        ]

        XCTAssertEqual(ManualWorkoutRescore.restingHR(
            forWorkoutStartingAt: 1_000,
            sourceId: "canonical",
            daily: days,
            hrMax: hrMax
        ), 50)
        XCTAssertEqual(ManualWorkoutRescore.restingHR(
            forWorkoutStartingAt: 1_000,
            sourceId: "active-repair",
            daily: days,
            hrMax: hrMax
        ), 63)
        XCTAssertNil(ManualWorkoutRescore.restingHR(
            forWorkoutStartingAt: 1_000,
            sourceId: "unknown",
            daily: days,
            hrMax: hrMax
        ))
    }
}
