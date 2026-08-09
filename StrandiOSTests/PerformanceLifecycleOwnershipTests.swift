import XCTest
@testable import NOOP

#if os(iOS)
@MainActor
final class PerformanceLifecycleOwnershipTests: XCTestCase {
    func testOptimizedLifecycleForwardsEveryTransitionToTheSingleAppModelOwner() {
        var received: [Bool] = []

        PerformanceLifecycleOwnership.apply(false) { received.append($0) }
        PerformanceLifecycleOwnership.apply(true) { received.append($0) }

        XCTAssertEqual(received, [false, true])
    }
}

final class FullHistoryRepairAdmissionTests: XCTestCase {
    func testNoActiveSourceDoesNotAdmitPresentationMaintenance() {
        XCTAssertFalse(FullHistoryRepairAdmissionPolicy.canRun(
            applicationIsActive: false,
            repositoryLoaded: true,
            hasActiveLiveSource: false,
            hasTodaySnapshot: false,
            hasActiveImport: false,
            isBackfilling: false,
            hasActiveWorkout: false))
    }

    func testActiveSourceStillRequiresTodayFirstPaint() {
        XCTAssertFalse(FullHistoryRepairAdmissionPolicy.canRun(
            applicationIsActive: false,
            repositoryLoaded: true,
            hasActiveLiveSource: true,
            hasTodaySnapshot: false,
            hasActiveImport: false,
            isBackfilling: false,
            hasActiveWorkout: false))
        XCTAssertTrue(FullHistoryRepairAdmissionPolicy.canRun(
            applicationIsActive: false,
            repositoryLoaded: true,
            hasActiveLiveSource: true,
            hasTodaySnapshot: true,
            hasActiveImport: false,
            isBackfilling: false,
            hasActiveWorkout: false))
    }

    func testActivePresentationStillHonorsEveryIdleGate() {
        func canRun(
            applicationIsActive: Bool = false,
            repositoryLoaded: Bool = true,
            hasActiveImport: Bool = false,
            isBackfilling: Bool = false,
            hasActiveWorkout: Bool = false
        ) -> Bool {
            FullHistoryRepairAdmissionPolicy.canRun(
                applicationIsActive: applicationIsActive,
                repositoryLoaded: repositoryLoaded,
                hasActiveLiveSource: true,
                hasTodaySnapshot: true,
                hasActiveImport: hasActiveImport,
                isBackfilling: isBackfilling,
                hasActiveWorkout: hasActiveWorkout)
        }

        XCTAssertFalse(canRun(applicationIsActive: true))
        XCTAssertFalse(canRun(repositoryLoaded: false))
        XCTAssertFalse(canRun(hasActiveImport: true))
        XCTAssertFalse(canRun(isBackfilling: true))
        XCTAssertFalse(canRun(hasActiveWorkout: true))
    }
}
#endif
