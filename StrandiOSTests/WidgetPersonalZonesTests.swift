import XCTest
import Combine
@testable import NOOP

/// The wearer's maximum heart rate on its way to the widgets: what is stored, what the widgets accept, and when the app
/// refreshes it.
@MainActor
final class WidgetPersonalZonesTests: XCTestCase {
    private var suite: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "noop.tests.personal-zones.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        suite.removePersistentDomain(forName: suiteName)
    }

    func testAPublishedMaximumReadsBackAndOnlyAChangeReportsAsOne() {
        XCTAssertNil(WidgetPersonalZones.hrMax(from: suite), "nothing shared yet: the widgets fall back to the fixed split")
        XCTAssertTrue(WidgetPersonalZones.publish(hrMax: 187, to: suite))
        XCTAssertEqual(WidgetPersonalZones.hrMax(from: suite), 187)
        XCTAssertFalse(WidgetPersonalZones.publish(hrMax: 187, to: suite), "same value: no widget reload needed")
        XCTAssertTrue(WidgetPersonalZones.publish(hrMax: 190, to: suite))
        XCTAssertEqual(WidgetPersonalZones.hrMax(from: suite), 190)
    }

    func testAnImplausibleMaximumIsNeverStoredOrRead() {
        XCTAssertFalse(WidgetPersonalZones.publish(hrMax: 0, to: suite))
        XCTAssertFalse(WidgetPersonalZones.publish(hrMax: 99, to: suite))
        XCTAssertFalse(WidgetPersonalZones.publish(hrMax: 261, to: suite))
        XCTAssertNil(WidgetPersonalZones.hrMax(from: suite))

        suite.set(40, forKey: WidgetPersonalZones.hrMaxKey)
        XCTAssertNil(WidgetPersonalZones.hrMax(from: suite), "a value written by something else is not trusted")
        suite.set(400, forKey: WidgetPersonalZones.hrMaxKey)
        XCTAssertNil(WidgetPersonalZones.hrMax(from: suite))
    }

    func testTheSyncAppliesTheProfilesRuleOverrideFirstThenAge() {
        let dob40 = ProfileStore.dateOfBirth(forAge: 40)
        XCTAssertEqual(WidgetPersonalZonesSync.hrMax(override: 0, dateOfBirth: dob40), 180, "208 - 0.7 x 40")
        XCTAssertEqual(WidgetPersonalZonesSync.hrMax(override: 175, dateOfBirth: dob40), 175, "a manual override wins")
        XCTAssertEqual(WidgetPersonalZonesSync.hrMax(override: 0, dateOfBirth: ProfileStore.dateOfBirth(forAge: 30)), 187)
    }

    func testTheSyncPublishesAtLaunchAndWhenTheOverrideChanges() {
        let profile = ProfileStore()
        let original = profile.hrMaxOverride
        defer { profile.hrMaxOverride = original }
        var reloads = 0
        WidgetPersonalZonesSync.start(profile: profile, defaults: suite) { reloads += 1 }

        let launch = ProfileStore.hrMax(age: profile.age, override: original)
        XCTAssertEqual(WidgetPersonalZones.hrMax(from: suite), Double(launch), "written at launch")
        XCTAssertEqual(reloads, 1)

        let changed = launch == 177 ? 178 : 177
        profile.hrMaxOverride = changed
        XCTAssertEqual(WidgetPersonalZones.hrMax(from: suite), Double(changed), "and again when the profile changes")
        XCTAssertEqual(reloads, 2)

        profile.hrMaxOverride = changed
        XCTAssertEqual(reloads, 2, "an unchanged maximum does not reload the widgets")
    }
}
