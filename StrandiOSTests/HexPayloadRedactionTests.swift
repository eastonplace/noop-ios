import XCTest
@testable import NOOP

final class HexPayloadRedactionTests: XCTestCase {
    private let payloadWithSerial = "142e1c0001d36e3d1c12a3574242354150303533393835320000"
    private let serialAsHex = "4242354150303533393835"

    func testSerialInsideHexPayloadIsMaskedWithoutDestroyingOtherBytes() {
        let output = LiveState.redactPii("[event] 0x6D(109) payload=\(payloadWithSerial)")
        XCTAssertFalse(output.contains(serialAsHex))
        XCTAssertTrue(output.contains("142e1c0001d36e3d1c12a3"))
    }

    func testSerialIsMaskedUnderEveryCurrentHexDumpLabel() {
        for line in [
            "frame=\(payloadWithSerial)",
            "[raw \(payloadWithSerial)]",
            "(raw \(payloadWithSerial))",
            "raw frame (#900) \(payloadWithSerial)",
            payloadWithSerial,
        ] {
            XCTAssertFalse(LiveState.redactPii(line).contains(serialAsHex), line)
        }
    }

    func testOddLengthAndDigitPrefixedRunsStillMaskSerial() {
        XCTAssertFalse(
            LiveState.redactPii("payload=\(payloadWithSerial)f").contains(serialAsHex)
        )
        let digitPrefixed = "3031323357424235415030353339383532" + "00" + "0000000000000000"
        let output = LiveState.redactPii("payload=\(digitPrefixed)")
        XCTAssertFalse(output.contains(serialAsHex))
        XCTAssertFalse(output.contains("30313233"), "the complete qualifying run must be masked")
    }

    func testLateLetterSerialAndLengthBoundaries() {
        let lateLetterSerial = "313233343536373839414243" // 123456789ABC
        let output = LiveState.redactPii("payload=\(lateLetterSerial)")
        XCTAssertFalse(output.contains(lateLetterSerial))
        XCTAssertTrue(output.contains(String(repeating: "•", count: lateLetterSerial.count)))

        let eightByteAlphanumeric = "4142434445464748" // ABCDEFGH
        XCTAssertEqual(
            LiveState.redactPii("payload=\(eightByteAlphanumeric)"),
            "payload=\(eightByteAlphanumeric)"
        )
        let nineByteDigits = "313233343536373839" // 123456789
        XCTAssertEqual(
            LiveState.redactPii("payload=\(nineByteDigits)"),
            "payload=\(nineByteDigits)"
        )
    }

    func testNonAsciiPayloadTextRulesAndServiceUuidRemainStable() {
        for payload in ["707d0000707d0000", "b87e0000b87e0000", "0000000000000000"] {
            XCTAssertEqual(LiveState.redactPii("payload=\(payload)"), "payload=\(payload)")
        }
        XCTAssertEqual(
            LiveState.redactPii("connecting to A1:B2:C3:D4:E5:F6"),
            "connecting to A1:••:••:••:••:F6"
        )
        XCTAssertTrue(LiveState.redactPii("Discovered WHOOP 4A2B9C1D").contains("<serial>"))
        let service = "61080003-8d6d-82b8-614a-1c8cb0f8dcc6"
        XCTAssertTrue(LiveState.redactPii("Notify active \(service)").contains("8d6d"))
        XCTAssertEqual(
            LiveState.redactPii("payload=zzzzzzzzzzzzzzzzzz"),
            "payload=zzzzzzzzzzzzzzzzzz"
        )
    }

    func testRawCaptureExportAndLegacyPersistedTailAreRedacted() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-redaction-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let capture = "[{\"hex\":\"\(payloadWithSerial)\"}]"
        try Data(capture.utf8).write(to: temporary)

        let safeData = try FileExport.sanitizedCaptureData(at: temporary)
        let safeText = try XCTUnwrap(String(data: safeData, encoding: .utf8))
        XCTAssertFalse(safeText.contains(serialAsHex))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: safeData))

        let defaults = UserDefaults.standard
        let key = "strapLog.tail"
        let prior = defaults.object(forKey: key)
        defer {
            if let prior { defaults.set(prior, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        defaults.set(["payload=\(payloadWithSerial)"], forKey: key)
        XCTAssertFalse(LiveState.persistedLogTail().joined().contains(serialAsHex))
        XCTAssertFalse(LiveState.scheduledExportText().contains(serialAsHex))
    }
}
