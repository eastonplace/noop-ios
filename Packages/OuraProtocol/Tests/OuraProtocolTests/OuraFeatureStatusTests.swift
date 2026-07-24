import XCTest
@testable import OuraProtocol

final class OuraFeatureStatusTests: XCTestCase {
    func testStatusQueryCommandsUseReadVerbOnly() {
        XCTAssertEqual(OuraCommands.spo2ReadStatus().bytes, [0x2f, 0x02, 0x20, 0x04])
        XCTAssertEqual(OuraCommands.realStepsReadStatus().bytes, [0x2f, 0x02, 0x20, 0x0b])
        XCTAssertFalse(OuraCommands.spo2ReadStatus().bytes.contains(0x22))
        XCTAssertFalse(OuraCommands.realStepsReadStatus().bytes.contains(0x22))
    }

    func testDecodesFiveStatusBytesAndRejectsShortBodies() {
        XCTAssertEqual(
            OuraDecoders.decodeFeatureStatus([0x04, 0x01, 0x11, 0x02, 0x00]),
            OuraFeatureStatus(feature: 4, mode: 1, status: 17, state: 2, subscription: 0)
        )
        XCTAssertNil(OuraDecoders.decodeFeatureStatus([0x04, 0x01]))
        XCTAssertNil(OuraDecoders.decodeFeatureStatus([]))
    }

    func testProbeKeepsDaytimeHeartRateAckOutOfDiagnostics() {
        XCTAssertNil(OuraFeatureStatusProbe.diagnosticStatus(
            from: OuraSecureFrame(subop: 0x21, subBody: [0x02, 0x01, 0x11, 0x02, 0x00])
        ))
    }

    func testProbeSurfacesSpO2AndRealStepsSubscriptionState() {
        XCTAssertEqual(
            OuraFeatureStatusProbe.diagnosticStatus(
                from: OuraSecureFrame(subop: 0x21, subBody: [0x04, 0, 0, 0, 0])
            ),
            OuraFeatureStatus(feature: 4, mode: 0, status: 0, state: 0, subscription: 0)
        )
        XCTAssertEqual(
            OuraFeatureStatusProbe.diagnosticStatus(
                from: OuraSecureFrame(subop: 0x21, subBody: [0x0b, 0, 0, 0, 0])
            ),
            OuraFeatureStatus(feature: 11, mode: 0, status: 0, state: 0, subscription: 0)
        )
    }
}
