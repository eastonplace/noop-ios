import XCTest
@testable import NOOP

final class ImportTimestampHardeningTests: XCTestCase {

    func testHypnogramEfficiencyIgnoresBadSegmentsAndRejectsOverflowingSessionSpans() throws {
        let valid: [[String: Any]] = [["start": 0, "end": 50, "stage": "light"]]
        let malformed = ["start": Int.min, "end": Int.max, "stage": "deep"] as [String: Any]
        let mixed = valid + [malformed]

        let xiaomi = try XCTUnwrap(XiaomiImporter.efficiency(segs: mixed, start: 0, end: 100))
        let wearable = try XCTUnwrap(WearableImporter.efficiency(segs: mixed, start: 0, end: 100))
        XCTAssertEqual(xiaomi, 50, accuracy: 0.001)
        XCTAssertEqual(wearable, 50, accuracy: 0.001)
        XCTAssertNil(XiaomiImporter.efficiency(segs: valid, start: Int.min, end: Int.max))
        XCTAssertNil(WearableImporter.efficiency(segs: valid, start: Int.min, end: Int.max))

        let normalDate = Date(timeIntervalSince1970: 1_000)
        let extremeDate = Date(timeIntervalSince1970: Double(Int.max))
        XCTAssertEqual(XiaomiImporter.timestamp(normalDate), 1_000)
        XCTAssertEqual(WearableImporter.timestamp(normalDate), 1_000)
        XCTAssertNil(XiaomiImporter.timestamp(extremeDate))
        XCTAssertNil(WearableImporter.timestamp(extremeDate))
    }

    func testShortcutImportDropsOverflowingWorkoutSpanAndKeepsValidRows() {
        let parsed = ShortcutHealthImport.parse("""
        W,1000,2800,Running,,,
        W,\(Int.min),\(Int.max),Cycling,,,
        """)

        XCTAssertEqual(parsed.workouts.count, 1)
        XCTAssertEqual(parsed.workouts.first?.startTs, 1000)
        XCTAssertEqual(parsed.workouts.first?.durationS, 1800)
    }
}
