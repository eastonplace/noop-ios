import XCTest
import StrandAnalytics
@testable import NOOP

@MainActor
final class NotificationRoutingTests: XCTestCase {
    func testColdLaunchWaitsForSourceAndDoesNotStartWorkout() {
        let router = NavRouter()
        router.handleNotificationDestination(.workout(id: "stable-session"))
        XCTAssertNil(router.takePendingNotification(sourceReady: false, activeWorkout: false))
        XCTAssertEqual(router.takePendingNotification(sourceReady: true, activeWorkout: false), .workout(id: "stable-session"))
        XCTAssertNil(router.workoutJourneyRequest)
        XCTAssertNil(router.takePendingNotification(sourceReady: true, activeWorkout: false))
    }

    func testOnboardingAndActiveWorkoutDeferWithoutDroppingTap() {
        let router = NavRouter()
        let blocker = UUID()
        router.setAutoPresentBlocked(true, id: blocker)
        router.handleNotificationDestination(.plannedWorkout(id: "plan-1"))
        XCTAssertNil(router.takePendingNotification(sourceReady: true, activeWorkout: false))
        router.setAutoPresentBlocked(false, id: blocker)
        XCTAssertNil(router.takePendingNotification(sourceReady: true, activeWorkout: true))
        XCTAssertEqual(router.takePendingNotification(sourceReady: true, activeWorkout: false), .plannedWorkout(id: "plan-1"))
        XCTAssertNil(router.workoutJourneyRequest)
    }

    func testUnknownPayloadVersionFallsBackToNotificationSettings() throws {
        let router = NavRouter()
        let data = try JSONEncoder().encode(NotificationDestination.workout(id: "old-record"))
        router.handleNotificationResponse(userInfo: ["noopNotificationVersion": 999, "noopNotificationDestination": String(decoding: data, as: UTF8.self)])
        XCTAssertEqual(router.takePendingNotification(sourceReady: true, activeWorkout: false), .settings(group: nil))
    }

    func testTapQueuePreservesMultipleDistinctDestinations() {
        let router = NavRouter()
        router.handleNotificationDestination(.journal(logicalDay: "2026-10-19"))
        router.handleNotificationDestination(.device(id: "device-A"))
        XCTAssertEqual(router.takePendingNotification(sourceReady: true, activeWorkout: false), .journal(logicalDay: "2026-10-19"))
        XCTAssertEqual(router.takePendingNotification(sourceReady: true, activeWorkout: false), .device(id: "device-A"))
    }
    func testReplacedSourceCannotOpenMatchingRecordInNewDatabase() {
        let router = NavRouter()
        router.handleNotificationDestination(.workout(id: "123:Running"), sourceID: "old-database")
        XCTAssertEqual(router.takePendingNotification(sourceReady: true, activeWorkout: false, sourceID: "new-database"), .settings(group: nil))
        XCTAssertNotNil(router.shellToast)
    }

    func testMalformedPayloadFallsBackSafely() {
        let router = NavRouter()
        router.handleNotificationResponse(userInfo: ["noopNotificationVersion": 1, "noopNotificationDestination": "bad-json"])
        XCTAssertEqual(router.takePendingNotification(sourceReady: true, activeWorkout: false), .settings(group: nil))
        XCTAssertNil(router.workoutJourneyRequest)
    }

    func testSettingsHasOneNotificationOwnerWithStableRoute() {
        let routes = SettingsRouteCatalog.rootSections.flatMap(\.routes).filter { $0.id == .notificationsAlerts }
        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(routes.first?.title, "Notifications")
        XCTAssertEqual(SettingsRouteCatalog.search("quiet hours").map(\.route), [.notificationsAlerts])
    }

    func testJournalNotificationDateDoesNotDriftAcrossMidnightBeforeWrite() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parser = ISO8601DateFormatter()
        let selected = try XCTUnwrap(parser.date(from: "2026-10-19T00:00:00Z"))
        let before = try XCTUnwrap(parser.date(from: "2026-10-20T23:59:00Z"))
        let after = try XCTUnwrap(parser.date(from: "2026-10-21T00:01:00Z"))
        XCTAssertEqual(JournalLogCard.entryDate(selectedDate: selected, dayOffset: 1, now: before, calendar: calendar), selected)
        XCTAssertEqual(JournalLogCard.entryDate(selectedDate: selected, dayOffset: 1, now: after, calendar: calendar), selected)
        XCTAssertNotEqual(JournalLogCard.entryDate(selectedDate: nil, dayOffset: 1, now: after, calendar: calendar), selected)
    }

    func testDelayedLiftRestorationKeepsTapQueuedUntilKnownIdle() {
        let router = NavRouter()
        router.handleNotificationDestination(.plannedWorkout(id: "plan-1"))
        let loading = NavRouter.notificationSourceIsReady(repositoryLoaded: true, repositoryFenced: false,
            liftRestorationComplete: false, liftSourceContext: nil, currentSourceContext: "source-A")
        XCTAssertNil(router.takePendingNotification(sourceReady: loading, activeWorkout: false))
        let restored = NavRouter.notificationSourceIsReady(repositoryLoaded: true, repositoryFenced: false,
            liftRestorationComplete: true, liftSourceContext: "source-A", currentSourceContext: "source-A")
        XCTAssertNil(router.takePendingNotification(sourceReady: restored, activeWorkout: true))
        XCTAssertEqual(router.takePendingNotification(sourceReady: restored, activeWorkout: false), .plannedWorkout(id: "plan-1"))
    }

    func testSameDeviceDifferentDatabaseCannotUseReadyOldLiftCoordinator() {
        XCTAssertFalse(NavRouter.notificationSourceIsReady(repositoryLoaded: true, repositoryFenced: false,
            liftRestorationComplete: true, liftSourceContext: "device-A|database-old", currentSourceContext: "device-A|database-new"))
        XCTAssertTrue(NavRouter.notificationSourceIsReady(repositoryLoaded: true, repositoryFenced: false,
            liftRestorationComplete: true, liftSourceContext: "device-A|database-new", currentSourceContext: "device-A|database-new"))
    }

}
