import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// N2-6 (AN-07) golden test: staging only the runs attributed to a day returns exactly what the unrestricted
/// detector returns for that day. Acceptance and the continuation chain still see every run.
final class SleepAttributionGoldenTests: XCTestCase {

    private struct Streams {
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        var gravity: [GravitySample] = []
        mutating func still(_ range: Range<Int>, bpm: Int = 50) {
            var toggle = false
            for ts in stride(from: range.lowerBound, to: range.upperBound, by: 2) {
                hr.append(HRSample(ts: ts, bpm: bpm))
                gravity.append(GravitySample(ts: ts, x: 0, y: 0, z: 1))
                toggle.toggle()
                rr.append(RRInterval(ts: ts, rrMs: toggle ? 1_205 : 1_195))
            }
        }
        mutating func awake(_ range: Range<Int>) {
            for ts in stride(from: range.lowerBound, to: range.upperBound, by: 2) {
                hr.append(HRSample(ts: ts, bpm: 80 + ts % 9))
                let wobble = Double(ts % 11) * 0.2
                gravity.append(GravitySample(ts: ts, x: wobble, y: 0.3 - wobble, z: 0.8))
            }
        }
    }

    /// A 54 h read window like the pass's: last night, a morning tail after a short stir (chain), an
    /// afternoon nap, and tonight's night that ends on the day.
    private func window(dayStart d: Int) -> Streams {
        var s = Streams()
        s.awake((d - 30 * 3_600)..<(d - 26 * 3_600))
        s.still((d - 26 * 3_600)..<(d - 18 * 3_600))                // night of D−1
        s.awake((d - 18 * 3_600)..<(d - 17 * 3_600 - 1_800))        // brief stir
        s.still((d - 17 * 3_600 - 1_800)..<(d - 16 * 3_600))        // morning tail (chain)
        s.awake((d - 16 * 3_600)..<(d - 2 * 3_600))
        s.still((d - 2 * 3_600)..<(d + 6 * 3_600))                  // night of D
        s.awake((d + 6 * 3_600)..<(d + 13 * 3_600))
        s.still((d + 13 * 3_600)..<(d + 14 * 3_600 + 1_800), bpm: 46)  // nap
        s.awake((d + 14 * 3_600 + 1_800)..<(d + 24 * 3_600))
        return s
    }

    func testAttributedDetectionEqualsTheFilteredFullDetection() {
        let d = 1_781_481_600   // 2026-06-15T00:00:00Z
        let s = window(dayStart: d)
        for (offset, v2) in [(0, false), (0, true), (-4 * 3_600, false), (2 * 3_600, true)] {
            let day = (d - offset)..<(d - offset + 86_400)
            let full = SleepStager.detectSleep(hr: s.hr, rr: s.rr, gravity: s.gravity, tzOffsetSeconds: offset,
                                               useSleepStagerV2: v2)
            let attributed = SleepStager.detectSleep(hr: s.hr, rr: s.rr, gravity: s.gravity,
                                                     tzOffsetSeconds: offset, useSleepStagerV2: v2,
                                                     attributeEndRange: day)
            XCTAssertGreaterThan(full.count, attributed.count, "the other night is detected but not staged")
            XCTAssertFalse(attributed.isEmpty)
            XCTAssertEqual(attributed, full.filter { day.contains($0.end) }, "offset \(offset) v2 \(v2)")
        }
    }

    /// `analyzeDay` (which now passes its civil day) produces the same day as before: the sessions it keeps
    /// are the full detector's sessions that end on the day.
    func testAnalyzeDayKeepsTheFullDetectorsSessionsForTheDay() {
        let d = 1_781_481_600
        let s = window(dayStart: d)
        let day = d..<(d + 86_400)
        let result = AnalyticsEngine.analyzeDay(day: "2026-06-15", hr: s.hr, rr: s.rr, gravity: s.gravity,
                                                profile: UserProfile(weightKg: 75, heightCm: 178, age: 30,
                                                                     sex: "male"),
                                                dayInterval: day)
        let full = SleepStager.detectSleep(hr: s.hr, rr: s.rr, gravity: s.gravity)
        XCTAssertEqual(result.sleepSessions, full.filter { day.contains($0.end) })
    }
}
