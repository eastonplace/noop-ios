import XCTest
@testable import WhoopProtocol

final class Whoop5V18SpO2CandidateTests: XCTestCase {
    func testClassifiesInBandPercentagesWithoutPromotingOtherValues() {
        XCTAssertEqual(Whoop5V18SpO2Candidate.decode(raw: 70), .percentage(70))
        XCTAssertEqual(Whoop5V18SpO2Candidate.decode(raw: 96), .percentage(96))
        XCTAssertEqual(Whoop5V18SpO2Candidate.decode(raw: 100), .percentage(100))
        XCTAssertEqual(Whoop5V18SpO2Candidate.decode(raw: 0), .absent)
        XCTAssertEqual(Whoop5V18SpO2Candidate.decode(raw: 42), .diagnosticCode(42))
        XCTAssertEqual(Whoop5V18SpO2Candidate.decode(raw: 0x80), .saturationSentinel(0x80))
        XCTAssertEqual(Whoop5V18SpO2Candidate.decode(raw: 0xa0), .saturationSentinel(0xa0))
    }

    func testReadsOnlyTheDocumentedV18FrameOffset() throws {
        var frame = [UInt8](repeating: 0, count: 120)
        frame[81] = 99
        frame[Whoop5V18SpO2Candidate.frameOffset] = 94
        frame[83] = 98

        let decoded = try XCTUnwrap(Whoop5V18SpO2Candidate.decode(frame: frame))
        XCTAssertEqual(decoded, .percentage(94))
        XCTAssertEqual(decoded.candidatePercentage, 94)
    }

    func testShortFrameFailsClosed() {
        XCTAssertNil(Whoop5V18SpO2Candidate.decode(frame: [UInt8](repeating: 0, count: 82)))
    }

    func testNonPercentageCasesNeverExposeCandidatePercentage() {
        XCTAssertNil(Whoop5V18SpO2Candidate.decode(raw: 0).candidatePercentage)
        XCTAssertNil(Whoop5V18SpO2Candidate.decode(raw: 12).candidatePercentage)
        XCTAssertNil(Whoop5V18SpO2Candidate.decode(raw: 0x80).candidatePercentage)
    }
}
