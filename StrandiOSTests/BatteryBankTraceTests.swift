import XCTest
import StrandAnalytics
@testable import NOOP

/// The Battery test mode's gated per-sample emit: banking a SoC reading drops one tagged (t, soc) line
/// when the mode is on, and NOTHING when it is off (the zero-cost-when-off contract). Twin of the Android
/// BatterySocLineFormatTest's shape (#713, Test Centre). No em-dashes.
@MainActor
final class BatteryBankTraceTests: XCTestCase {

    private let modeKeys = ["testcentre.active.battery", "testcentre.active.master"]
    private var savedModes: [String: Any] = [:]

    override func setUp() async throws {
        try await super.setUp()
        let defaults = UserDefaults.standard
        savedModes = modeKeys.reduce(into: [:]) { saved, key in
            saved[key] = defaults.object(forKey: key)
        }
        defaults.set(false, forKey: "testcentre.active.master")
        defaults.set(true, forKey: "testcentre.active.battery")
    }
    override func tearDown() async throws {
        for key in modeKeys {
            if let value = savedModes[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        savedModes.removeAll()
        try await super.tearDown()
    }

    func testBankEmitsTaggedSocLineWhenBatteryModeActive() {
        XCTAssertEqual(TestCentre.active(.battery),
                       UserDefaults.standard.bool(forKey: "testcentre.active.battery"))
        let live = LiveState()
        live.bankBatterySample(80, now: 1000)
        live.publishPendingLog() // Include lines queued by the real emitter before inspecting the log.
        XCTAssertTrue(live.log.contains { $0.contains("[battery] bank soc=80.0 t=1000s") },
                      "expected a battery-tagged SoC line, got: \(live.log)")
    }

    func testBankEmitsNothingWhenBatteryModeOff() {
        UserDefaults.standard.set(false, forKey: "testcentre.active.battery")
        XCTAssertEqual(TestCentre.active(.battery),
                       UserDefaults.standard.bool(forKey: "testcentre.active.battery"))
        let live = LiveState()
        live.bankBatterySample(80, now: 1000)
        live.publishPendingLog() // Make the mode-off assertion inspect queued emissions too.
        XCTAssertFalse(live.log.contains { $0.contains("[battery]") })
    }
}
