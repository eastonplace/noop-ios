import XCTest
@testable import NOOP

/// Upgrade 231 (b230 finding 1): the reject-archive replay gate moved from the app version to the decoder
/// schema. A 229 install stamped "9.0.1" under the old key, and its decoder is schema 1, so it doesn't replay
/// again (a replay files the archived records under the current strap's id). A fresh install and a decoder
/// bump still replay.
final class BLERejectArchiveReplayGateTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "BLERejectArchiveReplayGateTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testA229InstallDoesNotReplayAndCarriesTheGateForward() {
        defaults.set("9.0.1", forKey: BLEManager.legacyRejectArchiveReplayKey)
        XCTAssertFalse(BLEManager.rejectArchiveReplayIsDue(defaults: defaults, decoderSchema: 1))
        XCTAssertEqual(defaults.string(forKey: BLEManager.rejectArchiveReplayKey), "decoder-1")
        XCTAssertFalse(BLEManager.rejectArchiveReplayIsDue(defaults: defaults, decoderSchema: 1))
    }

    func testAFreshInstallReplays() {
        XCTAssertTrue(BLEManager.rejectArchiveReplayIsDue(defaults: defaults, decoderSchema: 1))
        XCTAssertNil(defaults.string(forKey: BLEManager.rejectArchiveReplayKey),
                     "the stamp is written only after a successful replay")
    }

    func testADecoderBumpReplaysAfter229AndAfterItsOwnStamp() {
        defaults.set("9.0.1", forKey: BLEManager.legacyRejectArchiveReplayKey)
        XCTAssertTrue(BLEManager.rejectArchiveReplayIsDue(defaults: defaults, decoderSchema: 2))
        defaults.set("decoder-1", forKey: BLEManager.rejectArchiveReplayKey)
        XCTAssertTrue(BLEManager.rejectArchiveReplayIsDue(defaults: defaults, decoderSchema: 2))
    }

    func testAnOlderAppVersionStampReplays() {
        defaults.set("9.0.0", forKey: BLEManager.legacyRejectArchiveReplayKey)
        XCTAssertTrue(BLEManager.rejectArchiveReplayIsDue(defaults: defaults, decoderSchema: 1))
    }
}
