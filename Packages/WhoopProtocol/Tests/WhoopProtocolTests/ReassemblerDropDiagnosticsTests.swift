import XCTest
@testable import WhoopProtocol

/// The upstream header-drop counter is adapted to this fork's independent characteristic windows.
/// These assertions pin both its reset semantics and the frame sequence relied on by history ingest.
final class ReassemblerDropDiagnosticsTests: XCTestCase {
    private let families: [DeviceFamily] = [.whoop4, .whoop5]

    private func header(
        family: DeviceFamily,
        declaredLength: UInt16,
        invalidChecksum: Bool = false
    ) -> [UInt8] {
        let low = UInt8(declaredLength & 0xFF)
        let high = UInt8(declaredLength >> 8)
        var result: [UInt8]
        switch family {
        case .whoop4:
            result = [0xAA, low, high, crc8([low, high])]
            if invalidChecksum { result[3] ^= 0x01 }
        case .whoop5:
            result = [0xAA, 0x01, low, high, 0x00, 0x01]
            let checksum = crc16Modbus(result)
            result += [UInt8(checksum & 0xFF), UInt8(checksum >> 8)]
            if invalidChecksum { result[6] ^= 0x01 }
        }
        return result
    }

    private func frame(
        family: DeviceFamily,
        sequence: UInt8,
        payload: [UInt8] = [0x01, 0x02]
    ) -> [UInt8] {
        switch family {
        case .whoop4:
            return frameFromPayload(payload, type: 47, seq: sequence)
        case .whoop5:
            return puffinCommandFrame(cmd: 0, seq: sequence, payload: payload, type: 47)
        }
    }

    func testHeaderDropsAreCountedWithoutSwallowingFollowingFramesOnEitherFamily() {
        for family in families {
            let first = frame(family: family, sequence: 1)
            let second = frame(family: family, sequence: 2)
            let falseStart = header(family: family, declaredLength: 100, invalidChecksum: true)
            XCTAssertFalse(falseStart.dropFirst().contains(0xAA), "fixture has only one candidate")
            let reassembler = Reassembler(family: family)

            XCTAssertEqual(reassembler.feed(falseStart + first + second), [first, second])
            XCTAssertEqual(reassembler.headerChecksumDrops, 1)
            XCTAssertEqual(reassembler.oversizedLengthDrops, 0)
        }
    }

    func testAnIncompleteHeaderIsNotCountedUntilItsChecksumIsAvailable() {
        for family in families {
            let falseStart = header(family: family, declaredLength: 100, invalidChecksum: true)
            let valid = frame(family: family, sequence: 1)
            for split in 1..<falseStart.count {
                let reassembler = Reassembler(family: family)
                XCTAssertEqual(reassembler.feed(Array(falseStart[..<split])), [])
                XCTAssertEqual(reassembler.headerChecksumDrops, 0)

                XCTAssertEqual(reassembler.feed(Array(falseStart[split...]) + valid), [valid])
                XCTAssertEqual(reassembler.headerChecksumDrops, 1)
                XCTAssertEqual(reassembler.feed([]), [])
                XCTAssertEqual(reassembler.headerChecksumDrops, 1, "empty feeds cannot recount a drop")
            }
        }
    }

    func testHeaderValidOversizedCandidatesUseTheirOwnCounter() {
        for family in families {
            let oversized = header(family: family, declaredLength: 0xFFFF)
            XCTAssertFalse(oversized.dropFirst().contains(0xAA), "fixture has only one candidate")
            let valid = frame(family: family, sequence: 1)
            let reassembler = Reassembler(family: family)

            XCTAssertEqual(reassembler.feed(oversized + valid), [valid])
            XCTAssertEqual(reassembler.headerChecksumDrops, 0)
            XCTAssertEqual(reassembler.oversizedLengthDrops, 1)
        }
    }

    func testInvalidHeaderStillWinsBeforeTheExistingSizeCap() {
        for family in families {
            let oversized = header(family: family, declaredLength: 0xFFFF, invalidChecksum: true)
            let valid = frame(family: family, sequence: 1)
            let reassembler = Reassembler(family: family)

            XCTAssertEqual(reassembler.feed(oversized + valid), [valid])
            XCTAssertEqual(reassembler.headerChecksumDrops, 1)
            XCTAssertEqual(reassembler.oversizedLengthDrops, 0,
                           "preserve the fork's header-first admission and diagnostic order")
        }
    }

    func testPayloadChecksumFailuresRemainInTheirOriginalFrameOrder() {
        for family in families {
            let first = frame(family: family, sequence: 1)
            var invalid = frame(family: family, sequence: 2,
                                payload: [0xAA, 0x64, 0x00, 0x00])
            invalid[invalid.count - 1] ^= 0x01
            let last = frame(family: family, sequence: 3)
            let check = verifyFrame(invalid, family: family)
            XCTAssertEqual(check.crc8OK, true, "the boundary is trustworthy")
            XCTAssertEqual(check.crc32OK, false, "fixture must fail its payload checksum")
            let reassembler = Reassembler(family: family)

            XCTAssertEqual(reassembler.feed(first + invalid + last), [first, invalid, last],
                           "history ingest must receive the invalid frame in sequence before an END")
            XCTAssertEqual(reassembler.headerChecksumDrops, 0,
                           "a payload's 0xAA is not a false start when its frame boundary is known")
            XCTAssertEqual(reassembler.oversizedLengthDrops, 0)
        }
    }

    func testHeaderValidUndersizedEnvelopesStillReachTheExistingDownstreamGate() {
        for family in families {
            let first = frame(family: family, sequence: 1)
            let undersized = header(family: family, declaredLength: 0)
            let last = frame(family: family, sequence: 3)
            XCTAssertFalse(verifyFrame(undersized, family: family).ok)
            let reassembler = Reassembler(family: family)

            XCTAssertEqual(reassembler.feed(first + undersized + last), [first, undersized, last],
                           "this diagnostics port must not insert an upstream lower-bound drop")
            XCTAssertEqual(reassembler.headerChecksumDrops, 0)
            XCTAssertEqual(reassembler.oversizedLengthDrops, 0)
        }
    }

    func testSetAggregatesIndependentCharacteristicsWithoutRecountingReads() {
        for family in families {
            let set = ReassemblerSet<String>(family: family)
            let valid = frame(family: family, sequence: 1)
            let badHeader = header(family: family, declaredLength: 100, invalidChecksum: true)
            let oversized = header(family: family, declaredLength: 0xFFFF)
            let split = valid.count / 2
            XCTAssertEqual(set.feed(Array(valid[..<split]), from: "data"), [])
            XCTAssertEqual(set.feed(badHeader + valid, from: "command"), [valid])
            XCTAssertEqual(set.feed(oversized + valid, from: "event"), [valid])
            XCTAssertEqual(set.feed(Array(valid[split...]), from: "data"), [valid],
                           "other characteristics must not disturb the data window")

            for _ in 0..<3 {
                XCTAssertEqual(set.headerChecksumDrops, 1)
                XCTAssertEqual(set.oversizedLengthDrops, 1)
            }
            XCTAssertEqual(set.feed([], from: "command"), [])
            XCTAssertEqual(set.headerChecksumDrops, 1)
            XCTAssertEqual(set.oversizedLengthDrops, 1)
            XCTAssertEqual(set.feed(badHeader, from: "event"), [])
            XCTAssertEqual(set.headerChecksumDrops, 2)
            XCTAssertEqual(set.oversizedLengthDrops, 1)
        }
    }

    func testResetClearsCountersAndTheNextWindowCanReportAgain() {
        for family in families {
            let set = ReassemblerSet<String>(family: family)
            let badHeader = header(family: family, declaredLength: 100, invalidChecksum: true)
            let oversized = header(family: family, declaredLength: 0xFFFF)
            XCTAssertEqual(set.feed(badHeader, from: "data"), [])
            XCTAssertEqual(set.feed(oversized, from: "command"), [])
            XCTAssertEqual(set.headerChecksumDrops, 1)
            XCTAssertEqual(set.oversizedLengthDrops, 1)

            set.reset()
            XCTAssertEqual(set.family, family)
            XCTAssertEqual(set.headerChecksumDrops, 0)
            XCTAssertEqual(set.oversizedLengthDrops, 0)
            XCTAssertEqual(set.feed(badHeader + oversized, from: "data"), [])
            XCTAssertEqual(set.headerChecksumDrops, 1)
            XCTAssertEqual(set.oversizedLengthDrops, 1)
        }
    }

    func testFamilySwitchResetsBothTotalsBeforeNewFamilyReports() {
        let set = ReassemblerSet<String>()
        XCTAssertEqual(set.feed(header(family: .whoop4, declaredLength: 100, invalidChecksum: true),
                                from: "data"), [])
        XCTAssertEqual(set.feed(header(family: .whoop4, declaredLength: 0xFFFF),
                                from: "command"), [])
        XCTAssertEqual(set.headerChecksumDrops, 1)
        XCTAssertEqual(set.oversizedLengthDrops, 1)

        set.reset(family: .whoop5)
        XCTAssertEqual(set.family, .whoop5)
        XCTAssertEqual(set.headerChecksumDrops, 0)
        XCTAssertEqual(set.oversizedLengthDrops, 0)
        XCTAssertEqual(set.feed(header(family: .whoop5, declaredLength: 100, invalidChecksum: true),
                                from: "fd4b0003"), [])
        XCTAssertEqual(set.feed(header(family: .whoop5, declaredLength: 0xFFFF),
                                from: "fd4b0004"), [])
        XCTAssertEqual(set.headerChecksumDrops, 1)
        XCTAssertEqual(set.oversizedLengthDrops, 1)
    }
}
