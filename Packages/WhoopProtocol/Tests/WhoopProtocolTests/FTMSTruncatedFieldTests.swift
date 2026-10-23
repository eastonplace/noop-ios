import XCTest
@testable import WhoopProtocol

final class FTMSTruncatedFieldTests: XCTestCase {
    func testTruncatedMultibyteFieldsCannotBecomeLaterHeartRate() {
        // Each flag set announces a heart-rate byte AFTER an incomplete multibyte field.
        let cases: [(String, [UInt8])] = [
            ("2ACD", [0x00, 0x01, 99]),        // treadmill instantaneous speed (u16)
            ("2AD2", [0x00, 0x02, 99]),        // bike instantaneous speed (u16)
            ("2AD1", [0x00, 0x02, 100, 99]),   // rower stroke rate (u8), stroke count (u16)
            ("2ACE", [0x00, 0x08, 0x00, 99]), // cross-trainer instantaneous speed (u16)
            ("2AD2", [0x11, 0x02, 80, 99]),    // bike distance (u24), no instantaneous speed
            ("2AD2", [0x41, 0x02, 99]),        // bike power (s16), no instantaneous speed
        ]
        for (uuid, bytes) in cases {
            let reading = FTMSDecode.decode(uuid16: uuid, bytes)
            XCTAssertNotNil(reading, uuid)
            XCTAssertNil(reading?.heartRate, "\(uuid): incomplete earlier field cannot supply HR")
        }
    }

    func testTruncationPreservesFieldsThatCompletedBeforeIt() {
        // Bike speed=10 km/h completed; truncated cadence must not become heart rate.
        let reading = FTMSDecode.indoorBike([0x04, 0x02, 0xE8, 0x03, 99])
        XCTAssertEqual(reading?.speedKmh, 10)
        XCTAssertNil(reading?.cadence)
        XCTAssertNil(reading?.heartRate)
    }
}
