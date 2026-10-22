import Foundation
import XCTest
@testable import NOOP

@MainActor
final class PuffinDeepDataPreferenceTests: XCTestCase {
    func testOnlyExplicitBooleanOptInAuthorizesDeepDataWrites() {
        let defaults = UserDefaults.standard
        let key = PuffinExperiment.deepDataKey
        let original = defaults.object(forKey: key)
        defer {
            if let original { defaults.set(original, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        defaults.removeObject(forKey: key)
        XCTAssertFalse(PuffinExperiment.deepDataEnabled)
        defaults.set(false, forKey: key)
        XCTAssertFalse(PuffinExperiment.deepDataEnabled)
        for malformed: Any in ["true", "YES", 1, 2, 1.0, [true]] {
            defaults.set(malformed, forKey: key)
            XCTAssertFalse(PuffinExperiment.deepDataEnabled,
                           "A non-Boolean saved preference must not authorize persistent firmware writes: \(malformed)")
        }
        defaults.set(true, forKey: key)
        XCTAssertTrue(PuffinExperiment.deepDataEnabled)
    }
}
