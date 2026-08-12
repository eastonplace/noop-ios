// Repository integration patch. Verification is durable-only; observable state
// changes once, after every exact cache family is ready.

import Foundation
import NoopPhase34Core
import WhoopStore

public struct DurableVerifiedSnapshotArtifacts: Sendable {
    public let receipt: SnapshotCommitReceipt
    public let snapshot: TodayHealthSnapshot

    public init(receipt: SnapshotCommitReceipt, snapshot: TodayHealthSnapshot) {
        self.receipt = receipt
        self.snapshot = snapshot
    }
}

/// Complete non-observable publication graph. Build this after the exact WAL read and before mutating any
/// Repository property. Keeping one value graph makes the final MainActor assignment non-suspending.
struct HistoricalPublicationPreparedState {
    let exactDays: Set<CivilDay>
    let snapshotReceipt: SnapshotCommitReceipt
    let storedSnapshot: TodayHealthSnapshot
    let days: [DailyMetric]
    let sleeps: [CachedSleepSession]
    let vitals: [SourcedDailyMetric]
    let importedSleep: [String: ImportedSleepFigures]
    let metricSources: [String: Repository.TodayHealthMetricSources]
    let persistedStrain: [String: ResolvedStrain]
    let importedStrain: [String: ResolvedStrain]
    let canonicalHealth: CanonicalHealthReadModel
}

@MainActor
extension Repository {
    /// Validate the durable verification result without publishing it. Call immediately after the existing
    /// snapshot save/read-back and verifiedSnapshotCommit transaction. The existing verification method must
    /// remove its assignments to verifiedHealthProjection/todayHealthSnapshot/revisions and return this value.
    func durableVerifiedSnapshotArtifacts(
        receipt: SnapshotCommitReceipt,
        storedSnapshot: TodayHealthSnapshot
    ) throws -> DurableVerifiedSnapshotArtifacts {
        guard storedSnapshot.generation == receipt.snapshotGeneration,
              storedSnapshot.context?.identifier == receipt.projection.contextId,
              storedSnapshot.scopeId == todayHealthSnapshotScopeId else {
            throw PR28HistoricalPipelineError.snapshotReadBackFailed
        }
        return DurableVerifiedSnapshotArtifacts(receipt: receipt, snapshot: storedSnapshot)
    }

    /// Final publication seam. Integrate this call at the end of publishVerifiedExactDays after all exact
    /// replacement values and the durable snapshot read-back are ready. No await may occur inside this method.
    func commitHistoricalPresentationAtomically(
        _ prepared: HistoricalPublicationPreparedState
    ) throws -> RepositoryRefreshOutcome {
        let receipt = prepared.snapshotReceipt
        let storedSnapshot = prepared.storedSnapshot
        guard storedSnapshot.generation == receipt.snapshotGeneration,
              storedSnapshot.context?.identifier == receipt.projection.contextId,
              receipt.analyzedDays == prepared.exactDays else {
            throw CanonicalRepositoryPublicationError.databaseChanged
        }

        let snapshotPresentationChanged = todayHealthSnapshot.map {
            !$0.hasSamePresentation(as: storedSnapshot)
        } ?? true
        let presentationChanged = prepared.days != days
            || prepared.sleeps != sleeps
            || prepared.vitals != vitalRows
            || prepared.importedSleep != importedSleep
            || prepared.metricSources != todayHealthMetricSources
            || prepared.persistedStrain != persistedStrainByDay
            || prepared.importedStrain != importedStrainByDay
            || prepared.canonicalHealth.presentationRevision
                != canonicalHealth.presentationRevision
            || receipt.projection.presentationIdentity
                != verifiedHealthProjection?.presentationIdentity
            || snapshotPresentationChanged
            || !loaded

        // One non-suspending MainActor turn: no surface can observe a new headline
        // generation while Sleep/Trends/detail caches remain old.
        days = prepared.days
        sleeps = prepared.sleeps
        vitalRows = prepared.vitals
        importedSleep = prepared.importedSleep
        todayHealthMetricSources = prepared.metricSources
        persistedStrainByDay = prepared.persistedStrain
        importedStrainByDay = prepared.importedStrain
        canonicalHealth = prepared.canonicalHealth
        todayHealthSnapshot = storedSnapshot
        verifiedHealthProjection = receipt.projection
        verifiedExternalSurfaceFenced = false
        rebuildCanonicalStrain()
        loaded = true

        if snapshotPresentationChanged {
            todayHealthSnapshotRevision &+= 1
        }
        if presentationChanged {
            refreshSeq &+= 1
        }
        return RepositoryRefreshOutcome(
            authoritativeDataPublished: true,
            changedDays: prepared.exactDays,
            snapshotStatus: .persisted
        )
    }
}

/*
Mechanical integration:

1. Keep the current WAL read, HealthKit payload build, snapshot save/read-back,
   projection construction, and verifiedSnapshotCommit mapping in
   `buildAndCommitVerifiedHistoricalSnapshot`.
2. Delete these assignments from that verification method:

       verifiedHealthProjection = committed.projection
       todayHealthSnapshot = stored
       todayHealthSnapshotRevision &+= 1

3. Return `durableVerifiedSnapshotArtifacts(receipt:storedSnapshot:)` instead.
4. In publishVerifiedExactDays, build HistoricalPublicationPreparedState and call
   commitHistoricalPresentationAtomically exactly once after every async read.
5. Resume paths load both receipt and stored snapshot, then use the same final seam.
*/
