import XCTest
import StrandAnalytics
@testable import NOOP

/// Wiring of the discharge-run / slope / gate trace into the live path: banking the charge-step fixture
/// and calling emitBatteryTrace() lands the slope + gate lines, tagged .battery, when the mode is on
/// (#713, Test Centre). No em-dashes.
@MainActor
final class BatteryEstimateTraceEmitTests: XCTestCase {

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

    func testEmitBatteryTraceWritesSlopeAndGateLines() {
        XCTAssertEqual(TestCentre.active(.battery),
                       UserDefaults.standard.bool(forKey: "testcentre.active.battery"))
        let live = LiveState()
        let h = 3600
        live.bankBatterySample(100, now: 0)
        live.bankBatterySample(70, now: 4 * h)
        live.bankBatterySample(100, now: 5 * h)
        live.bankBatterySample(88, now: 11 * h)
        live.emitBatteryTrace()
        live.publishPendingLog() // Include lines queued by the real emitter before inspecting the log.
        XCTAssertTrue(live.log.contains { $0.contains("[battery] battery slope=2.0pct/h fitted from run endpoints") })
        XCTAssertTrue(live.log.contains { $0.contains("[battery] battery gate minSpanHours 2.0 PASS, minDropPct 2.0 PASS -> source=measured") })
    }

    func testEmitBatteryTraceIsNoOpWhenModeOff() {
        UserDefaults.standard.set(false, forKey: "testcentre.active.battery")
        XCTAssertEqual(TestCentre.active(.battery),
                       UserDefaults.standard.bool(forKey: "testcentre.active.battery"))
        let live = LiveState()
        live.bankBatterySample(100, now: 0)
        live.bankBatterySample(80, now: 10 * 3600)
        live.emitBatteryTrace()
        live.publishPendingLog() // Make the mode-off assertion inspect queued emissions too.
        XCTAssertFalse(live.log.contains { $0.contains("[battery]") })
    }
}
