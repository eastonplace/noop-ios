import XCTest
@testable import WhoopProtocol

final class Whoop5RawOpticalTests: XCTestCase {
    func testStrictFiveBlockShapeAndSharedCounts() throws {
        var frame = [UInt8](repeating: 0, count: Whoop5RawOptical.bufferLength)
        frame[0] = 0xAA; frame[8] = 0x2F; frame[9] = 20
        frame[Whoop5RawOptical.blockStart] = 25
        let decoded = try XCTUnwrap(Whoop5RawOptical.decode(frame))
        XCTAssertEqual(decoded.blocks.count, 5)
        XCTAssertEqual(decoded.blocks.map(\.sampleCount), [25, 0, 0, 0, 0])
        XCTAssertEqual(decoded.blocks[0].channels.map { $0.samples.count }, [25, 25])
        XCTAssertTrue(decoded.blocks.allSatisfy { $0.rawHeader.count == 21 })

        frame[Whoop5RawOptical.blockStart] = 51
        XCTAssertNil(Whoop5RawOptical.decode(frame))
        frame.removeLast()
        XCTAssertNil(Whoop5RawOptical.decode(frame))
    }
}
