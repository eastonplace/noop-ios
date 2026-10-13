import XCTest
@testable import NOOP

/// BLE-12: a disconnect clears the live biometrics but keeps the seeded battery discharge history, so
/// "~X days left" does not fall back to a cold start after every reconnect.
@MainActor
final class LiveStateBatteryRetentionTests: XCTestCase {

    func testDisconnectKeepsSeededBatterySamples() {
        let live = LiveState()
        live.seedBatterySamples([(ts: 1_000, soc: 80), (ts: 4_600, soc: 78), (ts: 8_200, soc: 76)])
        live.setRRIntervals([800, 810])
        live.clearBiometrics()
        XCTAssertEqual(live.batterySamples.map(\.ts), [1_000, 4_600, 8_200])
        XCTAssertTrue(live.rrRecent.isEmpty, "the live biometrics are still cleared")
    }

    func testExplicitClearStillEmptiesTheBatteryHistory() {
        let live = LiveState()
        live.seedBatterySamples([(ts: 1_000, soc: 80)])
        live.clearBatterySamples()
        XCTAssertTrue(live.batterySamples.isEmpty)
    }
}
