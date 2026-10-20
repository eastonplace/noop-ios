import XCTest
import StrandAnalytics
@testable import NOOP

@MainActor
final class NotificationPreferencesTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "NotificationPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testMigrationPreservesExplicitLegacyChoicesAndLeavesNewGroupsOff() {
        let d = defaults()
        d.set(false, forKey: "behavior.batteryAlerts")
        d.set(true, forKey: "behavior.batteryPredictiveAlerts")
        d.set(true, forKey: "behavior.illnessWatch")
        d.set(true, forKey: "windDown.enabled")
        d.set(365, forKey: "windDown.wakeMinutes")
        let prefs = NotificationPreferences(defaults: d)
        XCTAssertFalse(prefs.batteryAlerts)
        XCTAssertTrue(prefs.batteryPredictiveAlerts)
        XCTAssertTrue(prefs.illnessWatch)
        XCTAssertEqual(prefs.mode(for: .windDown), .notify)
        XCTAssertEqual(prefs.windDownWakeMinutes, 365)
        for group: NotificationGroup in [.morningSummary, .workoutPlan, .workoutSummary, .strainTarget, .weeklyReview, .journalCheckIn] {
            XCTAssertEqual(prefs.mode(for: group), .off)
        }
    }

    func testMigrationIsIdempotentAndPreferencesChangeActualRuntimeKeys() {
        let d = defaults()
        let prefs = NotificationPreferences(defaults: d)
        prefs.batteryAlerts = false
        prefs.illnessWatch = true
        prefs.windDownEnabled = true
        prefs.setMode(.inApp, for: .workoutSummary)
        let reopened = NotificationPreferences(defaults: d)
        XCTAssertFalse(reopened.batteryAlerts)
        XCTAssertTrue(d.bool(forKey: "behavior.illnessWatch"))
        XCTAssertTrue(d.bool(forKey: "windDown.enabled"))
        XCTAssertEqual(reopened.snapshot.mode(for: .workoutSummary), .inApp)
        XCTAssertEqual(d.integer(forKey: "notifications.schemaVersion"), 1)
    }

    func testLegacyKeyRemainsAuthoritativeAfterExternalCompatibilityWrite() {
        let d = defaults()
        let prefs = NotificationPreferences(defaults: d)
        d.set(false, forKey: "behavior.batteryAlerts")
        XCTAssertFalse(prefs.batteryAlerts)
        XCTAssertEqual(prefs.snapshot.mode(for: .batteryFull), .off)
    }

    func testChosenDaysAreValidatedAndEmptyJournalScheduleNeverMeansDaily() {
        let prefs = NotificationPreferences(defaults: defaults())
        XCTAssertTrue(prefs.journalWeekdays.isEmpty)
        XCTAssertFalse(prefs.dryRunEnabled)
        prefs.journalWeekdays = [0, 2, 6, 8]
        XCTAssertEqual(prefs.journalWeekdays, [2, 6])
        prefs.journalMinutes = 2000
        XCTAssertEqual(prefs.journalMinutes, 1439)
        prefs.windDownPerDayWakeMinutes = [0: 12, 2: -20, 4: 2000]
        XCTAssertEqual(prefs.windDownPerDayWakeMinutes, [2: 0, 4: 1439])
    }
    func testScheduleEditRevisesIdentityAndSurvivesRelaunch() {
        let d = defaults()
        let prefs = NotificationPreferences(defaults: d)
        let revision = prefs.scheduleRevision
        prefs.journalMinutes = 900
        XCTAssertGreaterThan(prefs.scheduleRevision, revision)
        XCTAssertEqual(NotificationPreferences(defaults: d).scheduleRevision, prefs.scheduleRevision)
    }

}
