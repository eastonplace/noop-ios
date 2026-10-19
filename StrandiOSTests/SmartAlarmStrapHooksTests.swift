import XCTest
@testable import NOOP

final class SmartAlarmStrapHooksTests: XCTestCase {
    /// A Bluetooth-restoration relaunch builds the controller but never reaches the UI `.task` that calls
    /// `start()`. The strap-fired hook must already be installed, and installing twice must be harmless.
    @MainActor
    func testStrapFiredHookInstalledWithoutStart() throws {
        let suite = "SmartAlarmStrapHooksTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel()
        let modeStore = SmartAlarmAdaptiveModeStore(legacy: model.behavior, defaults: defaults)
        let controller = SmartAlarmRuntimeController(model: model, modeStore: modeStore)

        XCTAssertNil(model.live.onSmartAlarmFired)
        controller.installStrapHooks()
        XCTAssertNotNil(model.live.onSmartAlarmFired)

        controller.installStrapHooks()
        XCTAssertNotNil(model.live.onSmartAlarmFired)
    }
}
