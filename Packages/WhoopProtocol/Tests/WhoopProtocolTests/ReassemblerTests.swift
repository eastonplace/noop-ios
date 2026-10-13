import XCTest
@testable import WhoopProtocol

final class ReassemblerTests: XCTestCase {
    // Build a real ~1928-byte type-43 frame from a 1917-byte synthetic payload so the
    // test is self-contained (no capture dependency): inner = 1917+3, length = 1924,
    // total = 1928. Reassembly must reproduce it exactly from 244-byte fragments.
    private func bigFrame() -> [UInt8] {
        let payload = (0..<1917).map { UInt8($0 & 0xFF) }
        return frameFromPayload(payload, type: 43, seq: 7, cmd: 0)
    }

    func testReassembleFromFragments() {
        let frame = bigFrame()
        XCTAssertEqual(frame.count, 1928)
        var fragments: [[UInt8]] = []
        var i = 0
        while i < frame.count {
            fragments.append(Array(frame[i..<min(i + 244, frame.count)]))
            i += 244
        }
        XCTAssertEqual(fragments.count, 8)
        // Only the first fragment carries the 0xAA SOF.
        XCTAssertEqual(fragments[0].first, 0xAA)
        for f in fragments.dropFirst() {
            XCTAssertNotEqual(f.first, 0xAA)
        }
        let r = Reassembler()
        var assembled: [[UInt8]] = []
        for f in fragments {
            assembled.append(contentsOf: r.feed(f))
        }
        XCTAssertEqual(assembled.count, 1)
        XCTAssertEqual(assembled[0], frame)
    }

    func testTwoFramesInOneFeed() {
        let a = frameFromPayload([0x01, 0x02], type: 40)
        let b = frameFromPayload([0x03, 0x04], type: 48)
        let r = Reassembler()
        let out = r.feed(a + b)
        XCTAssertEqual(out, [a, b])
    }

    func testReassembleFromOneBytePerFragment() {
        // Two back-to-back frames, fed a single byte per fragment. This is the worst case for the old
        // removeFirst drain and exercises the offset/compact window hard: head advances byte by byte,
        // compact() slides the tail every feed(). Output must still be the two exact frames, in order.
        let a = frameFromPayload([0x01, 0x02], type: 40)
        let b = frameFromPayload([0x03, 0x04], type: 48)
        let r = Reassembler()
        var out: [[UInt8]] = []
        for byte in a + b {
            out.append(contentsOf: r.feed([byte]))
        }
        XCTAssertEqual(out, [a, b])
    }

    func testLeadingGarbageIsSkipped() {
        let a = frameFromPayload([0x09], type: 40)
        let r = Reassembler()
        let out = r.feed([0x11, 0x22, 0x33] + a)
        XCTAssertEqual(out, [a])
    }

    func testPartialFrameWaitsForRest() {
        let a = frameFromPayload([0x01, 0x02, 0x03, 0x04], type: 40)
        let r = Reassembler()
        XCTAssertTrue(r.feed(Array(a[0..<5])).isEmpty)        // header + part
        XCTAssertEqual(r.feed(Array(a[5..<a.count])), [a])    // remainder completes it
    }

    func testOversizedDeclaredLengthResyncsInsteadOfWedging() {
        // A corrupt/misaligned 0xAA declaring an impossibly large length (a bit-flip or a spurious
        // mid-frame SOF) must be dropped so the stream resyncs to the next real frame. Without the
        // ceiling, feed() would wait forever for bytes that can never arrive and the live stream
        // would freeze until a reconnect. (Reimplemented from @vulnix0x4's PR #374.)
        let valid = frameFromPayload([0x09], type: 40)
        let r = Reassembler()
        // Spurious SOF with a 0xFFFF length (total 65539, far past the 8 KB ceiling), then a real
        // frame. T5: the spurious header carries a VALID crc8 (as a stray 0xAA does ~1 in 256 times), so
        // it passes the BLE-1 header check and only the maxFrameBytes cap can reject it.
        let length: [UInt8] = [0xFF, 0xFF]
        let spurious: [UInt8] = [0xAA] + length + [crc8(length)]
        XCTAssertEqual(crc8(spurious, 1, 3), spurious[3], "fixture must pass the header check")
        let out = r.feed(spurious + valid)
        XCTAssertEqual(out, [valid], "a garbage oversized SOF must not wedge the stream")
    }

    /// T5: the WHOOP 5/MG twin: a header with a valid CRC16 declaring 0xFFFF bytes must hit the cap.
    func testWhoop5OversizedDeclaredLengthWithValidHeaderCRCResyncs() {
        let valid = puffinCommandFrame(cmd: 0x03, seq: 7, payload: [0x01])
        let r = Reassembler(family: .whoop5)
        var spurious: [UInt8] = [0xAA, 0x01, 0xFF, 0xFF, 0x00, 0x01]
        let headerCRC = crc16Modbus(spurious)
        spurious += [UInt8(headerCRC & 0xFF), UInt8(headerCRC >> 8)]
        let out = r.feed(spurious + valid)
        XCTAssertEqual(out, [valid], "a valid-CRC oversized WHOOP 5 header must not wedge the stream")
    }
}
