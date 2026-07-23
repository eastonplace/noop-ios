import Foundation
import XCTest
@testable import NOOP

final class SmartAlarmBackgroundTaskRegistrarTests: XCTestCase {
    @MainActor
    func testRequestLoaderDistinguishesMissingMalformedAndValidPayloads() throws {
        let suite = "SmartAlarmBackgroundRequestLoaderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(
            SmartAlarmBackgroundTaskRegistrar.loadRequest(defaults: defaults),
            .missing
        )

        defaults.set(Data("not-json".utf8), forKey: "smartAlarm.runtime.backgroundRequest")
        XCTAssertEqual(
            SmartAlarmBackgroundTaskRegistrar.loadRequest(defaults: defaults),
            .malformed
        )
        SmartAlarmBackgroundTaskRegistrar.clearStoredRequest(defaults: defaults)
        XCTAssertEqual(
            SmartAlarmBackgroundTaskRegistrar.loadRequest(defaults: defaults),
            .missing
        )

        let snapshot = SmartAlarmRuntimeSnapshot(
            enabled: true,
            mode: .sleepGoal,
            minutes: 7 * 60,
            weekdays: [2, 3, 4, 5, 6]
        )
        let request = SmartAlarmBackgroundRequest(
            configurationID: UUID(),
            endpoint: Date(timeIntervalSince1970: 1_800_000_000),
            snapshot: snapshot
        )
        defaults.set(
            try JSONEncoder().encode(request),
            forKey: "smartAlarm.runtime.backgroundRequest"
        )
        XCTAssertEqual(
            SmartAlarmBackgroundTaskRegistrar.loadRequest(defaults: defaults),
            .loaded(request)
        )
    }
}
