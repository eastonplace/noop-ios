import XCTest
import WhoopProtocol
import WhoopStore
@testable import StrandAnalytics

final class PersonalStressBaselineTests: XCTestCase {
    private func hour(_ hour: Int, bpm: Int, count: Int = 300) -> [HRSample] {
        (0..<count).map { HRSample(ts: hour * 3_600 + $0, bpm: bpm) }
    }

    private func baseline(_ value: Double, days: Int = 14) -> BaselineState {
        Baselines.foldHistory(Array(repeating: value, count: days), cfg: Baselines.daytimeHRCfg)
    }

    func testDefaultDayRelativeOutputIsUnchangedByOptInAPI() {
        let hr = hour(8, bpm: 60) + hour(9, bpm: 65) + hour(10, bpm: 90)
        let implicit = DaytimeStress.analyze(hr: hr, rr: [])
        let explicit = DaytimeStress.analyze(hr: hr, rr: [], mode: .dayRelative)
        XCTAssertEqual(implicit, explicit)
        XCTAssertEqual(implicit.hours.count, 3)
        XCTAssertEqual(implicit.peak?.hour, 10)
    }

    func testPersonalReferenceSurfacesAUniformlyElevatedDay() throws {
        let hr = hour(8, bpm: 80) + hour(9, bpm: 80) + hour(10, bpm: 80)
        let day = DaytimeStress.analyze(hr: hr, rr: [])
        let personal = DaytimeStress.analyze(
            hr: hr, rr: [], mode: .baselineRelative(hr: baseline(60), rmssd: nil))
        XCTAssertEqual(try XCTUnwrap(day.dayMean), 1.5, accuracy: 1e-9)
        XCTAssertGreaterThan(try XCTUnwrap(personal.dayMean), 2)
        XCTAssertTrue(personal.sustainedHigh)
    }

    func testFifteenBPMMarginMapsToHighBandWithoutPercentages() throws {
        let read = DaytimeStress.analyze(
            hr: hour(9, bpm: 75), rr: [],
            mode: .baselineRelative(hr: baseline(60), rmssd: nil))
        XCTAssertEqual(try XCTUnwrap(read.dayMean), DaytimeStress.highBandFloor, accuracy: 1e-9)
    }

    func testAnalyticsMemoChangesWithLensAndPersonalReference() throws {
        let hr = hour(9, bpm: 75)
        let lower = DaytimeStress.analyze(hr: hr, rr: [], mode: .baselineRelative(hr: baseline(60), rmssd: nil))
        let higher = DaytimeStress.analyze(hr: hr, rr: [], mode: .baselineRelative(hr: baseline(75), rmssd: nil))
        let ordinary = DaytimeStress.analyze(hr: hr, rr: [])
        XCTAssertGreaterThan(try XCTUnwrap(lower.dayMean), try XCTUnwrap(higher.dayMean))
        XCTAssertEqual(try XCTUnwrap(higher.dayMean), 1.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(ordinary.dayMean), 1.5, accuracy: 1e-9)
        XCTAssertEqual(lower, DaytimeStress.analyze(
            hr: hr, rr: [], mode: .baselineRelative(hr: baseline(60), rmssd: nil)))
    }

    func testInsufficientHistoryFallsBackAndFourDaysAreProvisional() {
        let three = PersonalStressBaseline.resolve(dailyHR: [60, 60, 60])
        XCTAssertFalse(three.isPersonal)
        XCTAssertEqual(three.mode, .dayRelative)
        let four = PersonalStressBaseline.resolve(dailyHR: [60, 60, 60, 60])
        guard case .history(let state) = four else { return XCTFail("Missing baseline state") }
        XCTAssertEqual(state.status, .provisional)
        XCTAssertTrue(four.isPersonal)
    }

    func testMissingLocalDaysAgeBaselineInsteadOfBeingSkipped() {
        let history: [Double?] = Array(repeating: 60, count: 14) + Array(repeating: nil, count: 16)
        let result = PersonalStressBaseline.resolve(dailyHR: history)
        guard case .history(let state) = result else { return XCTFail("Missing baseline state") }
        XCTAssertEqual(state.status, .stale)
        XCTAssertEqual(state.nightsSinceUpdate, 16)
        XCTAssertFalse(result.isPersonal)
        XCTAssertEqual(result.mode, .dayRelative)
    }

    func testMissingAndSparseDaysDoNotSeedPersonalBaseline() {
        XCTAssertNil(PersonalStressBaseline.aggregate([
            .init(startTs: 0, sampleCount: 299, meanHR: 60),
            .init(startTs: 3_600, sampleCount: 0, meanHR: 90),
        ]))
        let result = PersonalStressBaseline.resolve(dailyHR: Array(repeating: nil, count: 30))
        XCTAssertFalse(result.isPersonal)
        guard case .history(let state) = result else { return XCTFail("Missing baseline state") }
        XCTAssertEqual(state.nValid, 0)
    }

    func testSummaryAndRawDailyAggregatesUseTheSameCoveredHourMeans() throws {
        let raw = DaytimeStress.dayDaytimeAggregate(
            hr: hour(2, bpm: 35) + hour(6, bpm: 60) + hour(7, bpm: 80) + hour(8, bpm: 95, count: 299),
            rr: [], tzOffsetSeconds: 0)
        let reduced = PersonalStressBaseline.aggregate([
            .init(startTs: 6 * 3_600, sampleCount: 300, meanHR: 60),
            .init(startTs: 7 * 3_600, sampleCount: 300, meanHR: 80),
            .init(startTs: 8 * 3_600, sampleCount: 299, meanHR: 95),
        ])
        XCTAssertEqual(try XCTUnwrap(raw.hr), 62, accuracy: 1e-9)
        XCTAssertEqual(raw.hr, reduced)
    }

    func testPersonalLiveGateExcludesRMSSDEvenWhenItHasHistory() {
        let aggregates: [(hr: Double?, rmssd: Double?)] = Array(repeating: (60, 50), count: 14)
        let mode = DaytimeStress.scoringModeFromAggregates(aggregates)
        guard case .baselineRelative(_, let rmssd) = mode else { return XCTFail("Expected personal lens") }
        XCTAssertNil(rmssd)
        XCTAssertFalse(DaytimeStress.daytimeRMSSDScoringEnabled)
    }

    func testPersonalPathRejectsOffWristSamplesBeforeCoverageGate() {
        let read = DaytimeStress.analyze(
            hr: hour(9, bpm: 0), rr: [], mode: .baselineRelative(hr: baseline(60), rmssd: nil))
        XCTAssertTrue(read.scored.isEmpty)
        XCTAssertNil(DaytimeStress.dayDaytimeAggregate(
            hr: hour(9, bpm: 0), rr: [], tzOffsetSeconds: 0).hr)
    }

    func testThirtyLocalDaysExcludeTodayAndReanchorDSTMidnightTransitions() throws {
        let cases = [
            ("UTC", 2026, 10, 22),
            ("America/New_York", 2026, 3, 20),
            ("America/Santiago", 2026, 9, 20),
            ("Asia/Kathmandu", 2026, 10, 22),
        ]
        for (zone, year, month, day) in cases {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            let now = try XCTUnwrap(calendar.date(from: DateComponents(
                year: year, month: month, day: day, hour: 14)))
            let windows = PersonalStressBaseline.windows(before: now, calendar: calendar)
            XCTAssertEqual(windows.count, 30, zone)
            XCTAssertEqual(windows.last?.endTs, Int(calendar.startOfDay(for: now).timeIntervalSince1970), zone)
            for window in windows {
                let start = Date(timeIntervalSince1970: TimeInterval(window.startTs))
                XCTAssertEqual(start, calendar.startOfDay(for: start), zone)
                XCTAssertLessThanOrEqual(window.endTs, Int(calendar.startOfDay(for: now).timeIntervalSince1970), zone)
                XCTAssertEqual(window.hours.count, 16, zone)
                XCTAssertEqual(calendar.component(.hour, from: Date(timeIntervalSince1970:
                    TimeInterval(try XCTUnwrap(window.hours.first).startTs))), 6, zone)
                XCTAssertEqual(calendar.component(.hour, from: Date(timeIntervalSince1970:
                    TimeInterval(try XCTUnwrap(window.hours.last).endTs))), 22, zone)
            }
            for (previous, next) in zip(windows, windows.dropFirst()) {
                XCTAssertEqual(previous.endTs, next.startTs, zone)
            }
        }
    }
}
