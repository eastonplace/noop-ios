import XCTest
import StrandAnalytics
import WhoopStore
@testable import NOOP

@MainActor
final class StrapComparisonCardTests: XCTestCase {
    func testComparableDevicesKeepsPhysicalWhoopAndOuraInStablePriorityOrder() {
        let devices = [
            device(id: "generic-active", brand: "Polar", sourceKind: .liveBLE,
                   status: .active, addedAt: 50, lastSeenAt: 500),
            device(id: "whoop-import", brand: "WHOOP", sourceKind: .cloudImport,
                   status: .paired, addedAt: 40, lastSeenAt: 400),
            device(id: "oura-archived", brand: "Oura", sourceKind: .oura,
                   status: .archived, addedAt: 30, lastSeenAt: 300),
            device(id: "oura-active", brand: "Oura", sourceKind: .oura,
                   status: .active, addedAt: 20, lastSeenAt: 20),
            device(id: "whoop-older", brand: "WHOOP", sourceKind: .historyBLE,
                   status: .paired, addedAt: 10, lastSeenAt: 100),
            device(id: "whoop-newer", brand: "whoop", sourceKind: .historyBLE,
                   status: .paired, addedAt: 5, lastSeenAt: 200)
        ]

        XCTAssertEqual(
            StrapComparisonDataLoader.comparableDevices(devices).map(\.id),
            ["oura-active", "whoop-newer", "whoop-older"]
        )
    }

    func testDailyMetricMappingUsesOnlySupportedRawDailyFields() {
        let metric = daily(
            "2026-09-03",
            restingHr: 54,
            avgHrv: 61.5,
            spo2Pct: 97.2,
            skinTempDevC: -0.3,
            steps: 8_420,
            totalSleepMin: 432,
            activeKcalEst: 615.4
        )

        XCTAssertEqual(
            StrapComparisonDataLoader.metricValues(metric),
            [
                .restingHR: 54,
                .hrv: 61.5,
                .spo2: 97.2,
                .skinTemp: -0.3,
                .steps: 8_420,
                .sleep: 432,
                .calories: 615.4
            ]
        )
    }

    func testDayWindowIsThirtyInclusiveCalendarDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 3,
            hour: 12
        )))

        XCTAssertEqual(
            StrapComparisonDataLoader.dayWindow(endingAt: date, calendar: calendar),
            .init(fromDay: "2026-08-05", toDay: "2026-09-03")
        )
    }

    func testLoadReadsExactDeviceIdsAndChoosesLatestSharedDayInsideWindow() async throws {
        let first = device(id: "whoop-exact-7", brand: "WHOOP", sourceKind: .historyBLE,
                           status: .active, addedAt: 1, lastSeenAt: 20)
        let second = device(id: "oura-exact-9", brand: "Oura", sourceKind: .oura,
                            status: .paired, addedAt: 2, lastSeenAt: 30)
        let probe = MetricReadProbe(rowsByDeviceId: [
            first.id: [
                daily("2026-09-01", restingHr: 56),
                daily("2026-09-02", restingHr: 54, steps: 8_000),
                daily("2026-09-20", restingHr: 40)
            ],
            second.id: [
                daily("2026-09-02", restingHr: 55, steps: 7_900),
                daily("2026-09-03", restingHr: 53),
                daily("2026-09-20", restingHr: 41)
            ]
        ])

        let outcome = try await StrapComparisonDataLoader.load(
            devices: [second, first],
            fromDay: "2026-08-05",
            toDay: "2026-09-03",
            readDailyMetrics: { deviceId, fromDay, toDay in
                try await probe.read(deviceId: deviceId, fromDay: fromDay, toDay: toDay)
            }
        )

        guard case .snapshot(let snapshot) = outcome else {
            XCTFail("Expected a comparison snapshot")
            return
        }
        XCTAssertEqual(snapshot.firstDeviceId, "whoop-exact-7")
        XCTAssertEqual(snapshot.secondDeviceId, "oura-exact-9")
        XCTAssertEqual(snapshot.day, "2026-09-02")
        XCTAssertEqual(snapshot.rows.first(where: { $0.metric == .restingHR })?.a, 54)
        XCTAssertEqual(snapshot.rows.first(where: { $0.metric == .restingHR })?.b, 55)
        XCTAssertEqual(snapshot.rows.first(where: { $0.metric == .steps })?.a, 8_000)
        XCTAssertEqual(snapshot.rows.first(where: { $0.metric == .steps })?.b, 7_900)
        let calls = await probe.capturedCalls()
        XCTAssertEqual(Set(calls), Set([
            .init(deviceId: "whoop-exact-7", fromDay: "2026-08-05", toDay: "2026-09-03"),
            .init(deviceId: "whoop-exact-7-noop", fromDay: "2026-08-05", toDay: "2026-09-03"),
            .init(deviceId: "oura-exact-9", fromDay: "2026-08-05", toDay: "2026-09-03"),
            .init(deviceId: "oura-exact-9-noop", fromDay: "2026-08-05", toDay: "2026-09-03")
        ]))
    }

    func testLoadFillsRawDeviceGapsFromItsComputedSiblingWithoutChangingIdentity() async throws {
        let first = device(id: "whoop-a", brand: "WHOOP", sourceKind: .historyBLE,
                           status: .active, addedAt: 1, lastSeenAt: 20)
        let second = device(id: "oura-b", brand: "Oura", sourceKind: .oura,
                            status: .paired, addedAt: 2, lastSeenAt: 30)
        let probe = MetricReadProbe(rowsByDeviceId: [
            first.id: [daily("2026-09-03", restingHr: 54)],
            first.id + "-noop": [daily("2026-09-03", restingHr: 70, avgHrv: 62)],
            second.id + "-noop": [daily("2026-09-03", restingHr: 56, avgHrv: 60)]
        ])

        let outcome = try await StrapComparisonDataLoader.load(
            devices: [first, second],
            fromDay: "2026-08-05",
            toDay: "2026-09-03",
            readDailyMetrics: { deviceId, fromDay, toDay in
                try await probe.read(deviceId: deviceId, fromDay: fromDay, toDay: toDay)
            }
        )

        guard case .snapshot(let snapshot) = outcome else {
            XCTFail("Expected a comparison snapshot")
            return
        }
        XCTAssertEqual(snapshot.firstDeviceId, first.id)
        XCTAssertEqual(snapshot.secondDeviceId, second.id)
        XCTAssertEqual(snapshot.rows.first(where: { $0.metric == .restingHR })?.a, 54)
        XCTAssertEqual(snapshot.rows.first(where: { $0.metric == .restingHR })?.b, 56)
        XCTAssertEqual(snapshot.rows.first(where: { $0.metric == .hrv })?.a, 62)
        XCTAssertEqual(snapshot.rows.first(where: { $0.metric == .hrv })?.b, 60)
    }

    func testLoadSkipsNewerSharedDayWithOnlyUnsupportedFields() async throws {
        let first = device(id: "whoop-a", brand: "WHOOP", sourceKind: .historyBLE,
                           status: .active, addedAt: 1, lastSeenAt: 20)
        let second = device(id: "oura-b", brand: "Oura", sourceKind: .oura,
                            status: .paired, addedAt: 2, lastSeenAt: 30)
        let probe = MetricReadProbe(rowsByDeviceId: [
            first.id: [
                daily("2026-09-02", restingHr: 54),
                daily("2026-09-03", recovery: 82)
            ],
            second.id: [
                daily("2026-09-02", restingHr: 56),
                daily("2026-09-03", recovery: 78)
            ]
        ])

        let outcome = try await StrapComparisonDataLoader.load(
            devices: [first, second],
            fromDay: "2026-08-05",
            toDay: "2026-09-03",
            readDailyMetrics: { deviceId, fromDay, toDay in
                try await probe.read(deviceId: deviceId, fromDay: fromDay, toDay: toDay)
            }
        )

        guard case .snapshot(let snapshot) = outcome else {
            XCTFail("Expected the older supported comparison snapshot")
            return
        }
        XCTAssertEqual(snapshot.day, "2026-09-02")
        XCTAssertEqual(snapshot.rows.map(\.metric), [.restingHR])
        XCTAssertEqual(snapshot.rows[0].a, 54)
        XCTAssertEqual(snapshot.rows[0].b, 56)
    }

    private func device(
        id: String,
        brand: String,
        sourceKind: SourceKind,
        status: DeviceStatus,
        addedAt: Int,
        lastSeenAt: Int
    ) -> PairedDevice {
        PairedDevice(
            id: id,
            brand: brand,
            model: brand,
            sourceKind: sourceKind,
            capabilities: [.hr, .hrv, .sleep],
            status: status,
            addedAt: addedAt,
            lastSeenAt: lastSeenAt
        )
    }

    private func daily(
        _ day: String,
        restingHr: Int? = nil,
        avgHrv: Double? = nil,
        spo2Pct: Double? = nil,
        skinTempDevC: Double? = nil,
        steps: Int? = nil,
        totalSleepMin: Double? = nil,
        activeKcalEst: Double? = nil,
        recovery: Double? = nil
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
            recovery: recovery,
            strain: nil,
            exerciseCount: nil,
            spo2Pct: spo2Pct,
            skinTempDevC: skinTempDevC,
            steps: steps,
            activeKcalEst: activeKcalEst
        )
    }
}

private actor MetricReadProbe {
    struct Call: Equatable, Hashable, Sendable {
        let deviceId: String
        let fromDay: String
        let toDay: String
    }

    private let rowsByDeviceId: [String: [DailyMetric]]
    private var calls: [Call] = []

    init(rowsByDeviceId: [String: [DailyMetric]]) {
        self.rowsByDeviceId = rowsByDeviceId
    }

    func read(deviceId: String, fromDay: String, toDay: String) throws -> [DailyMetric] {
        calls.append(.init(deviceId: deviceId, fromDay: fromDay, toDay: toDay))
        return rowsByDeviceId[deviceId] ?? []
    }

    func capturedCalls() -> [Call] {
        calls
    }
}
