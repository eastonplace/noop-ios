import XCTest
@testable import WhoopProtocol

/// BLE-2: `Backfiller.ingest` used to run a full `parseFrame` on every history frame just to learn it was
/// not METADATA, and the chunk decode then parsed every record again. The pre-filter parses only frames
/// whose type byte says METADATA, and must classify exactly like the full parse.
final class HistoricalMetaPrefilterTests: XCTestCase {

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    private func whoop4Meta(cmd: UInt8, payload: [UInt8] = []) -> [UInt8] {
        var frame = frameFromPayload(payload, type: 49, seq: 0, cmd: cmd)
        frame[3] = crc8(frame, 1, 3)
        return frame
    }

    private func whoop4Record(_ i: Int) -> [UInt8] {
        var frame = frameFromPayload([UInt8](repeating: UInt8(i & 0xFF), count: 40), type: 47, seq: 0, cmd: 24)
        frame[3] = crc8(frame, 1, 3)
        return frame
    }

    private func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    /// A 2,000-frame offload with 3 METADATA frames parses exactly 3 frames in the classification step.
    func testOnlyMetadataFramesAreParsed() {
        var frames = (0..<1_997).map(whoop4Record)
        frames.insert(whoop4Meta(cmd: 1), at: 0)
        frames.insert(whoop4Meta(cmd: 2, payload: le32(1_700_000_000) + [0xE8, 0x03] + le32(0) + le32(42)),
                      at: 1_000)
        frames.append(whoop4Meta(cmd: 3))
        var parses = 0
        let counting: ([UInt8], DeviceFamily) -> ParsedFrame = { frame, family in
            parses += 1
            return parseFrame(frame, family: family)
        }
        var results: [HistoricalMeta] = []
        for frame in frames {
            let meta = classifyHistoricalMeta(frame: frame, family: .whoop4, parse: counting)
            if meta != .other { results.append(meta) }
        }
        XCTAssertEqual(parses, 3)
        XCTAssertEqual(results, [.start, .end(unix: 1_700_000_000, trim: 42), .complete])
    }

    /// The pre-filter is byte-identical to classifying the full parse, for both families and for
    /// truncated / non-AA input.
    func testPrefilterMatchesFullParseClassification() {
        let whoop4: [[UInt8]] = [
            whoop4Meta(cmd: 1), whoop4Meta(cmd: 3), whoop4Meta(cmd: 9),
            whoop4Meta(cmd: 2, payload: le32(1_700_000_123) + [0, 0] + le32(7) + le32(99)),
            whoop4Meta(cmd: 2, payload: [1, 2, 3]),
            whoop4Record(5), [0xAA, 0x01, 0x00], [0x00, 0x01, 0x02, 0x03, 49, 0, 1, 0],
        ]
        for frame in whoop4 {
            XCTAssertEqual(classifyHistoricalMeta(frame: frame, family: .whoop4),
                           classifyHistoricalMeta(parseFrame(frame, family: .whoop4)), "\(frame)")
        }
        let whoop5 = [
            bytes("aa011c00010023d1316a0284a3266a0a373d00000041b601001000000000000044d21e3d"),
            bytes("aa012c0001002cd1312c0184a3266ad7230d0000005200000000000000320000002600000001000000000000000b010034497926"),
        ]
        for frame in whoop5 {
            let full = classifyHistoricalMeta(parseFrame(frame, family: .whoop5))
            XCTAssertNotEqual(full, .other)
            XCTAssertEqual(classifyHistoricalMeta(frame: frame, family: .whoop5), full)
        }
    }

    /// Resolved layouts come from the load-time table and equal the on-demand ref-chain resolution.
    func testPreResolvedVersionsMatchOnDemandResolution() throws {
        let schema = loadSchema()
        let spec = try XCTUnwrap(schema.packets.values.first { $0.versions.count > 1 })
        for key in spec.versions.keys {
            let version = try XCTUnwrap(Int(key))
            let cached = schema.resolvedVersion(packet: spec, version)
            let onDemand = schema.resolveVersion(spec.versions, version)
            XCTAssertEqual(cached?.fields.count, onDemand?.fields.count, "v\(version)")
            XCTAssertEqual(cached?.kind, onDemand?.kind, "v\(version)")
            XCTAssertEqual(cached?.rrFirstOff, onDemand?.rrFirstOff, "v\(version)")
        }
        XCTAssertNil(schema.resolvedVersion(packet: spec, 9_999))
    }
}
