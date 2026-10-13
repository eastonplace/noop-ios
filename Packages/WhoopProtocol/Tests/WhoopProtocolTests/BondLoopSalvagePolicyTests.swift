import XCTest
import WhoopProtocol

/// #78 hole-4: the bond-loop salvage probe may fire ONLY while the give-up pause is latched, with no live
/// link, no user teardown in force, and at least the 10-minute floor since the pause tripped (or since the
/// previous probe re-stamped it). Ported from the uncompiled StrandTests/BondLoopHardeningTests; the
/// CoreBluetooth error-classification half lives in StrandiOSTests/BLEBondLoopHardeningTests.
final class BondLoopSalvagePolicyTests: XCTestCase {

    // MARK: shouldSalvageProbe (hole 4)

    private let floor = BondLoopSalvagePolicy.floorSeconds

    /// The happy salvage path: paused, link down, no user teardown, past the floor.
    func testProbe_firesPastFloorWhilePaused() {
        XCTAssertTrue(BondLoopSalvagePolicy.shouldProbe(pausedForBondLoop: true, connected: false,
                                                    intentionalDisconnect: false,
                                                    secondsSincePauseTripped: floor))
        XCTAssertTrue(BondLoopSalvagePolicy.shouldProbe(pausedForBondLoop: true, connected: false,
                                                    intentionalDisconnect: false,
                                                    secondsSincePauseTripped: floor + 3600))
    }

    /// Below the floor no probe fires - back-to-back foregrounds can't chain attempts.
    func testProbe_respectsTheFloor() {
        XCTAssertFalse(BondLoopSalvagePolicy.shouldProbe(pausedForBondLoop: true, connected: false,
                                                     intentionalDisconnect: false,
                                                     secondsSincePauseTripped: floor - 1))
        XCTAssertFalse(BondLoopSalvagePolicy.shouldProbe(pausedForBondLoop: true, connected: false,
                                                     intentionalDisconnect: false,
                                                     secondsSincePauseTripped: 0))
    }

    /// No trip timestamp = the pause never tripped this run = never probe.
    func testProbe_needsATripTimestamp() {
        XCTAssertFalse(BondLoopSalvagePolicy.shouldProbe(pausedForBondLoop: true, connected: false,
                                                     intentionalDisconnect: false,
                                                     secondsSincePauseTripped: nil))
    }

    /// Not paused (the normal healthy path) never probes - the probe exists ONLY for the latched pause.
    func testProbe_onlyWhilePaused() {
        XCTAssertFalse(BondLoopSalvagePolicy.shouldProbe(pausedForBondLoop: false, connected: false,
                                                     intentionalDisconnect: false,
                                                     secondsSincePauseTripped: floor))
    }

    /// A live link or an explicit user teardown always suppresses the probe.
    func testProbe_suppressedWhenConnectedOrUserTornDown() {
        XCTAssertFalse(BondLoopSalvagePolicy.shouldProbe(pausedForBondLoop: true, connected: true,
                                                     intentionalDisconnect: false,
                                                     secondsSincePauseTripped: floor))
        XCTAssertFalse(BondLoopSalvagePolicy.shouldProbe(pausedForBondLoop: true, connected: false,
                                                     intentionalDisconnect: true,
                                                     secondsSincePauseTripped: floor))
    }
}
