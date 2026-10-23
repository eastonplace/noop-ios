import XCTest
@testable import StrandImport

final class WhoopTimeSafetyTests: XCTestCase {
    func testMalformedTimezoneOffsetsFallBackToUTCWithoutOverflow() {
        for offset in [
            "UTC+9223372036854775807:00", "UTC-9223372036854775808:00",
            "UTC+01:9223372036854775807", "UTC+9999999999999999999999999",
            "UTC+01:60", "UTC+19:00", "UTC+01:-30", "UTC+1:bad",
        ] {
            XCTAssertEqual(WhoopTime.tzOffsetMinutes(offset), 0, offset)
        }
        XCTAssertEqual(WhoopTime.tzOffsetMinutes("UTC+18:00"), 1_080)
        XCTAssertEqual(WhoopTime.tzOffsetMinutes("UTC-12:45"), -765)
    }

    func testDirectUnrepresentableOffsetsFallBackToUTCWithoutOverflow() {
        let expected = Fixtures.utc(2024, 1, 2, 6, 30, 0)
        for offset in [Int.max, Int.min, 1_081, -1_081] {
            XCTAssertEqual(WhoopTime.parse("2024-01-02 06:30:00", offsetMinutes: offset), expected)
        }
    }

    func testConcurrentTimestampParsingKeepsEachCallsTimezoneAndPattern() {
        let lock = NSLock()
        var failures = 0
        let cases: [(String, Int, Date)] = [
            ("2024-01-02 06:30:00", 60, Fixtures.utc(2024, 1, 2, 5, 30, 0)),
            ("2024-01-03 00:05", -300, Fixtures.utc(2024, 1, 3, 5, 5, 0)),
            ("2024-01-04", 540, Fixtures.utc(2024, 1, 3, 15, 0, 0)),
        ]
        DispatchQueue.concurrentPerform(iterations: 600) { index in
            let (text, offset, expected) = cases[index % cases.count]
            if WhoopTime.parse(text, offsetMinutes: offset) != expected {
                lock.lock()
                failures += 1
                lock.unlock()
            }
        }
        XCTAssertEqual(failures, 0, "shared formatter configuration must stay paired with its parse")
    }
}
