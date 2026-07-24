import XCTest
@testable import WhoopProtocol

final class Whoop5ExperimentalSpO2PipelineTests: XCTestCase {
    /// Real WHOOP 5/MG type-47 v18 fixture. The test changes only the sleep-state and byte-82 payload
    /// bytes, then re-stamps the payload CRC so the production extractor's CRC gate remains active.
    private let historicalHex =
        "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817"

    private func bytes(_ string: String) -> [UInt8] {
        var output: [UInt8] = []
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            output.append(UInt8(string[index..<next], radix: 16)!)
            index = next
        }
        return output
    }

    private func crcValidFrame(sleepStateByte: UInt8, candidateByte: UInt8) -> [UInt8] {
        var frame = bytes(historicalHex)
        frame[81] = sleepStateByte
        frame[82] = candidateByte
        let declaredLength = Int(frame[2]) | (Int(frame[3]) << 8)
        let total = declaredLength + 8
        let payloadEnd = total - 4
        let checksum = crc32(frame, 8, payloadEnd)
        frame[payloadEnd] = UInt8(checksum & 0xff)
        frame[payloadEnd + 1] = UInt8((checksum >> 8) & 0xff)
        frame[payloadEnd + 2] = UInt8((checksum >> 16) & 0xff)
        frame[payloadEnd + 3] = UInt8((checksum >> 24) & 0xff)
        return frame
    }

    private func parsedCandidate(_ value: UInt8, sleepStateByte: UInt8 = 0x20) -> ParsedFrame {
        parseFrame(
            crcValidFrame(sleepStateByte: sleepStateByte, candidateByte: value),
            family: .whoop5
        )
    }

    func testSleepingInBandCandidateReachesCompactSpO2Stream() {
        let frame = parsedCandidate(96)
        XCTAssertEqual(frame.crcOK, true)
        XCTAssertEqual(frame.parsed["sleep_state"]?.intValue, 2)
        XCTAssertEqual(frame.parsed["aux_byte_82"]?.intValue, 96)

        let streams = extractHistoricalStreams(
            [frame],
            deviceClockRef: 1_780_916_150,
            wallClockRef: 1_780_916_150
        )

        XCTAssertEqual(streams.spo2, [
            SpO2Sample(
                ts: 1_780_916_100,
                red: 96,
                ir: Whoop5V18SpO2Candidate.persistedMarkerIR,
                unit: "experimental_pct"
            ),
        ])
    }

    func testSameMinuteCandidatesProduceOneOrderIndependentMean() {
        let values: [UInt8] = [70, 100, 90]
        let forward = extractHistoricalStreams(
            values.map { parsedCandidate($0) },
            deviceClockRef: 1_780_916_150,
            wallClockRef: 1_780_916_150
        ).spo2
        let reverse = extractHistoricalStreams(
            values.reversed().map { parsedCandidate($0) },
            deviceClockRef: 1_780_916_150,
            wallClockRef: 1_780_916_150
        ).spo2

        let expected = [
            SpO2Sample(
                ts: 1_780_916_100,
                red: 87,
                ir: Whoop5V18SpO2Candidate.persistedMarkerIR,
                unit: "experimental_pct"
            ),
        ]
        XCTAssertEqual(forward, expected)
        XCTAssertEqual(reverse, expected)
    }

    func testAwakeOrSentinelValuesNeverReachExperimentalStream() {
        let awake = parsedCandidate(96, sleepStateByte: 0x00)
        let sentinel = parsedCandidate(0x80)

        XCTAssertTrue(extractHistoricalStreams(
            [awake],
            deviceClockRef: 1_780_916_150,
            wallClockRef: 1_780_916_150
        ).spo2.isEmpty)
        XCTAssertTrue(extractHistoricalStreams(
            [sentinel],
            deviceClockRef: 1_780_916_150,
            wallClockRef: 1_780_916_150
        ).spo2.isEmpty)
    }
}
