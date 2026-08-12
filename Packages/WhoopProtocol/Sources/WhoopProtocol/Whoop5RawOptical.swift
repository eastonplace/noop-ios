import Foundation

/// Lossless structural decoder for WHOOP 5/MG historical layout v20.
///
/// The 2,140-byte record contains five repeated 422-byte blocks. Each block is a 21-byte shared
/// header, two 200-byte channel slots, and one reserved byte. The first header byte is the shared
/// sample count. Captured active blocks use 25 signed i32 samples per channel; the remaining slot
/// capacity is padding. Channel wavelength and biological meaning remain intentionally unspecified.
public struct RawOpticalChannel: Equatable, Codable, Sendable {
    public let metadata: [UInt8]
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

    public init(index: Int, sampleCount: Int, sharedMetadata: [UInt8],
                channels: [RawOpticalChannel], reserved: UInt8) {
        self.index = index
        self.sampleCount = sampleCount
        self.sharedMetadata = sharedMetadata
        self.channels = channels
        self.reserved = reserved
    }

    public var rawHeader: [UInt8] {
        [UInt8(sampleCount)] + sharedMetadata + channels.flatMap(\.metadata)
    }
}

public struct Whoop5OpticalFrame: Equatable, Codable, Sendable {
    public let recordIndex: Int
    public let baseTs: Int
    public let blocks: [Whoop5OpticalBlock]
}

public enum Whoop5RawOptical {
    public static let bufferLength = 2_140
    public static let blockCount = 5
    public static let blockStart = 26
    public static let blockLength = 422
    public static let headerLength = 21
    public static let channelSlotLength = 200
    public static let channelCapacity = 50

    public static func decode(_ frame: [UInt8]) -> Whoop5OpticalFrame? {
        guard frame.count == bufferLength,
              frame[0] == 0xAA,
              frame[8] == 0x2F,
              frame[9] == 20 else { return nil }

        var blocks: [Whoop5OpticalBlock] = []
        blocks.reserveCapacity(blockCount)
        for index in 0..<blockCount {
            let start = blockStart + index * blockLength
            let sampleCount = Int(frame[start])
            guard sampleCount <= channelCapacity else { return nil }
            let sharedMetadata = Array(frame[(start + 1)..<(start + 7)])
            var channels: [RawOpticalChannel] = []
            channels.reserveCapacity(2)
            for channelIndex in 0..<2 {
                let metadataStart = start + 7 + channelIndex * 7
                let metadata = Array(frame[metadataStart..<(metadataStart + 7)])
                let sampleStart = start + headerLength + channelIndex * channelSlotLength
                let samples = (0..<sampleCount).map { i32(frame, sampleStart + $0 * 4) }
                channels.append(RawOpticalChannel(metadata: metadata, samples: samples))
            }
            blocks.append(Whoop5OpticalBlock(
                index: index,
                sampleCount: sampleCount,
                sharedMetadata: sharedMetadata,
                channels: channels,
                reserved: frame[start + blockLength - 1]
            ))
        }
        return Whoop5OpticalFrame(
            recordIndex: Int(u32(frame, 11)),
            baseTs: Int(u32(frame, 15)),
            blocks: blocks
        )
    }

    @inline(__always) private static func u32(_ frame: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(frame[offset]) | (UInt32(frame[offset + 1]) << 8)
            | (UInt32(frame[offset + 2]) << 16) | (UInt32(frame[offset + 3]) << 24)
    }

    @inline(__always) private static func i32(_ frame: [UInt8], _ offset: Int) -> Int32 {
        Int32(bitPattern: u32(frame, offset))
    }
}
