// Add inside Repository.swift. This closes publish-before-save and analysis-to-snapshot replay races.

import Foundation
import NoopPhase34Core
import WhoopStore

/*
Add one structured commit method:

    func commitVerifiedTodaySnapshot(
        candidate: TodayHealthSnapshot,
        work: HistoricalAnalysisWork,
        analysis: AnalysisMutationReceipt,
        verifyStored: @MainActor (TodayHealthSnapshot, AnalysisMutationReceipt) async -> Bool
    ) async throws -> SnapshotCommitReceipt {
        guard let store = await ensureStore(),
              candidate.context == todayHealthSnapshotContext,
              candidate.schemaVersion == TodayHealthSnapshot.currentSchemaVersion,
              work.scope.databaseInstanceId == candidate.context?.databaseInstanceId,
              work.lastReceiptGeneration == analysis.throughReceiptGeneration,
              work.affectedDays.isSubset(of: analysis.analyzedDays) else {
            throw VerifiedTodaySnapshotCommitError.invalidContext
        }

        // A process may have died after the verified mapping committed but before the work-state event.
        // Return that exact mapping instead of assigning another snapshot generation.
        if let existing = try await store.verifiedSnapshotCommit(
            contextId: candidate.context!.identifier,
            analysisGeneration: analysis.analysisGeneration
        ) {
            guard existing.throughReceiptGeneration == analysis.throughReceiptGeneration,
                  existing.analyzedDays == analysis.analyzedDays else {
                throw VerifiedTodaySnapshotCommitError.conflictingReplay
            }
            return existing
        }

        // For historical-only work, compare the candidate presentation identity with the last committed
        // projection. When current Today did not change, reuse its committed snapshot generation and create
        // only a new analysis -> snapshot mapping. HealthKit still receives the new exact analyzed days.
        if let currentProjection = verifiedHealthProjection,
           currentProjection.presentationIdentity == candidatePresentationIdentity(candidate) {
            let receipt = try SnapshotCommitReceipt(
                throughReceiptGeneration: analysis.throughReceiptGeneration,
                analysisGeneration: analysis.analysisGeneration,
                snapshotGeneration: currentProjection.generation,
                analyzedDays: analysis.analyzedDays,
                projection: currentProjection
            )
            return try await store.recordVerifiedSnapshotCommit(receipt, now: Date())
        }

        // saveTodayHealthSnapshot assigns the snapshot-generation domain. Do not publish `candidate` first.
        guard try await store.saveTodayHealthSnapshot(candidate),
              let stored = try await store.todayHealthSnapshot(scopeId: candidate.scopeId),
              stored.context == candidate.context,
              stored.schemaVersion == TodayHealthSnapshot.currentSchemaVersion,
              await verifyStored(stored, analysis) else {
            throw VerifiedTodaySnapshotCommitError.readBackVerificationFailed
        }

        let projection = try VerifiedHealthProjectionBuilder.build(from: stored)
        let receipt = try SnapshotCommitReceipt(
            throughReceiptGeneration: analysis.throughReceiptGeneration,
            analysisGeneration: analysis.analysisGeneration,
            snapshotGeneration: stored.generation,
            analyzedDays: analysis.analyzedDays,
            projection: projection
        )
        return try await store.recordVerifiedSnapshotCommit(receipt, now: Date())
    }

The verifier must check the exact persisted score rows and snapshot evidence produced by the analysis:

- Recovery: correct wake day/source/algorithm, coverage gates passed, persisted value reads back.
- Strain: version 2, current physiological day, required raw frontier consumed, no partial-stream regression.
- Sleep: canonical source precedence, correct wake day, duration and score independently authoritative.
- Explicit unavailable state: successful complete read only. A read error remains unknown.

Change `enrichAndPersistTodayHealthSnapshot` in the audited branch:

CURRENT ORDER (remove):

    let resolved = ...
    publishTodayHealthSnapshot(resolved, persist: false)
    try await store.saveTodayHealthSnapshot(resolved)
    let stored = try await store.todayHealthSnapshot(...)
    publishTodayHealthSnapshot(stored, persist: false)

REQUIRED ORDER:

    let resolved = ...
    guard try await store.saveTodayHealthSnapshot(resolved) else { ... }
    guard let stored = try await store.todayHealthSnapshot(...) else { ... }
    publishTodayHealthSnapshot(stored, persist: false)

On save/read-back failure, retain the last committed in-memory snapshot and mark the writer dirty. Do not publish
the uncommitted candidate. Initial hydration still paints the last committed snapshot immediately.
*/

enum VerifiedTodaySnapshotCommitError: Error {
    case invalidContext
    case conflictingReplay
    case readBackVerificationFailed
}
