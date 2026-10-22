import Foundation
import XCTest
@testable import WhoopProtocol

final class Whoop4AlarmPhysicalTestTests: XCTestCase {
    @MainActor
    func testEqualTestAndSavedWakeStillUsesDistinctRestorePhase() async {
        let sharedWake = Date(timeIntervalSince1970: 1_792_666_800)
        let nextSavedWake = Date(timeIntervalSince1970: 1_792_753_200)
        var currentTime = sharedWake.addingTimeInterval(-90)
        var armed: [Date] = []
        var restoreCount = 0
        let result = await Whoop4AlarmPhysicalTest.run(
            armTest: { armed.append(sharedWake) },
            observeFire: {
                currentTime = sharedWake.addingTimeInterval(1)
                return true
            },
            restore: {
                restoreCount += 1
                XCTAssertGreaterThan(currentTime, sharedWake)
                // The restore phase computes the next saved occurrence after the test finishes.
                armed.append(nextSavedWake)
            },
            restoreConfirmed: { armed.last == nextSavedWake })
        XCTAssertEqual(armed, [sharedWake, nextSavedWake])
        XCTAssertEqual(restoreCount, 1)
        XCTAssertTrue(result.fireObserved)
        XCTAssertTrue(result.restoreConfirmed)
    }

    @MainActor
    func testObservedFireRestoresOriginalWakeBeforeConfirmingRestore() async {
        let testWake = Date(timeIntervalSince1970: 1_792_627_600)
        let restoreWake = Date(timeIntervalSince1970: 1_792_666_800)
        var events: [String] = []
        let result = await Whoop4AlarmPhysicalTest.run(
            testWake: testWake, restoreWake: restoreWake,
            arm: { date in events.append(date == testWake ? "test" : "restore") },
            observeFire: { events.append("observedFire"); return true },
            restoreConfirmed: { events.append("confirmRestore"); return true })
        XCTAssertEqual(events, ["test", "observedFire", "restore", "confirmRestore"])
        XCTAssertTrue(result.fireObserved)
        XCTAssertTrue(result.restoreConfirmed)
    }

    @MainActor
    func testFireTimeoutStillRestoresOriginalWakeAndReportsTimeoutSeparately() async {
        let testWake = Date(timeIntervalSince1970: 1_792_627_600)
        let restoreWake = Date(timeIntervalSince1970: 1_792_666_800)
        var armed: [Date] = []
        var restoreChecks = 0
        let result = await Whoop4AlarmPhysicalTest.run(
            testWake: testWake, restoreWake: restoreWake,
            arm: { armed.append($0) }, observeFire: { false },
            restoreConfirmed: { restoreChecks += 1; return true })
        XCTAssertEqual(armed, [testWake, restoreWake])
        XCTAssertEqual(restoreChecks, 1)
        XCTAssertFalse(result.fireObserved)
        XCTAssertTrue(result.restoreConfirmed)
    }

    @MainActor
    func testMissingRestoreConfirmationNeverClaimsRestorationDespiteObservedFire() async {
        let testWake = Date(timeIntervalSince1970: 1_792_627_600)
        let restoreWake = Date(timeIntervalSince1970: 1_792_666_800)
        var armed: [Date] = []
        let result = await Whoop4AlarmPhysicalTest.run(
            testWake: testWake, restoreWake: restoreWake,
            arm: { armed.append($0) }, observeFire: { true }, restoreConfirmed: { false })
        XCTAssertEqual(armed, [testWake, restoreWake])
        XCTAssertTrue(result.fireObserved)
        XCTAssertFalse(result.restoreConfirmed)
    }
}
