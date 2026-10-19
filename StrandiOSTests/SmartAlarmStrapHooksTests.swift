import XCTest
@testable import NOOP

final class SmartAlarmStrapHooksTests: XCTestCase {
    @MainActor
    private func makeController(defaults: UserDefaults) -> (AppModel, SmartAlarmRuntimeController) {
        let model = AppModel()
        let modeStore = SmartAlarmAdaptiveModeStore(legacy: model.behavior, defaults: defaults)
        return (model, SmartAlarmRuntimeController(model: model, modeStore: modeStore))
    }

    /// A Bluetooth-restoration relaunch builds the controller (StrandiOSApp.init) but never reaches the UI
    /// `.task` that calls `start()`. The strap-fired hook must already be live straight out of `init`, so
    /// removing the install from construction regresses this test.
    @MainActor
    func testStrapFiredHookInstalledByInitWithoutStart() throws {
        let suite = "SmartAlarmStrapHooksTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = AppModel()
        XCTAssertNil(model.live.onSmartAlarmFired)
        let modeStore = SmartAlarmAdaptiveModeStore(legacy: model.behavior, defaults: defaults)
        let controller = SmartAlarmRuntimeController(model: model, modeStore: modeStore)
        XCTAssertNotNil(model.live.onSmartAlarmFired)

        // A reconnect edge before `start()` must be safe, and the hook must survive `start()`.
        model.live.connectSettled += 1
        withExtendedLifetime(controller) {
            XCTAssertNotNil(model.live.onSmartAlarmFired)
        }
    }

    @MainActor
    func testStartKeepsStrapHookAndInstallIsIdempotent() throws {
        let suite = "SmartAlarmStrapHooksTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, controller) = makeController(defaults: defaults)

        controller.start()
        XCTAssertNotNil(model.live.onSmartAlarmFired)
        controller.installStrapHooks()
        XCTAssertNotNil(model.live.onSmartAlarmFired)
    }
}
