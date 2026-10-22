import HealthKit
import XCTest
import WhoopStore
@testable import NOOP

#if os(iOS)
@MainActor
final class HealthKitReadProjectionEvidenceTests: XCTestCase {
    func testLegacyWindowDecodesWithoutInventingDeletionEvidence() throws {
        let legacy = Data("{\"start\":1000,\"end\":2000}".utf8)
        let decoded = try JSONDecoder().decode(HealthKitSyncWindow.self, from: legacy)
        XCTAssertTrue(decoded.projectionDeletions.isEmpty)
    }

    func testDeletionEvidenceSurvivesDurableUnionRoundTrip() throws {
        let evidence = HealthKitProjectionDeletion(sampleType: "HKCategoryTypeIdentifierSleepAnalysis",
            fromDay: "2026-10-20", toDay: "2026-10-21", fromTimestamp: 1000, toTimestamp: 2000)
        let pending = HealthKitSyncWindow(start: Date(timeIntervalSince1970: 1000),
            end: Date(timeIntervalSince1970: 2000), projectionDeletions: [evidence])
        let union = pending.union(HealthKitSyncWindow(start: Date(timeIntervalSince1970: 500),
            end: Date(timeIntervalSince1970: 3000)))
        let replay = try JSONDecoder().decode(HealthKitSyncWindow.self, from: JSONEncoder().encode(union))
        XCTAssertEqual(replay.projectionDeletions, [evidence])
    }

    func testObserverAddsDeletionEvidenceOnlyForExternalDeletedObjects() async throws {
        let type = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!
        let start = Date(timeIntervalSince1970: 1_792_454_400)
        let identity = HealthKitObjectIdentity(sampleType: type.identifier, objectUUID: "external",
            startTs: Int(start.timeIntervalSince1970), endTs: Int(start.timeIntervalSince1970) + 60)
        let page = HealthKitAnchorPage(samples: [], deletedObjectUUIDs: ["external", "noop-owned"],
                                      newAnchor: HKQueryAnchor(fromValue: 1))
        let offered = try await HealthKitObserverPageCommit.commit(
            page: page, exportedObjectUUIDs: ["noop-owned"], importedIdentities: [identity],
            initialScan: false, now: start.addingTimeInterval(86_400),
            sampleTypeIdentifier: type.identifier, earliestLocalDate: { nil },
            offer: { _ in }, saveAnchor: { _ in }, retireExports: { _ in })
        let evidence = try XCTUnwrap(offered).projectionDeletions
        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(evidence.first?.sampleType, type.identifier)
        XCTAssertEqual(evidence.first?.fromTimestamp, identity.startTs)
        XCTAssertEqual(evidence.first?.toTimestamp, identity.endTs)
    }

    func testUnknownTombstoneRequeriesButCannotAuthorizeAllHistoryClearing() async throws {
        let type = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!
        let now = Date(timeIntervalSince1970: 1_792_454_400)
        let old = now.addingTimeInterval(-200 * 86_400)
        let page = HealthKitAnchorPage(samples: [], deletedObjectUUIDs: ["unknown-window"],
                                      newAnchor: HKQueryAnchor(fromValue: 1))
        let offered = try await HealthKitObserverPageCommit.commit(
            page: page, exportedObjectUUIDs: [], importedIdentities: [],
            initialScan: false, now: now, sampleTypeIdentifier: type.identifier,
            earliestLocalDate: { old }, offer: { _ in }, saveAnchor: { _ in }, retireExports: { _ in })
        let window = try XCTUnwrap(offered)
        XCTAssertLessThanOrEqual(window.start, old)
        XCTAssertTrue(window.projectionDeletions.isEmpty)
    }

    func testSleepStageTombstoneCannotInventAdjacentEpisodeContributionDays() async throws {
        let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!
        let start = Date(timeIntervalSince1970: 1_792_454_400 + 22 * 3600)
        let identity = HealthKitObjectIdentity(sampleType: type.identifier, objectUUID: "sleep-stage",
            startTs: Int(start.timeIntervalSince1970), endTs: Int(start.timeIntervalSince1970) + 8 * 3600)
        let page = HealthKitAnchorPage(samples: [], deletedObjectUUIDs: [identity.objectUUID],
                                      newAnchor: HKQueryAnchor(fromValue: 1))
        let window = try await HealthKitObserverPageCommit.commit(
            page: page, exportedObjectUUIDs: [], importedIdentities: [identity],
            initialScan: false, now: start.addingTimeInterval(2 * 86_400),
            sampleTypeIdentifier: type.identifier, earliestLocalDate: { nil },
            offer: { _ in }, saveAnchor: { _ in }, retireExports: { _ in })
        XCTAssertNotNil(window, "Keep the source/anchor requery path")
        XCTAssertTrue(try XCTUnwrap(window).projectionDeletions.isEmpty,
                      "Stage bounds do not identify the reduced episode's wake-day contribution")
    }
}
#endif
