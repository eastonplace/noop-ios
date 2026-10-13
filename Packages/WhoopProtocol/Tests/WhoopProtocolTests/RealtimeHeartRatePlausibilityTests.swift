import XCTest
import WhoopProtocol

/// AN-03 (ingest half): realtime heart-rate samples outside 30...240 bpm are never persisted. The strap
/// reports 0 while off-wrist, and a corrupt byte can read up to 255; both used to land in the HR stream
/// through REALTIME_DATA (live WHOOP 4) and REALTIME_RAW_DATA (history), unlike the type-47 path.
final class RealtimeHeartRatePlausibilityTests: XCTestCase {

    private func hexBytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
    }

    /// The synthetic REALTIME_DATA fixture from StreamsTests (ts=31538447, hr=60) with its heart-rate byte
    /// (frame offset 12) and timestamp replaced, then re-checksummed so it stays a valid envelope.
    private func realtimeFrame(bpm: UInt8, deviceTs: UInt32) -> [UInt8] {
        var f = hexBytes("aa1800ff28020f3de10100003c0000000000000000000000b7e67942")
        f.replaceSubrange(6..<10, with: le32(deviceTs))
        f[12] = bpm
        let length = Int(f[1]) | (Int(f[2]) << 8)
        f.replaceSubrange(length..<(length + 4), with: le32(crc32(f, 4, length)))
        return f
    }

    /// A REALTIME_RAW_DATA IMU record (1917-byte payload variant: hr at frame offset 21).
    private func rawFrame(bpm: UInt8, deviceTs: UInt32) -> [UInt8] {
        var payload = [UInt8](repeating: 0, count: 1917)
        payload.replaceSubrange(4..<8, with: le32(deviceTs))   // frame offset 11
        payload[14] = bpm                                        // frame offset 21
        return frameFromPayload(payload, type: 43, seq: 1, cmd: 0)
    }

    func testRangeConstant() {
        XCTAssertEqual(HeartRatePlausibility.ingestRange, 30...240)
        XCTAssertFalse(HeartRatePlausibility.isPlausible(0))
        XCTAssertFalse(HeartRatePlausibility.isPlausible(29))
        XCTAssertTrue(HeartRatePlausibility.isPlausible(30))
        XCTAssertTrue(HeartRatePlausibility.isPlausible(240))
        XCTAssertFalse(HeartRatePlausibility.isPlausible(241))
        XCTAssertFalse(HeartRatePlausibility.isPlausible(255))
    }

    func testRealtimeDataDropsOffWristZeroAndCorrupt255() {
        let frames = [realtimeFrame(bpm: 0, deviceTs: 100),
                      realtimeFrame(bpm: 255, deviceTs: 101),
                      realtimeFrame(bpm: 61, deviceTs: 102)]
        let parsed = frames.map { parseFrame($0) }
        XCTAssertTrue(parsed.allSatisfy { $0.ok && $0.typeName == "REALTIME_DATA" })
        let s = extractStreams(parsed, deviceClockRef: 100, wallClockRef: 1_736_365_593)
        XCTAssertEqual(s.hr, [HRSample(ts: 1_736_365_595, bpm: 61)])
    }

    func testRealtimeRawDataDropsOffWristZeroAndCorrupt255() {
        let wall = Int(Date().timeIntervalSince1970) - 3_600
        let frames = [rawFrame(bpm: 0, deviceTs: 5_000),
                      rawFrame(bpm: 255, deviceTs: 5_001),
                      rawFrame(bpm: 62, deviceTs: 5_002)]
        let parsed = frames.map { parseFrame($0) }
        XCTAssertTrue(parsed.allSatisfy { $0.ok && $0.typeName == "REALTIME_RAW_DATA" })
        XCTAssertEqual(parsed.compactMap { $0.parsed["heart_rate"]?.intValue }, [0, 255, 62],
                       "the decoder still reports the raw byte; only ingest filters it")
        let s = extractHistoricalStreams(parsed, deviceClockRef: 5_000, wallClockRef: wall)
        XCTAssertEqual(s.hr, [HRSample(ts: wall + 2, bpm: 62)])
    }
}
