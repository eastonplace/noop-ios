import XCTest
@testable import WhoopProtocol

final class Whoop5EnvelopeIntegrityRegressionTests: XCTestCase {
    func testValidDeclaredFrameWithTrailingBytesFailsCompleteEnvelopeValidation() {
        let frame = puffinCommandFrame(cmd: 20, seq: 1, payload: [0x01])
        let baseline = verifyFrame(frame, family: .whoop5)
        XCTAssertTrue(baseline.ok)
        XCTAssertEqual(baseline.crc8OK, true)
        XCTAssertEqual(baseline.crc32OK, true)

        let check = verifyFrame(frame + [0x99], family: .whoop5)

        XCTAssertFalse(check.ok)
        XCTAssertEqual(check.crc8OK, true, "The declared frame header remains valid")
        XCTAssertEqual(check.crc32OK, true, "The declared payload remains valid; the unprotected trailing byte must still invalidate the envelope")
    }
}
