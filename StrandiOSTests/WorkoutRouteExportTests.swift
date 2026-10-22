import Foundation
import XCTest
import CoreLocation
import WorkoutRouteExport
@testable import NOOP

final class WorkoutRouteExportPersistenceTests: XCTestCase {
    private let start: Int64 = 1_735_689_600_000

    private var points: [RecordedRoutePoint] {
        [.init(latitude: 51.5, longitude: -0.12, timestampMs: start, horizontalAccuracyM: 4.5),
         .init(latitude: 51.5001, longitude: -0.12, timestampMs: start + 10_000, horizontalAccuracyM: nil)]
    }

    private var route: WorkoutRoute {
        WorkoutRoute(segmentPolylines: [RouteMath.encode(points.map { .init($0.latitude, $0.longitude) })],
                     distanceM: RouteExporter.distanceMeters(in: [points]), pointSegments: [points])
    }

    private func environment() throws -> (UserDefaults, URL) {
        let suite = "gps-export-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return (defaults, directory)
    }

    func testLegacyRouteJSONRemainsDrawableWithoutExportedGuesses() throws {
        let legacy = WorkoutRoute(polyline: route.polyline, distanceM: route.distanceM)
        let data = try XCTUnwrap(RouteStore.encodeMap(["1735689600|Running": legacy]))
        let restored = try XCTUnwrap(RouteStore.decodeMap(data).values.first)
        XCTAssertTrue(restored.hasDrawableSegment)
        XCTAssertNil(restored.pointSegments)
        XCTAssertFalse(restored.hasExportableMeasurements)
        XCTAssertNil(WorkoutRouteExportService.newestExportableRoute(from: ["1735689600|Running": restored]))
        XCTAssertThrowsError(try WorkoutRouteExportService.file(format: .gpx, route: restored,
                                                               startTs: 1_735_689_600, sport: "Running"))
    }

    func testFinishedRouteStoreRoundTripIncludesMeasurementsAndSegments() throws {
        let (defaults, _) = try environment()
        let second = points.map { RecordedRoutePoint(latitude: $0.latitude + 1, longitude: $0.longitude,
            timestampMs: $0.timestampMs + 120_000, horizontalAccuracyM: $0.horizontalAccuracyM) }
        let all = [points, second]
        let value = WorkoutRoute(segmentPolylines: all.map { RouteMath.encode($0.map { .init($0.latitude, $0.longitude) }) },
                                 distanceM: RouteExporter.distanceMeters(in: all), pointSegments: all)
        RouteStore.store(value, startTs: Int(start / 1_000), sport: "Running", into: defaults)
        let restored = try XCTUnwrap(RouteStore.load(startTs: Int(start / 1_000), sport: "Running", from: defaults))
        XCTAssertEqual(restored, value)
        XCTAssertEqual(restored.pointSegments?.map(\.count), [2, 2])
        XCTAssertTrue(restored.hasExportableMeasurements)
        RouteStore.remove(startTs: Int(start / 1_000), sport: "Running", from: defaults)
        XCTAssertNil(RouteStore.load(startTs: Int(start / 1_000), sport: "Running", from: defaults))
    }

    func testBadOptionalExportMetadataCannotEraseOtherRouteMaps() throws {
        var invalid = route
        invalid.pointSegments = [[.init(latitude: .nan, longitude: 1, timestampMs: start), points[1]]]
        let data = try XCTUnwrap(RouteStore.encodeMap(["good": route, "corrupt": invalid]))
        let restored = RouteStore.decodeMap(data)
        XCTAssertEqual(restored["good"], route)
        XCTAssertTrue(restored["corrupt"]?.hasDrawableSegment == true)
        XCTAssertFalse(restored["corrupt"]?.hasExportableMeasurements == true)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(route)) as? [String: Any])
        object["pointSegments"] = "damaged metadata"
        let decoded = try JSONDecoder().decode(WorkoutRoute.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(decoded.hasDrawableSegment)
        XCTAssertNil(decoded.pointSegments)
    }

    func testMismatchedMetadataOrJoinedPauseSegmentsCannotExportADifferentMap() {
        var mismatched = route
        mismatched.pointSegments = [points.map { RecordedRoutePoint(latitude: $0.latitude + 10,
            longitude: $0.longitude, timestampMs: $0.timestampMs, horizontalAccuracyM: $0.horizontalAccuracyM) }]
        XCTAssertFalse(mismatched.hasExportableMeasurements)
        XCTAssertThrowsError(try WorkoutRouteExportService.file(format: .gpx, route: mismatched,
            startTs: Int(start / 1_000), sport: "Running"))
        let second = points.map { RecordedRoutePoint(latitude: $0.latitude + 1, longitude: $0.longitude,
            timestampMs: $0.timestampMs + 120_000) }
        let paused = WorkoutRoute(segmentPolylines: [points, second].map {
            RouteMath.encode($0.map { .init($0.latitude, $0.longitude) })
        }, distanceM: RouteExporter.distanceMeters(in: [points, second]), pointSegments: [points + second])
        XCTAssertFalse(paused.hasExportableMeasurements, "Metadata cannot bridge a stored pause boundary")
    }

    func testShortcutResolvesLatestValidSavedRouteAndUsesSameWriterAsDetail() throws {
        let routes = ["1735689600|Running|outdoors": route,
                      "1735689700|Running": WorkoutRoute(polyline: route.polyline, distanceM: route.distanceM),
                      "bad|Running": route, "1735689800|Wrong session": route]
        let resolved = try XCTUnwrap(WorkoutRouteExportService.newestExportableRoute(from: routes))
        XCTAssertEqual(resolved.startTs, 1_735_689_600)
        XCTAssertEqual(resolved.sport, "Running|outdoors")
        for format in RouteExportFormat.allCases {
            let detail = try WorkoutRouteExportService.file(format: format, route: route,
                startTs: 1_735_689_600, sport: "Running|outdoors")
            let shortcut = try WorkoutRouteExportService.file(format: format, route: resolved.route,
                startTs: resolved.startTs, sport: resolved.sport)
            XCTAssertEqual(detail.data, shortcut.data)
            XCTAssertEqual(detail.filename, "noop-route-1735689600.\(format.rawValue)")
        }
        XCTAssertNil(WorkoutRouteExportService.parseKey("0|Run"))
        XCTAssertNil(WorkoutRouteExportService.parseKey("123| "))
        XCTAssertNil(WorkoutRouteExportService.newestExportableRoute(from: [:]))
    }

    func testJournalCodecRoundTripsMeasuredAndLegacyPointsAtFixedWidth() throws {
        let records = [
            ActiveGpsJournalPoint(point: .init(51.5, -0.12), startsNewSegment: true),
            ActiveGpsJournalPoint(point: .init(51.5001, -0.12), startsNewSegment: true,
                                  measurement: .init(timestampMs: start, horizontalAccuracyM: 4.5)),
            ActiveGpsJournalPoint(point: .init(51.5002, -0.12), startsNewSegment: false,
                                  measurement: .init(timestampMs: start + 10_000, horizontalAccuracyM: nil)),
        ]
        let bytes = ActiveGpsJournalCodec.encode(records)
        XCTAssertEqual(bytes.count, 3 * 33)
        XCTAssertEqual(ActiveGpsJournalCodec.decode(bytes, count: 3), records)
        XCTAssertNil(ActiveGpsJournalCodec.decode(bytes.dropLast(), count: 3))
        XCTAssertNil(ActiveGpsJournalCodec.encodedByteCount(for: Int.max))
        XCTAssertNil(ActiveGpsJournalCodec.encodedByteCount(for: -1))
        var corrupted = bytes
        corrupted[0] = 0x80
        XCTAssertNil(ActiveGpsJournalCodec.decode(corrupted, count: 3))
    }

    func testMeasuredSnapshotRoundTripAndShapeValidation() throws {
        let (defaults, _) = try environment()
        let segment = points.map { RouteMath.LatLng($0.latitude, $0.longitude) }
        let measurements = points.map { Optional(GpsPointMeasurement(timestampMs: $0.timestampMs,
                                                                     horizontalAccuracyM: $0.horizontalAccuracyM)) }
        let snapshot = ActiveGpsWorkoutPersistence.Snapshot(sessionID: UUID(), workoutStartMs: start,
            segments: [segment], distanceM: route.distanceM, rawFixCount: 2,
            recordingWasActive: true, hadTerminatedGap: false, pointMeasurements: [measurements])
        XCTAssertTrue(ActiveGpsWorkoutPersistence.store(snapshot, into: defaults))
        XCTAssertEqual(ActiveGpsWorkoutPersistence.load(from: defaults), snapshot)
        let badShape = ActiveGpsWorkoutPersistence.Snapshot(sessionID: UUID(), workoutStartMs: start,
            segments: [segment], distanceM: route.distanceM, rawFixCount: 2,
            recordingWasActive: true, hadTerminatedGap: false, pointMeasurements: [[measurements[0]]])
        XCTAssertFalse(badShape.isValid)
        let backwards = ActiveGpsWorkoutPersistence.Snapshot(sessionID: UUID(), workoutStartMs: start,
            segments: [segment], distanceM: route.distanceM, rawFixCount: 2,
            recordingWasActive: true, hadTerminatedGap: false, pointMeasurements: [Array(measurements.reversed())])
        XCTAssertFalse(backwards.isValid)
    }

    func testV2ActiveJournalMigratesWithoutInventingMeasurementsOrLosingRecovery() throws {
        let (defaults, directory) = try environment()
        let (sessionID, legacyURL, legacyData) = try seedV2Journal(defaults: defaults, directory: directory)
        let writer = ActiveGpsWorkoutPersistence.JournalWriter(defaults: defaults, directory: directory)
        let legacy = try XCTUnwrap(writer.load())
        XCTAssertNil(legacy.pointMeasurements)
        XCTAssertEqual(legacy.acceptedPointCount, 2)
        let next = ActiveGpsJournalPoint(point: .init(52, 1), startsNewSegment: true,
                                        measurement: .init(timestampMs: start + 120_000, horizontalAccuracyM: 5))
        let checkpoint = ActiveGpsWorkoutPersistence.Checkpoint(sessionID: sessionID, workoutStartMs: start,
            appendedPoints: [next], distanceM: legacy.distanceM, rawFixCount: 3, acceptedPointCount: 3,
            recordingWasActive: true, hadTerminatedGap: true)
        XCTAssertTrue(writer.store(checkpoint, synchronously: true))
        let restored = try XCTUnwrap(writer.load())
        XCTAssertEqual(restored.segments.map(\.count), [2, 1])
        XCTAssertEqual(restored.pointMeasurements?[0], [nil, nil])
        XCTAssertEqual(restored.pointMeasurements?[1], [next.measurement])
        let metadata = try JSONDecoder().decode(ActiveGpsWorkoutPersistence.JournalMetadata.self,
            from: XCTUnwrap(defaults.data(forKey: ActiveGpsWorkoutPersistence.metadataKey)))
        XCTAssertEqual(metadata.version, 3)
        XCTAssertEqual(try Data(contentsOf: legacyURL), legacyData, "Old recovery remains intact through migration")
        let migratedURL = directory.appendingPathComponent("active-gps-\(metadata.generation.uuidString.lowercased()).bin")
        XCTAssertEqual(try Data(contentsOf: migratedURL).count, 3 * ActiveGpsJournalCodec.bytesPerPoint)
        var broken = try Data(contentsOf: migratedURL)
        broken[0] ^= 1
        try broken.write(to: migratedURL)
        let recovered = try XCTUnwrap(ActiveGpsWorkoutPersistence.JournalWriter(defaults: defaults, directory: directory).load())
        XCTAssertEqual(recovered.acceptedPointCount, 2, "Checksum failure falls back to v2 recovery")
        XCTAssertNil(recovered.pointMeasurements)
    }

    func testFailedV2MigrationLeavesOriginalJournalAndMetadataReadable() throws {
        let (defaults, directory) = try environment()
        let (sessionID, legacyURL, legacyData) = try seedV2Journal(defaults: defaults, directory: directory)
        let writer = ActiveGpsWorkoutPersistence.JournalWriter(defaults: defaults, directory: directory,
            faultInjector: { phase in
                if case .beforeMetadataCommit = phase { throw CocoaError(.fileWriteUnknown) }
            })
        let legacy = try XCTUnwrap(writer.load())
        let checkpoint = ActiveGpsWorkoutPersistence.Checkpoint(sessionID: sessionID, workoutStartMs: start,
            appendedPoints: [], distanceM: legacy.distanceM, rawFixCount: 2, acceptedPointCount: 2,
            recordingWasActive: true, hadTerminatedGap: true)
        XCTAssertFalse(writer.store(checkpoint, synchronously: true))
        XCTAssertEqual(try Data(contentsOf: legacyURL), legacyData)
        let recovered = ActiveGpsWorkoutPersistence.JournalWriter(defaults: defaults, directory: directory).load()
        XCTAssertEqual(recovered?.segments, legacy.segments)
        XCTAssertNil(recovered?.pointMeasurements)
    }

    private func seedV2Journal(defaults: UserDefaults, directory: URL) throws -> (UUID, URL, Data) {
        let sessionID = UUID()
        let generation = UUID()
        var bytes = Data()
        for (index, point) in points.enumerated() {
            bytes.append(index == 0 ? 1 : 0)
            var lat = point.latitude.bitPattern.littleEndian
            var lon = point.longitude.bitPattern.littleEndian
            withUnsafeBytes(of: &lat) { bytes.append(contentsOf: $0) }
            withUnsafeBytes(of: &lon) { bytes.append(contentsOf: $0) }
        }
        let url = directory.appendingPathComponent("active-gps-\(generation.uuidString.lowercased()).bin")
        try bytes.write(to: url)
        let checksum = bytes.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        let checkpoint = ActiveGpsWorkoutPersistence.Checkpoint(sessionID: sessionID, workoutStartMs: start,
            appendedPoints: [], distanceM: route.distanceM, rawFixCount: 2, acceptedPointCount: 2,
            recordingWasActive: true, hadTerminatedGap: false)
        let metadata = ActiveGpsWorkoutPersistence.JournalMetadata(checkpoint: checkpoint, generation: generation, checksum: checksum)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
        object["version"] = 2
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: ActiveGpsWorkoutPersistence.metadataKey)
        return (sessionID, url, bytes)
    }
}

// MARK: - Recorder integration (requires CoreLocation)

@MainActor
final class WorkoutRouteExportRecorderTests: XCTestCase {
    private final class LocationManager: CLLocationManager {
        override var authorizationStatus: CLAuthorizationStatus { .authorizedWhenInUse }
        override var accuracyAuthorization: CLAccuracyAuthorization { .fullAccuracy }
        override func startUpdatingLocation() {}
        override func stopUpdatingLocation() {}
        override class func locationServicesEnabled() -> Bool { true }
    }

    private let start: Int64 = 1_735_689_600_000

    private func fix(latitude: Double, offset: Double, accuracy: Double = 5) -> CLLocation {
        CLLocation(coordinate: .init(latitude: latitude, longitude: -0.12), altitude: 0,
                   horizontalAccuracy: accuracy, verticalAccuracy: -1,
                   timestamp: Date(timeIntervalSince1970: Double(start) / 1_000 + offset))
    }

    func testPauseResumePersistsExactMeasurementsAndRejectsCachedFixes() throws {
        let manager = LocationManager()
        let recorder = GpsWorkoutRecorder(manager: manager, makeBackgroundActivity: { nil })
        recorder.start(startMs: start)
        recorder.locationManager(manager, didUpdateLocations: [fix(latitude: 51.5, offset: -1),
            fix(latitude: 51.5, offset: 0.125), fix(latitude: 51.5001, offset: 10.125)])
        recorder.setPaused(true)
        recorder.locationManager(manager, didUpdateLocations: [fix(latitude: 51.7, offset: 15)])
        recorder.setPaused(false)
        recorder.locationManager(manager, didUpdateLocations: [fix(latitude: 51.50005, offset: 5),
            fix(latitude: 52, offset: 120.125), fix(latitude: 52.0001, offset: 130.125)])
        let route = try XCTUnwrap(recorder.capturedRoute())
        XCTAssertEqual(route.pointSegments?.map(\.count), [2, 2])
        XCTAssertEqual(route.pointSegments?.flatMap { $0 }.map(\.timestampMs),
                       [start + 125, start + 10_125, start + 120_125, start + 130_125])
        XCTAssertTrue(route.hasExportableMeasurements)
        XCTAssertLessThan(route.distanceM, 30)
        recorder.stop()
        recorder.locationManager(manager, didUpdateLocations: [fix(latitude: 53, offset: 140)])
        XCTAssertEqual(recorder.capturedRoute(), route, "Stopped/cancelled recording cannot collect more points")
        recorder.start(startMs: start + 200_000)
        XCTAssertNil(recorder.capturedRoute(), "A fresh workout cannot export a discarded route")
        recorder.stop()
    }

    func testLegacyRecoveryKeepsMapAndExportsOnlyNewMeasuredSegment() throws {
        let manager = LocationManager()
        let recorder = GpsWorkoutRecorder(manager: manager, makeBackgroundActivity: { nil })
        let old = [RouteMath.LatLng(51.5, -0.12), RouteMath.LatLng(51.5001, -0.12)]
        recorder.restore(.init(sessionID: UUID(), workoutStartMs: start, segments: [old],
            distanceM: RouteMath.totalMeters(old), rawFixCount: 2,
            recordingWasActive: true, hadTerminatedGap: false))
        XCTAssertFalse(try XCTUnwrap(recorder.capturedRoute()).hasExportableMeasurements)
        recorder.locationManager(manager, didUpdateLocations: [fix(latitude: 52, offset: 120),
                                                               fix(latitude: 52.0001, offset: 130)])
        let route = try XCTUnwrap(recorder.capturedRoute())
        XCTAssertEqual(route.decodedSegments.map(\.count), [2, 2])
        XCTAssertEqual(route.pointSegments?.map(\.count), [2])
        XCTAssertEqual(route.pointSegments?.first?.first?.timestampMs, start + 120_000)
        XCTAssertTrue(route.hasUnmeasuredSegments)
        recorder.stop()
    }

    func testBadAccuracyAndZeroPointsNeverCreateAnExport() {
        let manager = LocationManager()
        let recorder = GpsWorkoutRecorder(manager: manager, makeBackgroundActivity: { nil })
        recorder.start(startMs: start)
        XCTAssertNil(recorder.capturedRoute())
        recorder.locationManager(manager, didUpdateLocations: [fix(latitude: 51.5, offset: 1, accuracy: .nan),
            fix(latitude: 51.5001, offset: 10, accuracy: -1)])
        XCTAssertEqual(recorder.pointCount, 0)
        XCTAssertNil(recorder.capturedRoute())
        recorder.stop()
    }
}
