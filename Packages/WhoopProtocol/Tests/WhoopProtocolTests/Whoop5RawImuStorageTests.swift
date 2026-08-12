import XCTest
@testable import WhoopProtocol

final class Whoop5RawImuStorageTests: XCTestCase {
    private func frame() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Whoop5RawImu.bufferLength)

        func putU16(_ offset: Int, _ value: Int) {
            bytes[offset] = UInt8(value & 0xff)
            bytes[offset + 1] = UInt8((value >> 8) & 0xff)
        }
        func putI16(_ offset: Int, _ value: Int) {
            putU16(offset, value < 0 ? value + 65_536 : value)
        }
        func putU32(_ offset: Int, _ value: UInt32) {
            bytes[offset] = UInt8(value & 0xff)
            bytes[offset + 1] = UInt8((value >> 8) & 0xff)
            bytes[offset + 2] = UInt8((value >> 16) & 0xff)
            bytes[offset + 3] = UInt8((value >> 24) & 0xff)
        }

        putU32(15, 1_800_000_000)
        putU16(24, Whoop5RawImu.sampleCount)
        putU16(630, Whoop5RawImu.sampleCount)
        putI16(28, -4_096)
        putI16(228, 2_048)
        putI16(428, 1_024)
        putI16(640, -328)
        putI16(840, 164)
        putI16(1_040, 82)
        return bytes
    }

    func testRawColumnsPreserveWireOrderAndSignedValues() throws {
        let columns = try XCTUnwrap(Whoop5RawImu.rawColumns(frame()))
        XCTAssertEqual(columns.count, 600)
        XCTAssertEqual(columns[0], -4_096)
        XCTAssertEqual(columns[100], 2_048)
        XCTAssertEqual(columns[200], 1_024)
        XCTAssertEqual(columns[300], -328)
        XCTAssertEqual(columns[400], 164)
        XCTAssertEqual(columns[500], 82)
    }

    func testBaseTimestampRequiresTheCompleteImuShape() {
        XCTAssertEqual(Whoop5RawImu.baseTs(frame()), 1_800_000_000)
        XCTAssertNil(Whoop5RawImu.baseTs([0, 1, 2]))

        var unrelatedLongFrame = frame()
        unrelatedLongFrame[24] = 0
        unrelatedLongFrame[25] = 0
        XCTAssertNil(Whoop5RawImu.baseTs(unrelatedLongFrame))
    }

    func testDecodeAndRawColumnsRejectTrailingOrTruncatedBytes() {
        let valid = frame()
        XCTAssertNotNil(Whoop5RawImu.decode(valid))
        XCTAssertNotNil(Whoop5RawImu.rawColumns(valid))
        XCTAssertNil(Whoop5RawImu.decode(valid + [0]))
        XCTAssertNil(Whoop5RawImu.rawColumns(valid + [0]))
        XCTAssertNil(Whoop5RawImu.decode(Array(valid.dropLast())))
        XCTAssertNil(Whoop5RawImu.rawColumns(Array(valid.dropLast())))
    }
}
