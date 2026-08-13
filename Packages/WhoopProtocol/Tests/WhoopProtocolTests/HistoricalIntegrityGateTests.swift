import XCTest
@testable import WhoopProtocol

final class HistoricalIntegrityGateTests: XCTestCase {
    private let ts = Int(Date().timeIntervalSince1970) - 60

    private func frame(
        envelopeOK: Bool,
        headerCRCOK: Bool?,
        payloadCRCOK: Bool?,
        legacyCRCOK: Bool? = true
    ) -> ParsedFrame {
        ParsedFrame(
            ok: true,
            typeName: "HISTORICAL_DATA",
            seq: 18,
            cmdName: nil,
            crcOK: legacyCRCOK,
            envelopeOK: envelopeOK,
            headerCRCOK: headerCRCOK,
            payloadCRCOK: payloadCRCOK,
            lenBytes: 124,
            rawHex: "",
            fields: [],
            parsed: ["unix": .int(ts), "heart_rate": .int(63)]
        )
    }

    func testExtractorRequiresEnvelopeAndBothChecksums() {
        let valid = extractHistoricalStreams(
            [frame(envelopeOK: true, headerCRCOK: true, payloadCRCOK: true)],
            deviceClockRef: ts,
            wallClockRef: ts
        )
        XCTAssertEqual(valid.hr.map(\.bpm), [63])

        let failures = [
            frame(envelopeOK: false, headerCRCOK: true, payloadCRCOK: true),
            frame(envelopeOK: true, headerCRCOK: false, payloadCRCOK: true),
            frame(envelopeOK: true, headerCRCOK: nil, payloadCRCOK: true),
            frame(envelopeOK: true, headerCRCOK: true, payloadCRCOK: false),
            frame(envelopeOK: true, headerCRCOK: true, payloadCRCOK: nil),
        ]
        for invalid in failures {
            XCTAssertTrue(
                extractHistoricalStreams([invalid], deviceClockRef: ts, wallClockRef: ts).hr.isEmpty
            )
        }
    }

    func testSyntheticInitializerFailsClosedWithoutExplicitIntegrity() {
        let synthetic = ParsedFrame(
            ok: true,
            typeName: "HISTORICAL_DATA",
            seq: 18,
            cmdName: nil,
            crcOK: true,
            lenBytes: 124,
            rawHex: "",
            fields: [],
            parsed: ["unix": .int(ts), "heart_rate": .int(63)]
        )
        XCTAssertFalse(synthetic.envelopeOK)
        XCTAssertNil(synthetic.headerCRCOK)
        XCTAssertNil(synthetic.payloadCRCOK)
        XCTAssertTrue(
            extractHistoricalStreams([synthetic], deviceClockRef: ts, wallClockRef: ts).hr.isEmpty
        )
    }
}
