import XCTest
import StrandDesign
@testable import NOOP

final class PaperIntegrationContractTests: XCTestCase {
    func testWidgetPublicationUsesCanonicalThreeScoreScales() {
        let snapshot = WidgetSnapshot.publishing(
            recovery: 49.6,
            storedStrain: 67,
            sleepScore: 85.6,
            bpm: 58,
            batteryPct: 83.6,
            bonded: true,
            hrv: 63.7,
            restingHr: 52,
            updated: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(snapshot.recovery, 50)
        XCTAssertEqual(snapshot.effort ?? -1, 14.07, accuracy: 0.0001)
        XCTAssertEqual(snapshot.rest, 86)
        XCTAssertEqual(snapshot.bpm, 58)
        XCTAssertEqual(snapshot.batteryPct, 84)
        XCTAssertEqual(snapshot.hrv, 64)
        XCTAssertEqual(snapshot.restingHr, 52)
    }

    func testOldWidgetSnapshotDecodesWithNewFieldsUnavailable() throws {
        struct Legacy: Encodable {
            let recovery: Int?; let bpm: Int?; let batteryPct: Int?; let bonded: Bool; let updated: Date
            let effort: Double?; let rest: Int?; let hrv: Int?; let restingHr: Int?
        }
        let data = try JSONEncoder().encode(Legacy(
            recovery: 70, bpm: 61, batteryPct: 80, bonded: true, updated: .distantPast,
            effort: 8.4, rest: 82, hrv: 60, restingHr: 51))
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        XCTAssertEqual(decoded.strain, 8.4)
        XCTAssertNil(decoded.steps)
        XCTAssertNil(decoded.hourlyStress)
        XCTAssertNil(decoded.hrSparkline)
        XCTAssertNil(decoded.hrvSparkline)
    }

    func testFastWidgetMergePreservesSlowDashboardFieldsAndBoundsTrace() {
        let slow = WidgetSnapshot(
            recovery: 70, bpm: 50, batteryPct: 80, bonded: true, updated: .distantPast,
            effort: 7, rest: 82, hrv: 60, restingHr: 51, recoveryDelta: 4,
            sleepMinutes: 470, steps: 9_123, calories: 640,
            hourlyStress: [nil, 1.2], stressSummary: "Moderate",
            hrvSparkline: Array(40...60))
        let live = slow.mergingLive(
            bpm: 120, batteryPct: 63.6, bonded: false, storedStrain: 100,
            hrSparkline: Array(repeating: 90, count: 60) + [400])
        XCTAssertEqual(live.steps, 9_123)
        XCTAssertEqual(live.stressSummary, "Moderate")
        XCTAssertEqual(live.batteryPct, 64)
        XCTAssertEqual(live.strain ?? -1, 21, accuracy: 0.0001)
        XCTAssertEqual(live.hrSparkline?.count, 48)
        XCTAssertFalse(live.hrSparkline?.contains(400) ?? true)
        XCTAssertEqual(live.hrvSparkline?.count, 12)
        XCTAssertEqual(live.hrvSparkline?.last, 60)
    }

    func testWidgetSnapshotBoundsHRVHistoryWithoutFabricatingValues() {
        let snapshot = WidgetSnapshot(
            recovery: nil, bpm: nil, batteryPct: nil, bonded: false, updated: .distantPast,
            hrvSparkline: [2, 41, 48, 55, 301] + Array(repeating: 60, count: 20))
        XCTAssertEqual(snapshot.hrvSparkline?.count, 12)
        XCTAssertFalse(snapshot.hrvSparkline?.contains(2) ?? true)
        XCTAssertFalse(snapshot.hrvSparkline?.contains(301) ?? true)
    }

    func testLegacyLiveActivityDecodesAsSimpleLiveHR() throws {
        struct Legacy: Encodable { let bpm: Int?; let recovery: Int?; let bonded: Bool; let effort: Double? }
        let data = try JSONEncoder().encode(Legacy(bpm: 72, recovery: 80, bonded: true, effort: 4.2))
        let decoded = try JSONDecoder().decode(NOOPActivityAttributes.ContentState.self, from: data)
        XCTAssertFalse(decoded.isWorkout)
        XCTAssertNil(decoded.sport)
        XCTAssertEqual(decoded.effort, 4.2)
    }

    func testWorkoutActivityBoundsTraceAndZonesWithoutTurningBuildingIntoZero() {
        let state = NOOPActivityAttributes.ContentState(
            bpm: 140, recovery: 80, bonded: true, effort: nil,
            sport: "Run", workoutStartedAt: Date(), strainBuilding: true, calories: 120,
            hrTrace: Array(repeating: 120, count: 60) + [999], zoneSeconds: [1, 2, 3, 4, 5, 6])
        XCTAssertTrue(state.isWorkout)
        XCTAssertTrue(state.strainBuilding == true)
        XCTAssertNil(state.effort)
        XCTAssertEqual(state.hrTrace?.count, 48)
        XCTAssertEqual(state.zoneSeconds, [1, 2, 3, 4, 5])
    }

    func testPaperLocalizationCatalogsContainNoLegacyPillarKeys() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogs = [
            "Strand/Resources/Localizable.xcstrings",
            "Packages/StrandDesign/Sources/StrandDesign/Resources/Localizable.xcstrings",
        ]
        let legacyPillar = try NSRegularExpression(
            pattern: #"(^|[^A-Za-z])(Charge|Effort|EFFORT)([^A-Za-z]|$)"#
        )

        for relativePath in catalogs {
            let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(relativePath))
            let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
            XCTAssertFalse(strings.isEmpty, "Empty localization catalog: \(relativePath)")
            for key in strings.keys {
                let range = NSRange(key.startIndex..., in: key)
                XCTAssertNil(
                    legacyPillar.firstMatch(in: key, range: range),
                    "Legacy Paper pillar key in \(relativePath): \(key)"
                )
            }
        }
    }
}
