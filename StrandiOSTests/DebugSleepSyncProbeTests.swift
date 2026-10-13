import XCTest
@testable import NOOP

@MainActor
final class DebugSleepSyncProbeTests: XCTestCase {
    func testInitialSeriesWaitsForStoreBeforeExporting() async {
        var readinessAttempts = 0
        var pauses: [Duration] = []
        var exportedSequences: [Int] = []
        let schedule = DebugSleepSyncProbe.InitialSeriesSchedule(
            readinessAttempts: 5,
            readinessDelay: .milliseconds(10),
            captureCount: 4,
            captureDelay: .seconds(20)
        )

        let completed = await DebugSleepSyncProbe.runInitialSeries(
            schedule: schedule,
            isStoreReady: {
                readinessAttempts += 1
                return readinessAttempts == 3
            },
            pause: { pauses.append($0) },
            export: { exportedSequences.append($0) }
        )

        XCTAssertTrue(completed)
        XCTAssertEqual(readinessAttempts, 3)
        XCTAssertEqual(exportedSequences, [0, 1, 2, 3])
        XCTAssertEqual(
            pauses,
            [.milliseconds(10), .milliseconds(10), .seconds(20), .seconds(20), .seconds(20)]
        )
    }

    func testInitialSeriesStopsAfterBoundedReadinessAttempts() async {
        var readinessAttempts = 0
        var pauses: [Duration] = []
        var exportedSequences: [Int] = []
        let schedule = DebugSleepSyncProbe.InitialSeriesSchedule(
            readinessAttempts: 3,
            readinessDelay: .seconds(1),
            captureCount: 4,
            captureDelay: .seconds(20)
        )

        let completed = await DebugSleepSyncProbe.runInitialSeries(
            schedule: schedule,
            isStoreReady: {
                readinessAttempts += 1
                return false
            },
            pause: { pauses.append($0) },
            export: { exportedSequences.append($0) }
        )

        XCTAssertFalse(completed)
        XCTAssertEqual(readinessAttempts, 3)
        XCTAssertEqual(pauses, [.seconds(1), .seconds(1)])
        XCTAssertTrue(exportedSequences.isEmpty)
    }
}
