import XCTest
@testable import WhoopProtocol

final class HistoricalIngestionPerformanceTests: XCTestCase {
    private func bytes(_ hex: String) -> [UInt8] {
        var result: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            result.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return result
    }

    private func v20(unix: UInt32) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: Whoop5RawOptical.bufferLength)
        frame[0] = 0xAA; frame[1] = 0x01
        let declared = frame.count - 8
        frame[2] = UInt8(declared & 0xFF); frame[3] = UInt8((declared >> 8) & 0xFF)
        frame[4] = 0x01; frame[5] = 0x00; frame[8] = 0x2F; frame[9] = 20; frame[10] = 0x80
        frame[15] = UInt8(unix & 0xFF); frame[16] = UInt8((unix >> 8) & 0xFF)
        frame[17] = UInt8((unix >> 16) & 0xFF); frame[18] = UInt8((unix >> 24) & 0xFF)
        for block in 0..<Whoop5RawOptical.blockCount {
            frame[Whoop5RawOptical.blockStart + block * Whoop5RawOptical.blockLength] = block == 1 ? 0 : 25
        }
        let headerCRC = crc16Modbus(Array(frame[0..<6]))
        frame[6] = UInt8(headerCRC & 0xFF); frame[7] = UInt8((headerCRC >> 8) & 0xFF)
        let payloadEnd = frame.count - 4
        let payloadCRC = crc32(Array(frame[8..<payloadEnd]))
        frame[payloadEnd] = UInt8(payloadCRC & 0xFF)
        frame[payloadEnd + 1] = UInt8((payloadCRC >> 8) & 0xFF)
        frame[payloadEnd + 2] = UInt8((payloadCRC >> 16) & 0xFF)
        frame[payloadEnd + 3] = UInt8((payloadCRC >> 24) & 0xFF)
        return frame
    }

    func testMixedWhoop5ChunkReportsP50P95AndMax() {
        let v18 = bytes("aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f10b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e0000009d61a7c00000003e862817")
        let v21 = Whoop5RawImuTests.realFrameBytes
        var frames: [[UInt8]] = []
        for index in 0..<35 {
            switch index % 3 {
            case 0: frames.append(v18)
            case 1: frames.append(v20(unix: 1_781_557_000 + UInt32(index)))
            default: frames.append(v21)
            }
        }

        var milliseconds: [Double] = []
        for _ in 0..<30 {
            let start = DispatchTime.now().uptimeNanoseconds
            let parsed = frames.map { parseFrame($0, family: .whoop5) }
            _ = extractHistoricalStreams(
                parsed,
                deviceClockRef: 1_781_557_000,
                wallClockRef: 1_781_557_000)
            _ = zip(parsed, frames).map {
                historicalRecordDisposition(parsed: $0.0, rawFrame: $0.1, family: .whoop5)
            }
            let end = DispatchTime.now().uptimeNanoseconds
            milliseconds.append(Double(end - start) / 1_000_000)
        }

        let sorted = milliseconds.sorted()
        let p50 = sorted[Int(Double(sorted.count - 1) * 0.50)]
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let max = sorted.last!
        print(String(format: "HISTORY_INGEST_PERF frames=35 p50_ms=%.3f p95_ms=%.3f max_ms=%.3f", p50, p95, max))
        XCTAssertLessThan(p95, 250, "35 mixed V18/V20/V21 frames should remain bounded in Debug tests")
    }
}
