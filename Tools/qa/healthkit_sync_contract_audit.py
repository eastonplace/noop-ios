#!/usr/bin/env python3
"""Source-level guardrails for lossless, bounded, and generation-stable HealthKit ingestion."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]


def text(path: str) -> str:
    file = ROOT / path
    if not file.exists():
        raise AssertionError(f"missing required file: {path}")
    return file.read_text(encoding="utf-8")


def require(path: str, *markers: str) -> None:
    source = text(path)
    for marker in markers:
        if marker not in source:
            raise AssertionError(f"{path}: missing contract marker {marker!r}")


def require_order(path: str, *markers: str) -> None:
    source = text(path)
    cursor = 0
    for marker in markers:
        index = source.find(marker, cursor)
        if index < 0:
            raise AssertionError(
                f"{path}: missing or misordered contract marker {marker!r} after offset {cursor}"
            )
        cursor = index + len(marker)


def require_regex(path: str, pattern: str, description: str) -> None:
    if re.search(pattern, text(path), flags=re.MULTILINE | re.DOTALL) is None:
        raise AssertionError(f"{path}: missing {description}")


def forbid(path: str, *markers: str) -> None:
    source = text(path)
    for marker in markers:
        if marker in source:
            raise AssertionError(f"{path}: forbidden stale marker {marker!r}")


try:
    coordinator = "StrandiOS/Health/HealthKitSyncCoordinator.swift"
    require(
        coordinator,
        "final class HealthKitSyncCoordinator",
        "final class HealthKitScoringCoordinator: NSObject",
        "func withImportLease",
        "await acquireLease(.scoring)",
        "guard revision == snapshotRevision else { continue }",
        "try scoringCoordinator.offer(snapshot)",
        "final class HealthKitAnchorPager",
        "static let defaultPageLimit = 500",
        "oldestSampleDate",
        "maximumPageCount",
        "deletedObjectUUIDs",
        "handlePage: PageHandler? = nil",
    )
    # The scoring dependency must be durable before the importer starts awaiting HealthKit/store work.
    require_order(
        coordinator,
        "await scoringCoordinator.withImportLease",
        "try scoringCoordinator.offer(snapshot)",
        "guard await operation(snapshot)",
        "try persistence.save(nil)",
    )
    # A publication-sensitive analysis call must return the actual completion status, never Void.
    require_regex(
        "Strand/Data/IntelligenceAnalysisCoordinator.swift",
        r"func\s+analyzeRecent\(\s*maxDays:\s*Int,\s*startOffset:\s*Int,\s*"
        r"refreshRepository:\s*Bool\s*\)\s*async\s*->\s*Bool",
        "Bool-returning three-label analyzeRecent overload",
    )

    bridge = "StrandiOS/Health/HealthKitBridge.swift"
    require(
        bridge,
        "try syncCoordinator.offer(window)",
        "try Self.saveAnchor(scan.finalAnchor, forKey: key)",
        "syncCoordinator.start()",
        "await syncCoordinator.runAndWait()",
        "await acquireObserverScanLease()",
        "defer { releaseObserverScanLease() }",
        "healthKitObjectIdentities",
        "upsertHealthKitObjectIdentities",
        "replaceAppleHealthRange",
        "var hasUnknownHistoricalDeletion = false",
        "historyQueryChunkDays = 1",
        "streamWorkouts",
        "roundedInt(_ value: Double, in domain: ClosedRange<Int>)",
        "Live HealthKit import owns daily Apple projections and Apple workouts only",
        "readTypes.compactMap { $0 as? HKSampleType }",
    )
    forbid(
        bridge,
        "_ = await repo.refresh(.recentDashboard(days: 120))",
    )

    app = "StrandiOS/App/StrandiOSApp.swift"
    require(
        app,
        "HealthKitScoringCoordinator.shared.runAndWait(",
        "analyze: { window in",
        "publish: { window in",
        "await health.foregroundCatchUp()",
        "await drainCommittedHealthScoring()",
    )
    forbid(
        app,
        "HealthKitScoringCoordinator.runAnalysisThenPublish(",
    )

    require(
        "Packages/WhoopStore/Sources/WhoopStore/HealthKitAuthoritativeStore.swift",
        "struct HealthKitObjectIdentity",
        "healthKitObjectIndex",
        "earliestAppleHealthTimestamp",
        "replaceAppleHealthRange",
        "Empty inputs are meaningful",
        "MIN(healthKitObjectIndex.startTs, excluded.startTs)",
        "MAX(healthKitObjectIndex.endTs, excluded.endTs)",
        'appleHealthWorkoutSource = "apple-health"',
        "healthKitIdentityQueryChunkSize = 400",
        "return requested.compactMap",
    )
    forbid(
        bridge,
        "guard auth == .authorized, !syncing else { return }",
        "anchor: priorAnchor, limit: HKObjectQueryNoLimit",
        "fetchTouchedDayWindow",
        "objectUUIDs: scan.deletedObjectUUIDs",
    )

    require(
        "StrandiOSTests/HealthKitSyncCoordinatorTests.swift",
        "testObserverBWidensImportAndPublishesOneDurableScoringUnion",
        "testFailedAggregationSurvivesRelaunchAndLeavesDurableScoringWork",
        "testAnalysisFailureDoesNotPublishDerivedSurfaces",
        "testSuccessfulAnalysisPublishesExactlyOnceAfterAnalysis",
        "testPendingPersistenceFailureDoesNotStartOrLoseInMemoryWork",
        "testInitialLargeHistoryIsPagedInBoundedBatches",
        "testPagingFailureDoesNotProduceACommittableFinalAnchor",
    )
    require(
        "StrandiOSTests/HealthKitPipelineSerializationTests.swift",
        "testRevisionAdvanceDuringAnalysisSkipsTheOlderPublication",
        "testImportLeaseExcludesWritesUntilPublicationFinishes",
        "testFailedImportStillLeavesDurableScoringWork",
        "testWidenedImportCompletesBeforeAnyScoringPublication",
    )
    require(
        "StrandiOSTests/IntelligenceAnalysisPublicationContractTests.swift",
        "testThreeLabelPublicationOverloadReturnsCompletionStatus",
    )
    require(
        "Packages/WhoopStore/Tests/WhoopStoreTests/HealthKitAuthoritativeStoreTests.swift",
        "testObjectIndexRetainsHistoricalWindowUnionAcrossCorrections",
        "testObjectIndexChunksMassDeletionLookupsAndPreservesDuplicateRequests",
        "testEarliestAppleHealthTimestampIncludesHyphenatedWorkoutSource",
        "testEmptyAuthoritativeWindowRetractsAppleRowsAndWorkouts",
    )
except AssertionError as error:
    print(f"HealthKit sync contract audit: FAIL\n{error}", file=sys.stderr)
    raise SystemExit(1)

print("HealthKit sync contract audit: PASS")
