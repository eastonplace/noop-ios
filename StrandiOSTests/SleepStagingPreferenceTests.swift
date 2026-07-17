import XCTest
@testable import NOOP

final class SleepStagingPreferenceTests: XCTestCase {
    func testUnsetPreferenceMatchesPromotedEngineAndSettingsDefault() throws {
        let suite = "sleep-v2-default-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removeObject(forKey: PuffinExperiment.experimentalSleepV2Key)

        XCTAssertTrue(PuffinExperiment.experimentalSleepV2Default)
        XCTAssertEqual(
            PuffinExperiment.experimentalSleepV2Enabled(in: defaults),
            PuffinExperiment.experimentalSleepV2Default
        )

        defaults.set(false, forKey: PuffinExperiment.experimentalSleepV2Key)
        XCTAssertFalse(PuffinExperiment.experimentalSleepV2Enabled(in: defaults),
                       "The user can still select the V1 fallback explicitly")
    }
}
