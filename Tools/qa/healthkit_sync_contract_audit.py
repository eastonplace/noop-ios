#!/usr/bin/env python3
"""Source-level guardrails for lossless and bounded HealthKit observer ingestion."""
from pathlib import Path
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


def forbid(path: str, *markers: str) -> None:
    source = text(path)
    for marker in markers:
        if marker in source:
            raise AssertionError(f"{path}: forbidden stale marker {marker!r}")


try:
    require(
        "StrandiOS/Health/HealthKitSyncCoordinator.swift",
        "final class HealthKitSyncCoordinator",
        "try persistence.save(widened)",
        "guard revision == snapshotRevision else { continue }",
        "final class HealthKitAnchorPager",
        "static let defaultPageLimit = 500",
        "oldestSampleDate",
        "maximumPageCount",
        "deletedObjectUUIDs",
        "handlePage: PageHandler? = nil",
    )
    require(
        "StrandiOS/Health/HealthKitBridge.swift",
        "try syncCoordinator.offer(window)",
        "try Self.saveAnchor(scan.finalAnchor, forKey: key)",
        "syncCoordinator.start()",
        "await syncCoordinator.runAndWait()",
        "await acquireObserverScanLease()",
        "defer { releaseObserverScanLease() }",
        "healthKitObjectIdentities",
        "upsertHealthKitObjectIdentities",
        "replaceAppleHealthRange",
        "readTypes.compactMap { $0 as? HKSampleType }",
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
    )
    forbid(
        "StrandiOS/Health/HealthKitBridge.swift",
        "guard auth == .authorized, !syncing else { return }",
        "anchor: priorAnchor, limit: HKObjectQueryNoLimit",
        "fetchTouchedDayWindow",
    )
    require(
        "StrandiOSTests/HealthKitSyncCoordinatorTests.swift",
        "testObserverBWidensPendingWindowWhileObserverAIsSyncing",
        "testFailedAggregationSurvivesRelaunchAndRetries",
        "testPendingPersistenceFailureDoesNotStartOrLoseInMemoryWork",
        "testInitialLargeHistoryIsPagedInBoundedBatches",
        "testPagingFailureDoesNotProduceACommittableFinalAnchor",
    )
    require(
        "Packages/WhoopStore/Tests/WhoopStoreTests/HealthKitAuthoritativeStoreTests.swift",
        "testObjectIndexRetainsHistoricalWindowUnionAcrossCorrections",
        "testEmptyAuthoritativeWindowRetractsAppleRowsAndWorkouts",
    )
except AssertionError as error:
    print(f"HealthKit sync contract audit: FAIL\n{error}", file=sys.stderr)
    raise SystemExit(1)

print("HealthKit sync contract audit: PASS")
