import Foundation
import XCTest
@testable import NoopPhase34Core

final class VerifiedWidgetCorePayloadRegressionTests: XCTestCase {
    func testLegacyPayloadFallsBackToVerifiedProjectionOwner() throws {
        let day = try CivilDay(key: "2026-08-08")
        let legacy = """
        {
          "version": 1,
          "contextId": "ctx",
          "projectionGeneration": 7,
          "logicalDay": {"year": 2026, "month": 8, "day": 8},
          "restingHR": 51,
          "recoveryDelta": 4
        }
        """.data(using: .utf8)!
        let core = try JSONDecoder().decode(VerifiedWidgetCorePayload.self, from: legacy)
        let projection = try VerifiedHealthProjection(
            contextId: "ctx",
            deviceId: "source-A",
            generation: 7,
            logicalDay: day,
            metrics: [:]
        )
        let bundle = try VerifiedExternalProjectionBundle(projection: projection, widgetCore: core)

        XCTAssertEqual(core.recoveryDelta, 4)
        XCTAssertNil(core.recordedTimeZoneIdentifier)
        XCTAssertEqual(core.enrichmentSourceIds, [])
        XCTAssertEqual(bundle.verifiedEnrichmentSourceIds, ["source-A"])
    }

    func testEnrichmentSourceSetIsNormalizedAndStable() throws {
        let day = try CivilDay(key: "2026-08-08")
        let core = try VerifiedWidgetCorePayload(
            contextId: "ctx",
            projectionGeneration: 7,
            logicalDay: day,
            restingHR: nil,
            sleepMinutes: nil,
            steps: nil,
            calories: nil,
            recoveryDelta: -3,
            recordedTimeZoneIdentifier: "America/New_York",
            enrichmentSourceIds: [" source-A ", "source-A", "source-A-noop", ""]
        )
        let projection = try VerifiedHealthProjection(
            contextId: "ctx",
            deviceId: "source-A",
            generation: 7,
            logicalDay: day,
            metrics: [:]
        )
        let bundle = try VerifiedExternalProjectionBundle(projection: projection, widgetCore: core)

        XCTAssertEqual(bundle.verifiedEnrichmentSourceIds, ["source-A", "source-A-noop"])
        XCTAssertEqual(core.recordedTimeZoneIdentifier, "America/New_York")
    }
}
