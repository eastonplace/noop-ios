import XCTest
import WhoopStore
import StrandImport
@testable import NOOP

final class HealthImportNumericSafetyTests: XCTestCase {
    func testAppleExportWithInvalidNumbersPreservesUsableReadings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("export.xml")
        let xml = """
        <HealthData>
          <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="synthetic" startDate="2026-10-20 08:00:00 +0000" endDate="2026-10-20 08:00:00 +0000" value="NaN"/>
          <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="synthetic" startDate="2026-10-20 08:00:01 +0000" endDate="2026-10-20 08:00:01 +0000" value="80.6"/>
          <Record type="HKQuantityTypeIdentifierStepCount" sourceName="synthetic" startDate="2026-10-20 08:00:00 +0000" endDate="2026-10-20 09:00:00 +0000" value="1e100"/>
          <Workout workoutActivityType="HKWorkoutActivityTypeRunning" duration="10" durationUnit="min" startDate="2026-10-20 08:00:00 +0000" endDate="2026-10-20 08:10:00 +0000">
            <WorkoutStatistics type="HKQuantityTypeIdentifierHeartRate" average="NaN" maximum="1e100"/>
          </Workout>
        </HealthData>
        """
        try Data(xml.utf8).write(to: url)
        let store = try await WhoopStore.inMemory()

        _ = try await AppleHealthImport.importExport(url: url, into: store, deviceId: "synthetic")

        let daily = try await store.appleDaily(deviceId: "synthetic", from: "2026-10-20", to: "2026-10-20")
        XCTAssertEqual(daily.first?.avgHr, 81)
        XCTAssertEqual(daily.first?.maxHr, 81)
        XCTAssertNil(daily.first?.steps)
        let workouts = try await store.workouts(deviceId: "synthetic", from: 0, to: 2_000_000_000, limit: 10)
        XCTAssertEqual(workouts.count, 1)
        XCTAssertEqual(workouts.first?.durationS, 600)
        XCTAssertNil(workouts.first?.avgHr)
        XCTAssertNil(workouts.first?.maxHr)
    }

    func testWhoopExportOutOfRangeHeartRatesDoNotAbortOtherFields() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let csv = """
        Cycle start time,Cycle end time,Cycle timezone,Resting heart rate (bpm),Recovery score %
        2026-10-19 08:00:00,2026-10-20 08:00:00,+0000,1e100,78
        """
        try Data(csv.utf8).write(to: directory.appendingPathComponent("physiological_cycles.csv"))
        let store = try await WhoopStore.inMemory()

        _ = try await WhoopImporter.importExport(url: directory, into: store, deviceId: "synthetic")

        let daily = try await store.dailyMetrics(deviceId: "synthetic", from: "2026-10-19", to: "2026-10-20")
        XCTAssertEqual(daily.count, 1)
        XCTAssertNil(daily.first?.restingHr)
        XCTAssertEqual(daily.first?.recovery, 78)
    }

}
