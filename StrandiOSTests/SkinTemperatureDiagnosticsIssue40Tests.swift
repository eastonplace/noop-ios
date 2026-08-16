
import XCTest
@testable import NOOP

final class SkinTemperatureDiagnosticsIssue40Tests: XCTestCase {
    func testBackfillSummaryKeepsSkinTemperatureCountVisible() {
        let line = Backfiller.sessionSummaryLine(
            rows: 42,
            motion: 18,
            skinTemp: 3,
            nights: 1
        )

        XCTAssertTrue(line?.contains("3 skin-temp") == true)
    }

    func testStructuredTraceIsDayLevelAndPrivacySafe() {
        let trace = SkinTemperatureTrace(
            stage: .analysis,
            source: .wearable,
            family: "whoop5",
            day: "2026-08-16",
            queryFrom: 100,
            queryTo: 200,
            sampleCount: 80,
            firstTimestamp: 110,
            lastTimestamp: 190,
            persistenceOutcome: nil,
            insertedCount: nil,
            conversionCount: 64,
            isAvailable: true)

        XCTAssertTrue(trace.line.contains("day=2026-08-16"))
        XCTAssertTrue(trace.line.contains("samples=80"))
        XCTAssertTrue(trace.line.contains("converted=64"))
        XCTAssertTrue(trace.line.contains("available=true"))
        XCTAssertFalse(trace.line.contains("deviceId"))
    }

    func testLocalDaySeparatesSamplesAcrossMidnight() throws {
        let formatter = ISO8601DateFormatter()
        let timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let before = try XCTUnwrap(formatter.date(from: "2026-08-16T03:59:59Z"))
        let after = try XCTUnwrap(formatter.date(from: "2026-08-16T04:00:00Z"))

        XCTAssertEqual(
            SkinTemperatureTrace.localDay(for: Int(before.timeIntervalSince1970), timeZone: timeZone),
            "2026-08-15")
        XCTAssertEqual(
            SkinTemperatureTrace.localDay(for: Int(after.timeIntervalSince1970), timeZone: timeZone),
            "2026-08-16")
    }

    func testLocalDaySurvivesSpringForwardGap() throws {
        let formatter = ISO8601DateFormatter()
        let timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let beforeGap = try XCTUnwrap(formatter.date(from: "2026-03-08T06:59:59Z"))
        let afterGap = try XCTUnwrap(formatter.date(from: "2026-03-08T07:00:00Z"))

        XCTAssertEqual(
            SkinTemperatureTrace.localDay(for: Int(beforeGap.timeIntervalSince1970), timeZone: timeZone),
            "2026-03-08")
        XCTAssertEqual(
            SkinTemperatureTrace.localDay(for: Int(afterGap.timeIntervalSince1970), timeZone: timeZone),
            "2026-03-08")
    }
}
