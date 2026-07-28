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


def audit_direct_repository_refreshes() -> None:
    """Only the typed executor and exclusive HealthKit publisher may bypass typed refresh admission."""
    allowed = {
        ("Strand/Data/RepositoryRefreshIntent.swift", "await repository.refresh(days: intent.days)"),
        ("StrandiOS/App/StrandiOSApp.swift", "await model.repo.refresh(days: range.publicationDays)"),
    }
    pattern = re.compile(r"\b(?:model\.)?repo\.refresh\s*\(\s*days:|\brepository\.refresh\s*\(\s*days:")
    found: set[tuple[str, str]] = set()

    for root_name in ("Strand", "StrandiOS", "StrandiOSShared"):
        root = ROOT / root_name
        if not root.exists():
            continue
        for file in root.rglob("*.swift"):
            relative = str(file.relative_to(ROOT))
            for line_number, raw_line in enumerate(file.read_text(encoding="utf-8").splitlines(), start=1):
                line = raw_line.strip()
                if line.startswith("//") or not pattern.search(line):
                    continue
                match = next((entry for entry in allowed if entry[0] == relative and entry[1] in line), None)
                if match is None:
                    raise AssertionError(
                        f"{relative}:{line_number}: direct Repository refresh bypasses typed/fenced admission"
                    )
                found.add(match)

    missing = allowed - found
    if missing:
        raise AssertionError(f"missing expected direct Repository refresh owner(s): {sorted(missing)}")


try:
    coordinator = "StrandiOS/Health/HealthKitSyncCoordinator.swift"
    require(
        coordinator,
        "final class HealthKitSyncCoordinator",
        "final class HealthKitScoringCoordinator: NSObject",
        "publicationBarrier: RepositoryPublicationBarrier = .shared",
        "func withImportLease",
        "await ensurePublicationBarrierHeld()",
        "releasePublicationBarrierIfIdle()",
        "await acquireLease(.scoring)",
        "guard revision == snapshotRevision else { continue }",
        "try await scoringCoordinator.offer(snapshot)",
        "final class HealthKitAnchorPager",
        "static let defaultPageLimit = 500",
        "oldestSampleDate",
        "maximumPageCount",
        "deletedObjectUUIDs",
        "handlePage: PageHandler? = nil",
    )
    # The Repository fence and scoring dependency must exist before the importer awaits HealthKit/store work.
    require_order(
        coordinator,
        "await scoringCoordinator.withImportLease",
        "try await scoringCoordinator.offer(snapshot)",
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

    refresh = "Strand/Data/RepositoryRefreshIntent.swift"
    require(
        refresh,
        "final class RepositoryPublicationBarrier",
        "func acquireExclusive() async",
        "func acquireRestoredExclusiveIfIdle() -> Bool",
        "func beginRefreshIfAllowed() -> Bool",
        "func performAfterOpen",
        "guard barrier.beginRefreshIfAllowed() else",
        "barrier.performAfterOpen",
        "await repository.refresh(days: intent.days)",
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
        "await model.repo.refresh(days: range.publicationDays)",
        "await health.foregroundCatchUp()",
        "await drainCommittedHealthScoring()",
    )
    require_order(
        app,
        "_ = HealthKitScoringCoordinator.shared",
        "let model = AppModel()",
    )
    forbid(
        app,
        "HealthKitScoringCoordinator.runAnalysisThenPublish(",
        "model.repo.refresh(.recentDashboard(days: range.publicationDays))",
    )

    audit_direct_repository_refreshes()

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
        "testRestoredScoringJournalClosesPublicationBeforeDrain",
        "testFailedAggregationSurvivesRelaunchAndLeavesDurableScoringWork",
        "testFailedScoringRetainsJournalAndPublicationFenceUntilLaterDrain",
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
        "testFailedImportStillLeavesDurableScoringWorkAndFence",
        "testWidenedImportCompletesBeforeAnyScoringPublication",
    )
    require(
        "StrandiOSTests/RepositoryRefreshIntentTests.swift",
        "testExclusivePublicationWaitsForInFlightRefreshAndStopsNewStarts",
        "testBlockedRefreshCallbackRunsOnlyAfterPublicationFenceOpens",
        "testRestoredJournalCanFenceSynchronouslyBeforeLaunchRefresh",
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
