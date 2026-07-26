#!/usr/bin/env python3
"""Source-level guardrails for active-workout recovery persistence."""
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
        "Strand/App/ActiveWorkoutPersistence.swift",
        "ActiveWorkoutSampleJournalCodec",
        "bytesPerSample = MemoryLayout<Int64>.size + MemoryLayout<Int32>.size",
        "ActiveWorkoutJournalPlanner",
        "active-workout-\\(generation.uuidString.lowercased()).bin",
        "ProductionJournalWriter",
        "case appendFinalized(expectedCount: Int, expectedLast: HRSample?, suffix: [HRSample], tail: HRSample?)",
        "let finalizedCount = max(0, copied.count - 1)",
        "tail: tail",
        "completeFileProtectionUntilFirstUserAuthentication",
        "let generation: UUID",
        "let sessionID: UUID",
        "let checksum: UInt64",
        "struct JournalSegment",
        "static let currentVersion = 5",
        "let segments: [JournalSegment]",
        "let journalSampleCount: Int?",
        "let tailSample: HRSample?",
        "appendDurably",
        "truncatingTo",
        "enqueueLatest",
        "private func merge",
        "onCommit: (@Sendable (Bool) -> Void)? = nil",
        "previousMetadataKey",
        "encodedByteCount(for sampleCount: Int)",
        "private var committedCursor: Cursor?",
        "private var pendingCursor: Cursor?",
        "try handle.synchronize()",
        "defaults.synchronize()",
        "faultInjector(.beforeMetadataCommit)",
        "productionWriter.store(",
        "epoch &+= 1",
    )
    require(
        "Strand/App/AppModel.swift",
        "if accepted {",
        "lastWorkoutSnapshotAt = now",
        "lastWorkoutSnapshotEnqueuedAt",
        "latestWorkoutSnapshotAttempt",
        "onCommit: { [weak self] committed in",
        "workoutDurabilityWarning = nil",
        "persistActiveWorkout(force: true, synchronously: true)",
        "func flushActiveWorkoutSnapshot() -> Bool",
    )
    forbid(
        "Strand/App/ActiveWorkoutPersistence.swift",
        "private static let writer = SnapshotWriter()",
        "let old = try Data(contentsOf: journalURL(for: previous.generation)",
        "case append(expectedCount: Int, expectedLast: HRSample?, suffix: [HRSample])",
    )
    require(
        "StrandiOSTests/ActiveWorkoutPersistenceTests.swift",
        "testBinaryJournalRoundTripsLargeSampleSetAtFixedWidth",
        "testJournalPlannerAppendsOnlyNewSuffixForCompatibleSession",
        "testJournalPlannerRewritesOnReplacementShrinkOrPrefixCorrection",
        "testGenerationJournalCommitsMetadataPointerAndChecksum",
        "testIncrementalCheckpointsUseBoundedAppendOnlyJournalAndReplaceableTail",
        "testSameSecondReplacementStaysInMetadataUntilThatSecondFinalizes",
        "testAsynchronousCheckpointPublishesActualCommitFailure",
        "testSynchronousWriteReportsFailureBeforeCommitAndRelaunchKeepsPreviousGeneration",
        "testRelaunchUsesNewGenerationWhenProcessDiesAfterPointerSwap",
        "testEncodedByteCountRejectsOverflow",
        "testChecksumMismatchRecoversPreviousCommittedGeneration",
        "testV3GenerationJournalMigratesToImmutableSuffixSegments",
        "testLegacyV2PairMigratesToGenerationJournalOnLoad",
    )
except AssertionError as error:
    print(f"Workout persistence contract audit: FAIL\n{error}", file=sys.stderr)
    raise SystemExit(1)

print("Workout persistence contract audit: PASS")
