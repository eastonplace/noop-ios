import Foundation
import StrandAnalytics
import StrandDesign
import XCTest
@testable import NOOP

/// Strength Strain on the day's curve: pure transform and the score parts.
final class StrainDayLiftTransformTests: XCTestCase {

    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func analysis() -> StrainDayAnalysis {
        let curve = (0..<6).map { index in
            StrainScorerV2.CumulativeCardioPoint(
                t: origin.addingTimeInterval(Double(index) * 3_600), value: Double(index) * 2)
        }
        let components = StrainScorerV2.DayStrainComponents(
            cardio: 10, steps: 4, energy: 3, score: StrainScorerV2.storedValue(fromDisplay: 10), dominant: .cardio)
        return StrainDayAnalysis(components: components, curve: curve, gateOpenedAt: origin)
    }

    func testEmptyLoadsReturnTheAnalysisUnchanged() {
        let base = analysis()
        XCTAssertEqual(StrainDayLiftTransform.apply(base, loads: []), base)
        XCTAssertEqual(StrainDayLiftTransform.apply(base, loads: [StrainDayLiftLoad(endTs: 1, muscularLoad: 0)]), base)
        XCTAssertEqual(StrainDayLiftTransform.apply(base, loads: [StrainDayLiftLoad(endTs: 1, muscularLoad: .nan)]), base)
    }

    func testAMidDayLiftRaisesThePointsOnlyAfterItEnded() {
        let base = analysis()
        let end = Int(origin.addingTimeInterval(2 * 3_600 + 60).timeIntervalSince1970)
        let result = StrainDayLiftTransform.apply(base, loads: [StrainDayLiftLoad(endTs: end, muscularLoad: 12)])
        for index in 0...2 {
            XCTAssertEqual(result.curve[index].value.bitPattern, base.curve[index].value.bitPattern, "point \(index)")
        }
        XCTAssertGreaterThan(result.curve[3].value, base.curve[3].value)
        XCTAssertGreaterThan(result.curve[4].value, base.curve[4].value)
        XCTAssertEqual(result.liftMuscularLoad, StrengthStrain.dayMuscularLoad([12]))
        XCTAssertEqual(result.components, base.components, "components stay heart rate only")
    }

    func testALiftEndingAfterTheLastPointStillLandsFully() {
        let base = analysis()
        let end = Int(origin.addingTimeInterval(99 * 3_600).timeIntervalSince1970)
        let result = StrainDayLiftTransform.apply(base, loads: [StrainDayLiftLoad(endTs: end, muscularLoad: 12)])
        let last = base.curve[base.curve.count - 1].value
        XCTAssertEqual(result.curve.last?.value, StrengthStrain.combinedDisplay(hrDisplay: last, muscularLoad: 12))
        XCTAssertEqual(result.curve[0].value, base.curve[0].value)
    }

    func testTwoLiftsUseTheSummedDayLoadAndTheCombineCapsIt() {
        let base = analysis()
        let end = Int(origin.addingTimeInterval(3_600).timeIntervalSince1970)
        let loads = [StrainDayLiftLoad(endTs: end, muscularLoad: 30), StrainDayLiftLoad(endTs: end, muscularLoad: 30)]
        let result = StrainDayLiftTransform.apply(base, loads: loads)
        XCTAssertEqual(result.liftMuscularLoad, StrengthStrain.dayMuscularLoad([30, 30]))
        // The day's load is the plain sum; the cap lives in the combine, so 60 lands where 36 does.
        let last = base.curve[base.curve.count - 1].value
        XCTAssertEqual(result.curve.last?.value, StrengthStrain.combinedDisplay(hrDisplay: last, muscularLoad: 36))
    }

    func testScorePartsWithALiftAgreeWithACombinedHeroAndAddTheLiftingRow() throws {
        let base = analysis()
        let load = 14.0
        let combined = try XCTUnwrap(StrengthStrain.combineDay(components: base.components, muscularLoad: load))
        let hero = StrainScale.displayValue(fromStored: combined)

        let parts = try XCTUnwrap(StrainScoreParts.make(base.components, hero: hero, liftLoad: load))
        XCTAssertTrue(parts.agreesWithHero)
        XCTAssertEqual(parts.rows.last?.kind, .lifting)
        let add = try XCTUnwrap(parts.rows.last?.value)
        XCTAssertEqual(add, hero - StrainScale.displayValue(fromStored: try XCTUnwrap(base.components.score)), accuracy: 1e-9)
        XCTAssertGreaterThan(add, 0)

        // Without the lift the same hero does not agree with the heart-rate parts.
        let hrOnly = try XCTUnwrap(StrainScoreParts.make(base.components, hero: hero))
        XCTAssertFalse(hrOnly.agreesWithHero)
        XCTAssertFalse(hrOnly.rows.contains { $0.kind == .lifting })
    }

    func testNoLiftLoadLeavesThePartsAsTheyWere() throws {
        let base = analysis()
        let hero = StrainScale.displayValue(fromStored: try XCTUnwrap(base.components.score))
        XCTAssertEqual(StrainScoreParts.make(base.components, hero: hero, liftLoad: 0),
                       StrainScoreParts.make(base.components, hero: hero))
        XCTAssertEqual(StrainScoreParts.make(base.components, hero: hero, liftLoad: .nan),
                       StrainScoreParts.make(base.components, hero: hero))
    }
}
