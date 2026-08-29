import XCTest
@testable import WhoopProtocol

final class Whoop5RawOpticalTests: XCTestCase {
    func testIntegrityGatedConfigAndSignedSamples() throws {
        var frame = Self.sealedSyntheticFrame()
        let start = Whoop5RawOptical.blockStart

        frame[start] = 2
        frame[start + 1] = 1
        Self.putU16(1_400, in: &frame, at: start + 2)
        frame[start + 4] = 4
        Self.putU16(2_800, in: &frame, at: start + 5)
        frame[start + 7] = 3
        Self.putU32(32, in: &frame, at: start + 8)
        Self.putI16(-800, in: &frame, at: start + 12)
        frame[start + 14] = 4
        Self.putU32(16, in: &frame, at: start + 15)
        Self.putI16(2_400, in: &frame, at: start + 19)

        let firstSlot = start + Whoop5RawOptical.headerLength
        Self.putI32(-22_101, in: &frame, at: firstSlot)
        Self.putI32(Whoop5RawOptical.sampleMax, in: &frame, at: firstSlot + 4)

        let secondSlot = firstSlot + Whoop5RawOptical.channelSlotLength
        Self.putI32(100, in: &frame, at: secondSlot)
        Self.putI32(-100, in: &frame, at: secondSlot + 4)

        frame = Self.reseal(frame)
        let decoded = try XCTUnwrap(Whoop5RawOptical.decode(frame))
        let block = decoded.blocks[0]

        XCTAssertEqual(block.config.sampleCount, 2)
        XCTAssertEqual(block.config.sourceA, 1)
        XCTAssertEqual(block.config.driveA, 1_400)
        XCTAssertEqual(block.config.sourceB, 4)
        XCTAssertEqual(block.config.driveB, 2_800)
        XCTAssertEqual(block.config.detectorASelect, 3)
        XCTAssertEqual(block.config.rangeA, 32)
        XCTAssertEqual(block.config.offsetA, -800)
        XCTAssertEqual(block.config.detectorBSelect, 4)
        XCTAssertEqual(block.config.rangeB, 16)
        XCTAssertEqual(block.config.offsetB, 2_400)
        XCTAssertEqual(block.readingsA, [-22_101, 524_287])
        XCTAssertEqual(block.readingsB, [100, -100])
        XCTAssertEqual(block.rawHeader, Array(frame[start..<(start + 21)]))
        XCTAssertEqual(decoded.layoutVersion, 20)
        XCTAssertEqual(decoded.checksum, Self.u32(frame, Whoop5RawOptical.checksumOffset))
    }

    func testSingleBitPayloadCorruptionIsRejected() {
        let clean = Self.sealedSyntheticFrame()
        XCTAssertNotNil(Whoop5RawOptical.decode(clean))

        var corrupt = clean
        corrupt[Whoop5RawOptical.blockStart + 25] ^= 0x01
        XCTAssertNil(Whoop5RawOptical.decode(corrupt))
    }

    func testHeaderCorruptionIsRejected() {
        let clean = Self.sealedSyntheticFrame()
        var corrupt = clean
        corrupt[4] ^= 0x01
        XCTAssertNil(Whoop5RawOptical.decode(corrupt))
    }

    func testStrictShapeClassVersionAndCountGates() {
        let clean = Self.sealedSyntheticFrame()
        XCTAssertNotNil(Whoop5RawOptical.decode(clean))
        XCTAssertNil(Whoop5RawOptical.decode(clean + [0]))

        var wrongClass = clean
        wrongClass[8] = 0x2E
        XCTAssertNil(Whoop5RawOptical.decode(Self.reseal(wrongClass)))

        var wrongVersion = clean
        wrongVersion[9] = 21
        XCTAssertNil(Whoop5RawOptical.decode(Self.reseal(wrongVersion)))

        var tooMany = clean
        tooMany[Whoop5RawOptical.blockStart] = 51
        XCTAssertNil(Whoop5RawOptical.decode(Self.reseal(tooMany)))
    }

    func testOutOfSignedTwentyBitDomainIsRejected() {
        var frame = Self.sealedSyntheticFrame()
        let start = Whoop5RawOptical.blockStart
        frame[start] = 1
        Self.putI32(524_288, in: &frame, at: start + Whoop5RawOptical.headerLength)
        XCTAssertNil(Whoop5RawOptical.decode(Self.reseal(frame)))
    }

    func testCompatibilityInitializerFailsClosedOnMalformedHeader() {
        XCTAssertNil(Whoop5OpticalBlock(
            index: 0,
            sampleCount: 1,
            sharedMetadata: [],
            channels: [],
            reserved: 0
        ))
    }

    static func sealedSyntheticFrame() -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: Whoop5RawOptical.bufferLength)
        frame[0] = 0xAA
        frame[1] = 0x01
        frame[2] = 0x54
        frame[3] = 0x08
        frame[4] = 0x01
        frame[8] = Whoop5RawOptical.recordClass
        frame[9] = Whoop5RawOptical.layoutVersion
        return reseal(frame)
    }

    static func reseal(_ input: [UInt8]) -> [UInt8] {
        var frame = input
        guard frame.count >= Whoop5RawOptical.checksumOffset + 4 else { return frame }

        let header = crc16Modbus(frame, 0, 6)
        frame[6] = UInt8(header & 0xFF)
        frame[7] = UInt8((header >> 8) & 0xFF)

        let payload = crc32(frame, 8, Whoop5RawOptical.checksumOffset)
        putU32(payload, in: &frame, at: Whoop5RawOptical.checksumOffset)
        return frame
    }

    static func putU16(_ value: UInt16, in bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    static func putI16(_ value: Int16, in bytes: inout [UInt8], at offset: Int) {
        putU16(UInt16(bitPattern: value), in: &bytes, at: offset)
    }

    static func putU32(_ value: UInt32, in bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    static func putI32(_ value: Int32, in bytes: inout [UInt8], at offset: Int) {
        putU32(UInt32(bitPattern: value), in: &bytes, at: offset)
    }

    static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }
}
