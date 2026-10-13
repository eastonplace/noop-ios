import XCTest
import WhoopProtocol

/// BLE-1: the reassembler trusts a declared length only after the header checksum that protects it
/// verifies, and each notify characteristic gets its own reassembly window.
final class ReassemblerHeaderCRCTests: XCTestCase {

    /// A stray 0xAA whose following bytes declare a small, plausible length (well under the 8 KB cap) used
    /// to swallow the next real frame into a garbage "frame" of that length. Its crc8 at [3] does not
    /// match, so the reassembler now skips it and emits the real frame.
    func testWhoop4SpuriousSOFWithPlausibleLengthDoesNotSwallowNextFrame() {
        let valid = frameFromPayload([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08], type: 40, seq: 3)
        let lenLow: UInt8 = 0x10   // declares a 20-byte frame
        let badCRC = crc8([lenLow, 0x00]) ^ 0xFF
        let r = Reassembler()
        XCTAssertEqual(r.feed([0xAA, lenLow, 0x00, badCRC] + valid), [valid])
    }

    /// Same hardening for WHOOP 5/MG, whose length is protected by CRC16-Modbus at [6..8].
    func testWhoop5SpuriousSOFWithBadHeaderCRCIsSkipped() {
        let valid = puffinCommandFrame(cmd: 3, seq: 7, payload: [0x01])
        // fmt 0x01, declLen 8 (a 16-byte frame), two header bytes, then a deliberately wrong CRC16.
        var junk: [UInt8] = [0xAA, 0x01, 0x08, 0x00, 0x00, 0x01]
        let good = crc16Modbus(junk)
        junk += [UInt8(good & 0xFF) ^ 0xFF, UInt8(good >> 8)]
        let r = Reassembler(family: .whoop5)
        XCTAssertEqual(r.feed(junk + valid), [valid])
    }

    /// A header split across notifications still waits for the checksum bytes instead of rejecting early.
    func testHeaderSplitBeforeChecksumStillAssembles() {
        let w4 = frameFromPayload([0x09, 0x0A], type: 48)
        let r4 = Reassembler()
        XCTAssertTrue(r4.feed(Array(w4[0..<3])).isEmpty)
        XCTAssertEqual(r4.feed(Array(w4[3...])), [w4])

        let w5 = puffinCommandFrame(cmd: 3, seq: 1, payload: [0x00])
        let r5 = Reassembler(family: .whoop5)
        XCTAssertTrue(r5.feed(Array(w5[0..<7])).isEmpty)
        XCTAssertEqual(r5.feed(Array(w5[7...])), [w5])
    }

    /// A command response delivered on its own characteristic between two fragments of a data frame. One
    /// shared window splices the two together; per-characteristic windows keep both frames intact.
    func testCommandFrameInterleavedBetweenDataFragments() {
        let data = frameFromPayload((0..<40).map { UInt8($0) }, type: 47, seq: 1)
        let command = frameFromPayload([0x01], type: 36, seq: 2, cmd: 26)
        let firstHalf = Array(data[0..<20]), secondHalf = Array(data[20...])

        let shared = Reassembler()
        var sharedOut = shared.feed(firstHalf)
        sharedOut += shared.feed(command)
        sharedOut += shared.feed(secondHalf)
        XCTAssertFalse(sharedOut.contains(data), "one shared window corrupts the interleaved data frame")

        let perCharacteristic = ReassemblerSet<String>()
        var out = perCharacteristic.feed(firstHalf, from: "data")
        out += perCharacteristic.feed(command, from: "cmd")
        out += perCharacteristic.feed(secondHalf, from: "data")
        XCTAssertEqual(out, [command, data])
    }

    /// Reset drops every partial window, so bytes from an old link can never prefix a new link's frame.
    func testResetDropsPartialFramesAndSwitchesFamily() {
        let data = frameFromPayload((0..<40).map { UInt8($0) }, type: 47, seq: 1)
        let set = ReassemblerSet<String>()
        XCTAssertTrue(set.feed(Array(data[0..<20]), from: "data").isEmpty)
        set.reset()
        XCTAssertTrue(set.feed(Array(data[20...]), from: "data").isEmpty,
                      "the tail of a frame from before the reset must not complete anything")
        XCTAssertEqual(set.feed(data, from: "data"), [data])

        set.reset(family: .whoop5)
        XCTAssertEqual(set.family, .whoop5)
        let w5 = puffinCommandFrame(cmd: 3, seq: 7, payload: [0x01])
        XCTAssertEqual(set.feed(w5, from: "fd4b0003"), [w5])
    }
}
