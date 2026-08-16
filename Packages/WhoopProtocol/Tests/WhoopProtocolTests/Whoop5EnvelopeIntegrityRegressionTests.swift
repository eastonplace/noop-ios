import XCTest
@testable import WhoopProtocol

final class Whoop5EnvelopeIntegrityRegressionTests: XCTestCase {
    private let whoop5V18Hex =
        "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817"

    private func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)!
        }
    }

    private func disposition(_ frame: [UInt8]) -> HistoricalRecordDisposition {
        historicalRecordDisposition(
            parsed: parseFrame(frame, family: .whoop5),
            rawFrame: frame,
            family: .whoop5)
    }

    func testValidFramePropagatesCompleteIntegrityVerdict() {
        let parsed = parseFrame(bytes(whoop5V18Hex), family: .whoop5)

        XCTAssertTrue(parsed.envelopeOK)
        XCTAssertEqual(parsed.headerCRCOK, true)
        XCTAssertEqual(parsed.payloadCRCOK, true)
    }

    func testBadHeaderCRCIsRejectedAtHistoryBoundary() {
        var frame = bytes(whoop5V18Hex)
        frame[4] ^= 0x01
        let parsed = parseFrame(frame, family: .whoop5)

        XCTAssertTrue(parsed.envelopeOK)
        XCTAssertEqual(parsed.headerCRCOK, false)
        XCTAssertEqual(parsed.payloadCRCOK, true)
        XCTAssertEqual(disposition(frame), .invalidCRC(version: 18))
    }

    func testBadPayloadCRCIsRejectedAtHistoryBoundary() {
        var frame = bytes(whoop5V18Hex)
        frame[20] ^= 0x01
        let parsed = parseFrame(frame, family: .whoop5)

        XCTAssertTrue(parsed.envelopeOK)
        XCTAssertEqual(parsed.headerCRCOK, true)
        XCTAssertEqual(parsed.payloadCRCOK, false)
        XCTAssertEqual(disposition(frame), .invalidCRC(version: 18))
    }

    func testUnavailablePayloadCRCVerdictIsRejectedAtHistoryBoundary() {
        var frame = Array(bytes(whoop5V18Hex).dropLast(4))
        let declared = frame.count + 8
        frame[2] = UInt8(declared & 0xff)
        frame[3] = UInt8((declared >> 8) & 0xff)
        let headerCRC = crc16Modbus(frame, 0, 6)
        frame[6] = UInt8(headerCRC & 0xff)
        frame[7] = UInt8(headerCRC >> 8)
        let parsed = parseFrame(frame, family: .whoop5)

        XCTAssertFalse(parsed.envelopeOK)
        XCTAssertEqual(parsed.headerCRCOK, true)
        XCTAssertNil(parsed.payloadCRCOK)
        XCTAssertEqual(disposition(frame), .invalidEnvelope(version: 18))
    }

    func testDeclaredLengthMismatchIsRejectedAtHistoryBoundary() {
        var frame = bytes(whoop5V18Hex)
        let declared = Int(frame[2]) | (Int(frame[3]) << 8)
        let mismatched = declared + 1
        frame[2] = UInt8(mismatched & 0xff)
        frame[3] = UInt8((mismatched >> 8) & 0xff)
        let headerCRC = crc16Modbus(frame, 0, 6)
        frame[6] = UInt8(headerCRC & 0xff)
        frame[7] = UInt8(headerCRC >> 8)
        let parsed = parseFrame(frame, family: .whoop5)

        XCTAssertFalse(parsed.envelopeOK)
        XCTAssertEqual(parsed.headerCRCOK, true)
        XCTAssertNil(parsed.payloadCRCOK)
        XCTAssertEqual(disposition(frame), .invalidEnvelope(version: 18))
    }

    func testValidDeclaredFrameWithTrailingBytesFailsCompleteEnvelopeValidation() {
        let frame = bytes(whoop5V18Hex)
        let baseline = verifyFrame(frame, family: .whoop5)
        XCTAssertTrue(baseline.ok)
        XCTAssertEqual(baseline.crc8OK, true)
        XCTAssertEqual(baseline.crc32OK, true)

        let trailing = frame + [0x99]
        let check = verifyFrame(trailing, family: .whoop5)
        let parsed = parseFrame(trailing, family: .whoop5)

        XCTAssertFalse(check.ok)
        XCTAssertEqual(check.crc8OK, true, "The declared frame header remains valid")
        XCTAssertEqual(check.crc32OK, true, "The declared payload remains valid; the unprotected trailing byte must still invalidate the envelope")
        XCTAssertFalse(parsed.envelopeOK)
        XCTAssertEqual(parsed.headerCRCOK, true)
        XCTAssertEqual(parsed.payloadCRCOK, true)
        XCTAssertEqual(disposition(trailing), .invalidEnvelope(version: 18))
    }
}
