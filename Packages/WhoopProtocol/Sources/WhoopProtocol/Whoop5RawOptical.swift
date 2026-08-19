import Foundation

/// Neutral, evidence-backed interpretation of the eleven fields in one WHOOP 5/MG
/// layout-v20 optical block header. Names describe wire behavior only. They do not
/// claim wavelength, biological meaning, register identity, or physical units.
public struct Whoop5OpticalBlockConfig: Equatable, Codable, Sendable {
    public let sampleCount: Int
    public let sourceA: UInt8
    public let driveA: UInt16
    public let sourceB: UInt8
    public let driveB: UInt16
    public let detectorASelect: UInt8
    public let rangeA: UInt32
    public let offsetA: Int16
    public let detectorBSelect: UInt8
    public let rangeB: UInt32
    public let offsetB: Int16

    public init(
        sampleCount: Int,
        sourceA: UInt8,
        driveA: UInt16,
        sourceB: UInt8,
        driveB: UInt16,
        detectorASelect: UInt8,
        rangeA: UInt32,
        offsetA: Int16,
        detectorBSelect: UInt8,
        rangeB: UInt32,
        offsetB: Int16
    ) {
        self.sampleCount = sampleCount
        self.sourceA = sourceA
        self.driveA = driveA
        self.sourceB = sourceB
        self.driveB = driveB
        self.detectorASelect = detectorASelect
        self.rangeA = rangeA
        self.offsetA = offsetA
        self.detectorBSelect = detectorBSelect
        self.rangeB = rangeB
        self.offsetB = offsetB
    }

    fileprivate static func decode(_ header: [UInt8]) -> Self? {
        guard header.count == Whoop5RawOptical.headerLength else { return nil }
        return Self(
            sampleCount: Int(header[0]),
            sourceA: header[1],
            driveA: u16(header, 2),
            sourceB: header[4],
            driveB: u16(header, 5),
            detectorASelect: header[7],
            rangeA: u32(header, 8),
            offsetA: i16(header, 12),
            detectorBSelect: header[14],
            rangeB: u32(header, 15),
            offsetB: i16(header, 19)
        )
    }

    @inline(__always)
    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    @inline(__always)
    private static func i16(_ bytes: [UInt8], _ offset: Int) -> Int16 {
        Int16(bitPattern: u16(bytes, offset))
    }

    @inline(__always)
    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }
}

public struct RawOpticalChannel: Equatable, Codable, Sendable {
    /// Seven raw per-channel header bytes. The block config is the named view.
    public let metadata: [UInt8]
    /// Signed 20-bit ADC readings already sign-extended into i32 containers.
    public let samples: [Int32]

    public init(metadata: [UInt8], samples: [Int32]) {
        self.metadata = metadata
        self.samples = samples
    }
}

public struct Whoop5OpticalBlock: Equatable, Codable, Sendable {
    public let index: Int
    public let sampleCount: Int
    public let sharedMetadata: [UInt8]
    public let channels: [RawOpticalChannel]
    public let reserved: UInt8
    public let config: Whoop5OpticalBlockConfig

    /// Compatibility initializer retained for existing callers. The config is derived
    /// from the exact 21-byte header supplied by the existing fields.
    public init(
        index: Int,
        sampleCount: Int,
        sharedMetadata: [UInt8],
        channels: [RawOpticalChannel],
        reserved: UInt8
    ) {
        let header = [UInt8(clamping: sampleCount)]
            + sharedMetadata
            + channels.flatMap(\.metadata)
        self.init(
            index: index,
            sampleCount: sampleCount,
            sharedMetadata: sharedMetadata,
            channels: channels,
            reserved: reserved,
            config: Whoop5OpticalBlockConfig.decode(header)
                ?? Whoop5OpticalBlockConfig(
                    sampleCount: sampleCount,
                    sourceA: 0,
                    driveA: 0,
                    sourceB: 0,
                    driveB: 0,
                    detectorASelect: 0,
                    rangeA: 0,
                    offsetA: 0,
                    detectorBSelect: 0,
                    rangeB: 0,
                    offsetB: 0
                )
        )
    }

    public init(
        index: Int,
        sampleCount: Int,
        sharedMetadata: [UInt8],
        channels: [RawOpticalChannel],
        reserved: UInt8,
        config: Whoop5OpticalBlockConfig
    ) {
        self.index = index
        self.sampleCount = sampleCount
        self.sharedMetadata = sharedMetadata
        self.channels = channels
        self.reserved = reserved
        self.config = config
    }

    public var rawHeader: [UInt8] {
        [UInt8(clamping: sampleCount)] + sharedMetadata + channels.flatMap(\.metadata)
    }

    public var readingsA: [Int32] { channels.first?.samples ?? [] }
    public var readingsB: [Int32] { channels.count > 1 ? channels[1].samples : [] }
}

public struct Whoop5OpticalFrame: Equatable, Codable, Sendable {
    public let recordIndex: Int
    public let baseTs: Int
    public let blocks: [Whoop5OpticalBlock]
    public let layoutVersion: UInt8
    public let checksum: UInt32

    public init(
        recordIndex: Int,
        baseTs: Int,
        blocks: [Whoop5OpticalBlock],
        layoutVersion: UInt8 = Whoop5RawOptical.layoutVersion,
        checksum: UInt32 = 0
    ) {
        self.recordIndex = recordIndex
        self.baseTs = baseTs
        self.blocks = blocks
        self.layoutVersion = layoutVersion
        self.checksum = checksum
    }
}

public enum Whoop5RawOptical {
    public static let bufferLength = 2_140
    public static let blockCount = 5
    public static let blockStart = 26
    public static let blockLength = 422
    public static let headerLength = 21
    public static let channelSlotLength = 200
    public static let channelCapacity = 50
    public static let layoutVersion: UInt8 = 20
    public static let recordClass: UInt8 = 0x2F
    public static let checksumOffset = 2_136

    public static let sampleMax: Int32 = 524_287
    public static let sampleMin: Int32 = -524_288

    /// Decode a complete v20 frame only after the standard WHOOP 5 envelope,
    /// header CRC16, payload CRC32, class, and layout version all verify.
    public static func decode(_ frame: [UInt8]) -> Whoop5OpticalFrame? {
        guard frame.count == bufferLength,
              frame[0] == 0xAA,
              verifyFrame(frame, family: .whoop5).ok,
              frame[8] == recordClass,
              frame[9] == layoutVersion
        else { return nil }

        var blocks: [Whoop5OpticalBlock] = []
        blocks.reserveCapacity(blockCount)

        for index in 0..<blockCount {
            let start = blockStart + index * blockLength
            let header = Array(frame[start..<(start + headerLength)])
            guard let config = Whoop5OpticalBlockConfig.decode(header),
                  config.sampleCount <= channelCapacity
            else { return nil }

            let sharedMetadata = Array(header[1..<7])
            var channels: [RawOpticalChannel] = []
            channels.reserveCapacity(2)

            for channelIndex in 0..<2 {
                let metadataStart = 7 + channelIndex * 7
                let metadata = Array(header[metadataStart..<(metadataStart + 7)])
                let sampleStart = start + headerLength + channelIndex * channelSlotLength
                var samples: [Int32] = []
                samples.reserveCapacity(config.sampleCount)

                for sampleIndex in 0..<config.sampleCount {
                    let value = i32(frame, sampleStart + sampleIndex * 4)
                    guard value >= sampleMin, value <= sampleMax else { return nil }
                    samples.append(value)
                }
                channels.append(RawOpticalChannel(metadata: metadata, samples: samples))
            }

            blocks.append(
                Whoop5OpticalBlock(
                    index: index,
                    sampleCount: config.sampleCount,
                    sharedMetadata: sharedMetadata,
                    channels: channels,
                    reserved: frame[start + blockLength - 1],
                    config: config
                )
            )
        }

        return Whoop5OpticalFrame(
            recordIndex: Int(u32(frame, 11)),
            baseTs: Int(u32(frame, 15)),
            blocks: blocks,
            layoutVersion: frame[9],
            checksum: u32(frame, checksumOffset)
        )
    }

    @inline(__always)
    private static func u32(_ frame: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(frame[offset]) | (UInt32(frame[offset + 1]) << 8)
            | (UInt32(frame[offset + 2]) << 16) | (UInt32(frame[offset + 3]) << 24)
    }

    @inline(__always)
    private static func i32(_ frame: [UInt8], _ offset: Int) -> Int32 {
        Int32(bitPattern: u32(frame, offset))
    }
}
