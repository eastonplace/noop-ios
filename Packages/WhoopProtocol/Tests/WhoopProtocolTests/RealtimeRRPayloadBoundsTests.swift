import XCTest
@testable import WhoopProtocol

final class RealtimeRRPayloadBoundsTests: XCTestCase {
    private func le32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    private func frame(family: DeviceFamily, intervals: [UInt8]) -> [UInt8] {
        // timestamp=100, HR=60, declared RR count=255. Only supplied interval bytes are payload.
        let inner: [UInt8] = [40, 0, 100, 0, 0, 0, 0, 0, 60, 255] + intervals
        if family == .whoop4 {
            return frameFromPayload(Array(inner.dropFirst(3)), type: 40, seq: 0, cmd: 100)
        }
        let length = inner.count + 4
        var header: [UInt8] = [0xAA, 1, UInt8(length), 0, 0, 1]
        let checksum = crc16Modbus(header)
        header += [UInt8(truncatingIfNeeded: checksum), UInt8(truncatingIfNeeded: checksum >> 8)]
        return header + inner + le32(crc32(inner))
    }

    func testInflatedRRCountCannotReadChecksumAsIntervals() {
        for family in [DeviceFamily.whoop4, .whoop5] {
            let wire = frame(family: family, intervals: [0xE8, 0x03])
            XCTAssertTrue(verifyFrame(wire, family: family).ok)
            let parsed = parseFrame(wire, family: family)
            XCTAssertEqual(parsed.parsed["rr_intervals"]?.intArrayValue, [1000], "\(family)")
            let streams = extractStreams([parsed], family: family, deviceClockRef: 100, wallClockRef: 1_792_620_000)
            XCTAssertEqual(streams.rr.map(\.rrMs), [1000], "\(family): checksum bytes must never become stored beats")
        }
    }

    func testIncompleteFinalIntervalCannotBorrowChecksumByte() {
        for family in [DeviceFamily.whoop4, .whoop5] {
            let wire = frame(family: family, intervals: [0xE8])
            XCTAssertTrue(verifyFrame(wire, family: family).ok)
            XCTAssertEqual(parseFrame(wire, family: family).parsed["rr_intervals"]?.intArrayValue, [], "\(family)")
        }
    }
}
