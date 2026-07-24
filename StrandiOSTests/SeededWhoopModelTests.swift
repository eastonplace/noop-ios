import XCTest
@testable import NOOP

final class SeededWhoopModelTests: XCTestCase {
    func testGenericSeedResolvesToWhoop4WhenFiveIsNotDetected() {
        XCTAssertEqual(
            SeededWhoopModelResolver.correctedModel(
                current: "WHOOP",
                whoop5Detected: false
            ),
            "WHOOP 4.0"
        )
    }

    func testGenericSeedResolvesToWhoop5FamilyWhenDetected() {
        XCTAssertEqual(
            SeededWhoopModelResolver.correctedModel(
                current: " whoop ",
                whoop5Detected: true
            ),
            "WHOOP 5.0 / MG"
        )
    }

    func testSpecificModelIsNeverOverwritten() {
        XCTAssertNil(SeededWhoopModelResolver.correctedModel(
            current: "WHOOP 4.0",
            whoop5Detected: true
        ))
        XCTAssertNil(SeededWhoopModelResolver.correctedModel(
            current: "WHOOP 5.0 / MG",
            whoop5Detected: false
        ))
        XCTAssertNil(SeededWhoopModelResolver.correctedModel(
            current: "Oura Gen 4",
            whoop5Detected: false
        ))
    }
}
