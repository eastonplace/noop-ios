import XCTest
import StrandAnalytics
import WhoopProtocol
import WhoopStore
@testable import NOOP

@MainActor
final class RecoveryReadinessReceiptTests: XCTestCase {
    func testReceiptLineIsCountsAndGateStatesOnly() {
        let receipt = RecoveryReadinessReceipt(
            day: "2026-07-26",
            storeAvailable: true,
            rawSourceCount: 1,
            hrRows: 12_345,
            rrRows: 9_876,
            validSleepSessions: 1,
            defensiblyStagedSessions: 1,
            rrRowsInsideSleep: 8_765,
            dailyRowPresent: true,
            hrvPresent: true,
            restingHRPresent: true,
            hrvBaselineNights: 4,
            hrvBaselineUsable: true,
            scorerInputsReady: true,
            recoveryPresent: false)

        XCTAssertEqual(
            receipt.line,
            "recoveryReceipt day=2026-07-26 store=1 rawSources=1 hrRows=12345 rrRows=9876 "
                + "validSleep=1 stagedSleep=1 rrInSleep=8765 daily=1 hrv=1 rhr=1 "
                + "baselineN=4 baselineUsable=1 scorerInputsReady=1 recovery=0")
        XCTAssertFalse(receipt.line.contains("bpm"))
        XCTAssertFalse(receipt.line.contains("milliseconds"))
        XCTAssertFalse(receipt.line.contains("percent"))
    }

    func testReceiptIdentifiesReadyInputsWithoutInventingMissingRecovery() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: Repository.whoopSource)
        repo.setStoreForTesting(store)
        let computedId = Repository.whoopSource + "-noop"

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        let targetDay = "2026-07-26"
        let dayStartDate = try XCTUnwrap(formatter.date(from: targetDay))
        let dayStart = Int(dayStartDate.timeIntervalSince1970)
        let now = dayStartDate.addingTimeInterval(12 * 3_600)

        var history: [DailyMetric] = []
        for daysBack in stride(from: 4, through: 1, by: -1) {
            let date = Calendar.current.date(byAdding: .day, value: -daysBack, to: dayStartDate)!
            history.append(DailyMetric(
                day: formatter.string(from: date),
                totalSleepMin: 420,
                efficiency: 0.88,
                deepMin: 70,
                remMin: 90,
                lightMin: 260,
                disturbances: 3,
                restingHr: 52 + daysBack,
                avgHrv: 55 + Double(daysBack),
                recovery: 70,
                strain: 20,
                exerciseCount: 1))
        }
        history.append(DailyMetric(
            day: targetDay,
            totalSleepMin: 430,
            efficiency: 0.9,
            deepMin: 80,
            remMin: 95,
            lightMin: 255,
            disturbances: 2,
            restingHr: 51,
            avgHrv: 64,
            recovery: nil,
            strain: 22,
            exerciseCount: 1))
        _ = try await store.upsertDailyMetrics(history, deviceId: computedId)

        let sleepStart = dayStart - 8 * 3_600
        let sleepEnd = dayStart + 6 * 3_600
        _ = try await store.upsertSleepSessions([
            CachedSleepSession(
                startTs: sleepStart,
                endTs: sleepEnd,
                efficiency: 0.9,
                restingHr: 51,
                avgHrv: 64,
                stagesJSON: #"{"awake":30,"light":240,"deep":80,"rem":90}"#)
        ], deviceId: computedId)

        let sampleRange = 0..<300
        try await store.insert(
            Streams(
                hr: sampleRange.map { HRSample(ts: sleepStart + $0, bpm: 55) },
                rr: sampleRange.map { RRInterval(ts: sleepStart + $0, rrMs: 900 + ($0 % 2) * 20) },
                gravity: sampleRange.map { GravitySample(ts: sleepStart + $0, x: 0, y: 0, z: 1) }),
            deviceId: Repository.whoopSource)

        let receipt = await DebugDataDiagnostics.recoveryReadinessReceipt(
            repo: repo,
            day: targetDay,
            now: now)

        XCTAssertTrue(receipt.storeAvailable)
        XCTAssertEqual(receipt.rawSourceCount, 1)
        XCTAssertEqual(receipt.hrRows, 300)
        XCTAssertEqual(receipt.rrRows, 300)
        XCTAssertEqual(receipt.validSleepSessions, 1)
        XCTAssertEqual(receipt.defensiblyStagedSessions, 1)
        XCTAssertEqual(receipt.rrRowsInsideSleep, 300)
        XCTAssertTrue(receipt.dailyRowPresent)
        XCTAssertTrue(receipt.hrvPresent)
        XCTAssertTrue(receipt.restingHRPresent)
        XCTAssertGreaterThanOrEqual(receipt.hrvBaselineNights, Baselines.minNightsSeed)
        XCTAssertTrue(receipt.hrvBaselineUsable)
        XCTAssertTrue(receipt.scorerInputsReady)
        XCTAssertFalse(receipt.recoveryPresent,
                       "the receipt reports the missing persisted result; it never fabricates one")
    }
}
