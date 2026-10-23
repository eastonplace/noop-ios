import XCTest
@testable import WhoopProtocol

final class ReassemblyEventTests: XCTestCase {
    private func frame(_ family: DeviceFamily, sequence: UInt8) -> [UInt8] {
        family == .whoop4
            ? frameFromPayload([1, 2], type: 47, seq: sequence)
            : puffinCommandFrame(cmd: 0, seq: sequence, payload: [1, 2], type: 47)
    }

    private func badHeader(_ family: DeviceFamily) -> [UInt8] {
        if family == .whoop4 { return [0xAA, 100, 0, crc8([100, 0]) ^ 1] }
        var header: [UInt8] = [0xAA, 1, 100, 0, 0, 1]
        let checksum = crc16Modbus(header) ^ 1
        header += [UInt8(checksum & 255), UInt8(checksum >> 8)]
        return header
    }

    func testCorruptCandidateRemainsOrderedBetweenFrames() {
        for family in DeviceFamily.allCases {
            let first = frame(family, sequence: 1)
            let last = frame(family, sequence: 2)
            let corrupt = badHeader(family)
            XCTAssertEqual(Reassembler(family: family).feedEvents(first + corrupt + last),
                           [.frame(first), .discardedBytes(corrupt.count), .frame(last)])
        }
    }

    func testFragmentedBadHeaderReportsLossOnlyWhenKnown() {
        for family in DeviceFamily.allCases {
            let corrupt = badHeader(family)
            let last = frame(family, sequence: 2)
            for split in 1..<corrupt.count {
                let decoder = Reassembler(family: family)
                XCTAssertEqual(decoder.feedEvents(Array(corrupt[..<split])), [])
                XCTAssertEqual(decoder.feedEvents(Array(corrupt[split...]) + last),
                               [.discardedBytes(corrupt.count), .frame(last)])
                XCTAssertEqual(decoder.feedEvents([]), [])
            }
        }
    }

    func testNoiseOutsideFramesIsReportedWithoutChangingLegacyFrameOutput() {
        for family in DeviceFamily.allCases {
            let valid = frame(family, sequence: 1)
            let bytes: [UInt8] = [1, 2, 3] + valid + [4, 5]
            XCTAssertEqual(Reassembler(family: family).feedEvents(bytes),
                           [.discardedBytes(3), .frame(valid), .discardedBytes(2)])
            XCTAssertEqual(Reassembler(family: family).feed(bytes), [valid])
        }
    }

    func testOtherCharacteristicCannotSpliceIntoAnIncompleteFrame() {
        for family in DeviceFamily.allCases {
            let windows = ReassemblerSet<String>(family: family)
            let valid = frame(family, sequence: 1)
            let split = valid.count / 2
            XCTAssertEqual(windows.feedEvents(Array(valid[..<split]), from: "data"), [])
            let corrupt = badHeader(family)
            XCTAssertEqual(windows.feedEvents(corrupt, from: "command"), [.discardedBytes(corrupt.count)])
            XCTAssertEqual(windows.feedEvents(Array(valid[split...]), from: "data"), [.frame(valid)])
        }
    }

    func testResetDiscardsOldConnectionFragmentsAndLoss() {
        let windows = ReassemblerSet<String>()
        let valid = frame(.whoop4, sequence: 1)
        XCTAssertEqual(windows.feedEvents(Array(valid.prefix(3)), from: "data"), [])
        windows.reset()
        XCTAssertEqual(windows.feedEvents(valid, from: "data"), [.frame(valid)])
    }
}
