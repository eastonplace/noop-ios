import Foundation
import XCTest
@testable import NoopPhase34Core

final class CoachBriefWidgetPayloadTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func payload(text: String = "Keep today steady.", strain: Double? = 8.2) throws -> CoachBriefWidgetPayload {
        try XCTUnwrap(CoachBriefWidgetPayload(epoch: 7, contextID: "source-a", generation: 42,
            logicalDay: "2026-09-21", generatedAt: now, kind: .morning, text: text,
            recovery: 75, strain: strain, sleepMinutes: 465))
    }
    func testRoundTripPreservesCompletedBriefAndCapturedMetrics() throws {
        let original = try payload()
        let decoded = try JSONDecoder().decode(CoachBriefWidgetPayload.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.isDisplayable(epoch: 7, contextID: "source-a", logicalDay: "2026-09-21", now: now))
    }
    func testDifferentSourceEpochOrLogicalDayHidesOldBrief() throws {
        let value = try payload()
        XCTAssertFalse(value.isDisplayable(epoch: 8, contextID: "source-a", logicalDay: "2026-09-21", now: now))
        XCTAssertFalse(value.isDisplayable(epoch: 7, contextID: "source-b", logicalDay: "2026-09-21", now: now))
        XCTAssertFalse(value.isDisplayable(epoch: 7, contextID: "source-a", logicalDay: "2026-09-22", now: now))
    }
    func testOldOrFutureBriefCannotLookCurrent() throws {
        let value = try payload()
        XCTAssertFalse(value.isDisplayable(epoch: 7, contextID: "source-a", logicalDay: "2026-09-21", now: now.addingTimeInterval(27 * 3_600)))
        XCTAssertFalse(value.isDisplayable(epoch: 7, contextID: "source-a", logicalDay: "2026-09-21", now: now.addingTimeInterval(-120)))
    }
    func testBoundedUnicodeTextNeverSplitsScalar() throws {
        let value = try payload(text: String(repeating: "🟢", count: 1_000))
        XCTAssertLessThanOrEqual(value.text.utf8.count, CoachBriefWidgetPayload.maximumTextBytes)
        XCTAssertFalse(value.text.contains("�"))
        XCTAssertFalse(value.text.isEmpty)
    }
    func testEmptyBriefAndNonFiniteMetricAreRejected() {
        XCTAssertNil(CoachBriefWidgetPayload(epoch: 1, contextID: "a", generation: 1,
            logicalDay: "2026-09-21", generatedAt: now, kind: .evening, text: " \n "))
        XCTAssertNil(CoachBriefWidgetPayload(epoch: 1, contextID: "a", generation: 1,
            logicalDay: "2026-09-21", generatedAt: now, kind: .morning, text: "A brief.", strain: .nan))
    }
    func testDecodedUnsupportedVersionIsNotDisplayed() throws {
        let data = try JSONEncoder().encode(payload())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["version"] = 99
        let decoded = try JSONDecoder().decode(CoachBriefWidgetPayload.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(decoded.isDisplayable(epoch: 7, contextID: "source-a", logicalDay: "2026-09-21", now: now))
    }
    func testMissingMetricsStayMissing() throws {
        let value = try XCTUnwrap(CoachBriefWidgetPayload(epoch: 7, contextID: "source-a", generation: 42,
            logicalDay: "2026-09-21", generatedAt: now, kind: .evening, text: "Your evening brief."))
        XCTAssertNil(value.recovery); XCTAssertNil(value.strain); XCTAssertNil(value.sleepMinutes)
    }
}
