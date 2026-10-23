import Foundation
import XCTest
import WhoopStore
@testable import NOOP

final class WhoopImporterNumericBoundaryTests: XCTestCase {
    func testMalformedNumericCellsDoNotCrashOrPoisonWhoopStore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-whoop-numeric-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try """
        Cycle start time,Cycle end time,Cycle timezone,Resting heart rate (bpm),Heart rate variability (ms),Day strain,Asleep duration (min)
        2024-01-01 06:30:00,2024-01-02 06:29:00,UTC+00:00,1e300,68.4,1e308,420
        2024-01-02 06:30:00,2024-01-03 06:29:00,UTC+00:00,52.4,72,10.5,440
        """.write(to: directory.appendingPathComponent("physiological_cycles.csv"), atomically: true, encoding: .utf8)
        try """
        Workout start time,Workout end time,Cycle timezone,Activity name,Average HR (bpm),Max HR (bpm),Activity strain
        2024-01-02 08:00:00,2024-01-02 09:00:00,UTC+00:00,Running,1e300,-1e300,1e308
        2024-01-03 08:00:00,2024-01-03 09:00:00,UTC+00:00,Cycling,140.4,180.6,21
        """.write(to: directory.appendingPathComponent("workouts.csv"), atomically: true, encoding: .utf8)
        let store = try await WhoopStore.inMemory()
        _ = try await WhoopImporter.importExport(url: directory, into: store, deviceId: "whoop-numeric")
        let days = try await store.dailyMetrics(deviceId: "whoop-numeric", from: "2024-01-01", to: "2024-01-04")
        let malformed = try XCTUnwrap(days.first { $0.day == "2024-01-02" })
        XCTAssertNil(malformed.restingHr)
        XCTAssertNil(malformed.strain)
        XCTAssertEqual(malformed.avgHrv, 68.4)
        XCTAssertEqual(malformed.totalSleepMin, 420)
        let valid = try XCTUnwrap(days.first { $0.day == "2024-01-03" })
        XCTAssertEqual(valid.restingHr, 52)
        XCTAssertEqual(try XCTUnwrap(valid.strain), 50, accuracy: 0.000001)
        let strain = try await store.metricSeries(deviceId: "whoop-numeric", key: "strain", from: "2024-01-01", to: "2024-01-04")
        XCTAssertEqual(strain.map(\.day), ["2024-01-03"])
        XCTAssertEqual(try XCTUnwrap(strain.first?.value), 50, accuracy: 0.000001)
        let rhr = try await store.metricSeries(deviceId: "whoop-numeric", key: "rhr", from: "2024-01-01", to: "2024-01-04")
        XCTAssertEqual(rhr.map(\.day), ["2024-01-03"])
        XCTAssertEqual(rhr.first?.value, 52.4, "the explorer retains valid verbatim CSV precision")
        let stress = try await store.metricSeries(deviceId: "whoop-numeric", key: "stress", from: "2024-01-01", to: "2024-01-04")
        XCTAssertEqual(stress.map(\.day), ["2024-01-03"])
        let workouts = try await store.workouts(deviceId: "whoop-numeric", from: 1_704_067_200, to: 1_704_412_800, limit: 10)
        let badWorkout = try XCTUnwrap(workouts.first { $0.sport == "Running" })
        XCTAssertNil(badWorkout.avgHr)
        XCTAssertNil(badWorkout.maxHr)
        XCTAssertNil(badWorkout.strain)
        let goodWorkout = try XCTUnwrap(workouts.first { $0.sport == "Cycling" })
        XCTAssertEqual(goodWorkout.avgHr, 140)
        XCTAssertEqual(goodWorkout.maxHr, 181)
        XCTAssertEqual(try XCTUnwrap(goodWorkout.strain), 100, accuracy: 0.000001)
    }

    func testWhoopNumericBoundaryPreservesRoundedHeartRateAndDocumentedStrainScale() throws {
        for invalid in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, Double(Int.max)] {
            XCTAssertNil(WhoopImporter.roundedImportedHeartRate(invalid))
        }
        XCTAssertEqual(WhoopImporter.roundedImportedHeartRate(52.6), 53)
        XCTAssertNil(WhoopImporter.importedEffort(-0.1))
        XCTAssertNil(WhoopImporter.importedEffort(21.1))
        XCTAssertNil(WhoopImporter.importedEffort(.greatestFiniteMagnitude))
        XCTAssertNil(WhoopImporter.importedEffort(.nan))
        XCTAssertEqual(WhoopImporter.importedEffort(0), 0)
        XCTAssertEqual(try XCTUnwrap(WhoopImporter.importedEffort(10.5)), 50, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(WhoopImporter.importedEffort(21)), 100, accuracy: 0.000001)
    }
}
