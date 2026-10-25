import XCTest
@testable import NOOP

#if os(iOS)
@MainActor
final class HistoricalSyncBackgroundLaunchTests: XCTestCase {
    @MainActor
    private final class LaunchProbe {
        var syncRequests = 0
        var scheduledDelays: [TimeInterval] = []
        var cancellations = 0
        var admission: HistoricalSyncBackgroundTaskRegistrar.LaunchAdmission?
    }

    private func caughtUpSnapshot(
        maintenanceEligible: Bool = true,
        syncActive: Bool = false,
        now: TimeInterval = 11_000
    ) -> HistoricalSyncBackgroundSnapshot {
        HistoricalSyncBackgroundSnapshot(
            backlogRemains: false,
            maintenanceEligible: maintenanceEligible,
            syncActive: syncActive,
            connectionReady: true,
            now: now,
            lastBackfillAt: 10_000,
            powerSaving: false,
            emptyStreak: 0
        )
    }

    func testDueCaughtUpMaintenanceLaunchRequestsHistoryExactlyOnce() async {
        let probe = LaunchProbe()
        let initial = caughtUpSnapshot()
        let operation = HistoricalSyncBackgroundTaskRegistrar.makeOperation {
            probe.admission = HistoricalSyncBackgroundTaskRegistrar.admitLaunch(
                initial: initial,
                requestSync: {
                    probe.syncRequests += 1
                    return true
                },
                schedule: { probe.scheduledDelays.append($0) },
                cancel: { probe.cancellations += 1 }
            )
        }
        await operation.value

        XCTAssertEqual(probe.admission, .syncStarted)
        XCTAssertEqual(probe.syncRequests, 1)
        XCTAssertTrue(probe.scheduledDelays.isEmpty)
        XCTAssertEqual(probe.cancellations, 0)
    }

    func testCaughtUpMaintenanceBeforeItsFloorRearmsWithoutRequestingHistory() {
        let probe = LaunchProbe()
        let admission = HistoricalSyncBackgroundTaskRegistrar.admitLaunch(
            initial: caughtUpSnapshot(now: 10_100),
            requestSync: {
                probe.syncRequests += 1
                return true
            },
            schedule: { probe.scheduledDelays.append($0) },
            cancel: { probe.cancellations += 1 }
        )

        XCTAssertEqual(admission, .completed(success: true))
        XCTAssertEqual(probe.syncRequests, 0)
        XCTAssertEqual(probe.scheduledDelays, [800])
        XCTAssertEqual(probe.cancellations, 0)
    }

    func testIneligibleCaughtUpLaunchCancelsWithoutRequestingHistory() {
        let probe = LaunchProbe()
        let admission = HistoricalSyncBackgroundTaskRegistrar.admitLaunch(
            initial: caughtUpSnapshot(maintenanceEligible: false),
            requestSync: {
                probe.syncRequests += 1
                return true
            },
            schedule: { probe.scheduledDelays.append($0) },
            cancel: { probe.cancellations += 1 }
        )

        XCTAssertEqual(admission, .completed(success: true))
        XCTAssertEqual(probe.syncRequests, 0)
        XCTAssertTrue(probe.scheduledDelays.isEmpty)
        XCTAssertEqual(probe.cancellations, 1)
    }

    func testActiveSyncLaunchCannotRequestOverlappingHistory() {
        let probe = LaunchProbe()
        let admission = HistoricalSyncBackgroundTaskRegistrar.admitLaunch(
            initial: caughtUpSnapshot(syncActive: true),
            requestSync: {
                probe.syncRequests += 1
                return true
            },
            schedule: { probe.scheduledDelays.append($0) },
            cancel: { probe.cancellations += 1 }
        )

        XCTAssertEqual(admission, .completed(success: true))
        XCTAssertEqual(probe.syncRequests, 0)
        XCTAssertTrue(probe.scheduledDelays.isEmpty)
        XCTAssertEqual(probe.cancellations, 1)
    }

    func testMissingSnapshotLaunchCancelsWithoutRequestingHistory() {
        let probe = LaunchProbe()
        let admission = HistoricalSyncBackgroundTaskRegistrar.admitLaunch(
            initial: nil,
            requestSync: {
                probe.syncRequests += 1
                return true
            },
            schedule: { probe.scheduledDelays.append($0) },
            cancel: { probe.cancellations += 1 }
        )

        XCTAssertEqual(admission, .completed(success: false))
        XCTAssertEqual(probe.syncRequests, 0)
        XCTAssertTrue(probe.scheduledDelays.isEmpty)
        XCTAssertEqual(probe.cancellations, 1)
    }

    func testRefusedDueMaintenanceRequestKeepsBoundedRetry() {
        let probe = LaunchProbe()
        let admission = HistoricalSyncBackgroundTaskRegistrar.admitLaunch(
            initial: caughtUpSnapshot(),
            requestSync: {
                probe.syncRequests += 1
                return false
            },
            schedule: { probe.scheduledDelays.append($0) },
            cancel: { probe.cancellations += 1 }
        )

        XCTAssertEqual(admission, .completed(success: true))
        XCTAssertEqual(probe.syncRequests, 1)
        XCTAssertEqual(probe.scheduledDelays, [900])
        XCTAssertEqual(probe.cancellations, 0)
    }

    func testExpirationBeforeMaintenanceLaunchCannotIssueHistory() async {
        let probe = LaunchProbe()
        let initial = caughtUpSnapshot()
        let operation = HistoricalSyncBackgroundTaskRegistrar.makeOperation {
            probe.admission = HistoricalSyncBackgroundTaskRegistrar.admitLaunch(
                initial: initial,
                requestSync: {
                    probe.syncRequests += 1
                    return true
                },
                schedule: { probe.scheduledDelays.append($0) },
                cancel: { probe.cancellations += 1 }
            )
        }
        operation.cancel()
        await operation.value

        XCTAssertNil(probe.admission)
        XCTAssertEqual(probe.syncRequests, 0)
        XCTAssertTrue(probe.scheduledDelays.isEmpty)
        XCTAssertEqual(probe.cancellations, 0)
    }

    func testCancellationAfterLaunchAdmissionBeginsCannotIssueHistory() async {
        let probe = LaunchProbe()
        let initial = caughtUpSnapshot()
        let operation = HistoricalSyncBackgroundTaskRegistrar.makeOperation {
            withUnsafeCurrentTask { $0?.cancel() }
            probe.admission = HistoricalSyncBackgroundTaskRegistrar.admitLaunch(
                initial: initial,
                requestSync: {
                    probe.syncRequests += 1
                    return true
                },
                schedule: { probe.scheduledDelays.append($0) },
                cancel: { probe.cancellations += 1 }
            )
        }
        await operation.value

        XCTAssertEqual(probe.admission, .cancelled)
        XCTAssertEqual(probe.syncRequests, 0)
        XCTAssertTrue(probe.scheduledDelays.isEmpty)
        XCTAssertEqual(probe.cancellations, 0)
    }
}
#endif
