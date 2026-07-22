import XCTest
import WhoopStore
@testable import NOOP

#if os(iOS)
final class AppleHealthDeviceTests: XCTestCase {
    private func daily(
        _ day: String,
        restingHr: Int? = nil,
        avgHrv: Double? = nil,
        totalSleepMin: Double? = nil,
        spo2Pct: Double? = nil,
        skinTempDevC: Double? = nil,
        steps: Int? = nil
    ) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: totalSleepMin,
            efficiency: nil,
            deepMin: nil,
            remMin: nil,
            lightMin: nil,
            disturbances: nil,
            restingHr: restingHr,
            avgHrv: avgHrv,
            recovery: nil,
            strain: nil,
            exerciseCount: nil,
            spo2Pct: spo2Pct,
            skinTempDevC: skinTempDevC,
            respRateBpm: nil,
            steps: steps
        )
    }

    private func apple(_ day: String, steps: Int? = nil, avgHr: Int? = nil) -> AppleDaily {
        AppleDaily(
            day: day,
            steps: steps,
            activeKcal: nil,
            basalKcal: nil,
            vo2max: nil,
            avgHr: avgHr,
            maxHr: nil,
            walkingHr: nil,
            weightKg: nil
        )
    }

    func testAuthorizationAndUsableDataAreBothRequired() {
        XCTAssertNil(AppleWatchDevice.device(daily: [], apple: [], authorized: true))
        XCTAssertNil(AppleWatchDevice.device(
            daily: [daily("2026-06-20", restingHr: 52)],
            apple: [],
            authorized: false
        ))
        XCTAssertNil(AppleWatchDevice.device(
            daily: [daily("2026-06-20")],
            apple: [],
            authorized: true
        ))
    }

    func testCapabilitiesAreTrimmedToObservedHealthKitData() {
        let full = AppleWatchDevice.device(
            daily: [daily(
                "2026-06-20",
                restingHr: 52,
                avgHrv: 45,
                totalSleepMin: 420,
                spo2Pct: 97,
                skinTempDevC: 0.1,
                steps: 8_000
            )],
            apple: [],
            authorized: true
        )
        XCTAssertEqual(full?.id, Repository.appleHealthSource)
        XCTAssertEqual(full?.brand, "Apple")
        XCTAssertEqual(full?.model, "Apple Health")
        XCTAssertEqual(full?.sourceKind, .liveAppleWatch)
        XCTAssertEqual(full?.capabilities, [.hr, .hrv, .sleep, .steps, .spo2, .skinTemp])

        let partial = AppleWatchDevice.device(
            daily: [daily("2026-06-20", avgHrv: 42)],
            apple: [apple("2026-06-20", steps: 5_000, avgHr: 70)],
            authorized: true
        )
        XCTAssertEqual(partial?.capabilities, [.hr, .hrv, .steps])
    }

    func testRefreshPreservesUserIdentityFields() {
        let existing = PairedDevice(
            id: Repository.appleHealthSource,
            brand: "Apple",
            model: "Apple Health",
            nickname: "My Health data",
            peripheralId: nil,
            sourceKind: .liveAppleWatch,
            capabilities: [.hr],
            status: .paired,
            addedAt: 1_000,
            lastSeenAt: 1_000
        )
        let refreshed = AppleWatchDevice.device(
            daily: [daily("2026-06-20", restingHr: 52, avgHrv: 45, totalSleepMin: 420, steps: 8_000)],
            apple: [],
            authorized: true,
            existing: existing,
            now: Date(timeIntervalSince1970: 2_000)
        )
        XCTAssertEqual(refreshed?.nickname, "My Health data")
        XCTAssertEqual(refreshed?.addedAt, 1_000)
        XCTAssertEqual(refreshed?.lastSeenAt, 2_000)
    }
}
#endif
