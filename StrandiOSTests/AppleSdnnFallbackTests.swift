import XCTest
import WhoopStore
@testable import NOOP

/// DL-11 (data half): Apple Health's HRV is SDNN, a different metric on a different scale from the strap's
/// nightly RMSSD. It filled strap-less nights in the merged HRV and the Apple-compatible series fallback, so the
/// HRV tile and trend switched metric with no label.
@MainActor
final class AppleSdnnFallbackTests: XCTestCase {
    private func day(_ key: String, hrv: Double?, rhr: Int?) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: nil, strain: nil,
                    exerciseCount: nil)
    }

    func testSdnnNeverFillsAStraplessNightForSomeoneWithAnRmssdSource() {
        let strap = [day("2026-10-10", hrv: 62, rhr: 51), day("2026-10-11", hrv: nil, rhr: nil)]
        let apple = [day("2026-10-11", hrv: 38, rhr: 54), day("2026-10-12", hrv: 41, rhr: 53)]

        let merged = Repository.mergeDaily(
            imported: Repository.mergeDaily(imported: strap, computed: []),
            computed: Repository.appleFallbackDaily(apple, rmssdSources: strap, []))
        let byDay = Dictionary(uniqueKeysWithValues: merged.map { ($0.day, $0) })

        XCTAssertEqual(byDay["2026-10-10"]?.avgHrv, 62)
        XCTAssertNil(byDay["2026-10-11"]?.avgHrv, "Apple SDNN filled a strap-less night")
        XCTAssertNil(byDay["2026-10-12"]?.avgHrv)
        XCTAssertEqual(byDay["2026-10-11"]?.restingHr, 54, "other Apple vitals still fill the gap")
    }

    func testSomeoneWithOnlyAppleHealthKeepsTheirHrv() {
        let apple = [day("2026-10-11", hrv: 38, rhr: 54)]
        let merged = Repository.mergeDaily(
            imported: [], computed: Repository.appleFallbackDaily(apple, rmssdSources: [], []))
        XCTAssertEqual(merged.first?.avgHrv, 38)
    }

    func testTheHrvSeriesHasNoAppleFallback() {
        XCTAssertNil(Repository.appleCompatibleKey(forWhoopKey: "hrv"))
        XCTAssertEqual(Repository.appleCompatibleKey(forWhoopKey: "rhr"), "resting_hr")
        let candidates = Repository.sourceCandidates(
            forKey: "hrv", preferredSource: Repository.whoopSource, actualWhoopSource: Repository.whoopSource)
        XCTAssertFalse(candidates.contains { $0.source == Repository.appleHealthSource })
    }
}
