import Foundation
import WhoopStore

/// The observable result of one bounded durable-receipt drain.
///
/// A deferred scope stays durable and unacknowledged. It is deliberately not treated as success: a later
/// launch or finalized burst must be able to retry the exact staged target.
struct HistoricalReceiptAnalysisDrainResult: Equatable, Sendable {
    let acknowledgedReceiptCount: Int
    let analysisRunCount: Int
    let deferredScopeCount: Int
    let isAlreadyDraining: Bool

    static let idle = HistoricalReceiptAnalysisDrainResult(
        acknowledgedReceiptCount: 0,
        analysisRunCount: 0,
        deferredScopeCount: 0,
        isAlreadyDraining: false
    )

    static let alreadyDraining = HistoricalReceiptAnalysisDrainResult(
        acknowledgedReceiptCount: 0,
        analysisRunCount: 0,
        deferredScopeCount: 0,
        isAlreadyDraining: true
    )

    var didAdvance: Bool { acknowledgedReceiptCount > 0 }
}

/// Durable, source-scoped handoff from historical commit receipts to exact analysis runs.
///
/// The consumer has two durable edges: it first stages a Codable plan against one exact receipt, then it
/// acknowledges that same receipt only after every exact run succeeds. This makes a process kill, a failed
/// analysis, or a retry safe without expanding the work to a broad "last N days" sweep.
@MainActor
final class HistoricalReceiptAnalysisConsumer {
    static let consumerId = "noop.exact-historical-analysis.v1"

    typealias StoreProvider = @MainActor () async -> WhoopStore?
    typealias ScopeIsCurrent = @MainActor (WhoopStore, HistoricalCursorScope) async -> Bool
    typealias ExecuteRun = @MainActor (CommittedAnalysisRun, CommittedAnalysisExecutionContext) async -> Bool
    typealias TimeZoneProvider = @MainActor () -> TimeZone
    typealias NowProvider = @MainActor () -> Date

    private static let receiptLimit = 100
    private static let maximumBatchesPerDrain = 16

    private struct PendingPayload: Codable, Equatable {
        static let version = 1

        let version: Int
        let plan: HistoricalReceiptAnalysisPlan
        let timeZoneIdentifier: String

        init(plan: HistoricalReceiptAnalysisPlan, calendar: Calendar) throws {
            guard calendar.identifier == .gregorian,
                  let timeZone = TimeZone(identifier: calendar.timeZone.identifier) else {
                throw ConsumerError.invalidPayload
            }
            self.version = Self.version
            self.plan = plan
            self.timeZoneIdentifier = timeZone.identifier
        }

        func calendar() throws -> Calendar {
            guard version == Self.version,
                  let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
                throw ConsumerError.invalidPayload
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            return calendar
        }
    }

    private struct ResolvedWork {
        let receipt: HistoricalDataCommitReceipt
        let plan: HistoricalReceiptAnalysisPlan
        let calendar: Calendar
    }

    private enum ScopeResult {
        case acknowledged(runCount: Int)
        case deferred
    }

    private enum ConsumerError: Error {
        case invalidPayload
        case targetReceiptMissing
        case targetReceiptMismatch
        case analysisDidNotComplete
        case scopeNoLongerCurrent
        case cancelled
    }

    private let storeProvider: StoreProvider
    private let scopeIsCurrent: ScopeIsCurrent
    private let executeRun: ExecuteRun
    private let timeZoneProvider: TimeZoneProvider
    private let now: NowProvider
    private var isDraining = false
    private var rerunRequested = false

    init(
        storeProvider: @escaping StoreProvider,
        scopeIsCurrent: @escaping ScopeIsCurrent,
        executeRun: @escaping ExecuteRun,
        timeZoneProvider: @escaping TimeZoneProvider = { .current },
        now: @escaping NowProvider = Date.init
    ) {
        self.storeProvider = storeProvider
        self.scopeIsCurrent = scopeIsCurrent
        self.executeRun = executeRun
        self.timeZoneProvider = timeZoneProvider
        self.now = now
    }

    /// Drain bounded receipt pages. A concurrent caller marks one extra pass instead of duplicating a
    /// checkpointed analysis run; the active caller observes that mark before it returns.
    func drain() async -> HistoricalReceiptAnalysisDrainResult {
        guard !isDraining else {
            rerunRequested = true
            return .alreadyDraining
        }

        isDraining = true
        defer { isDraining = false }

        var total = HistoricalReceiptAnalysisDrainResult.idle
        repeat {
            rerunRequested = false
            guard let store = await storeProvider() else {
                total = total.adding(deferredScopes: 1)
                break
            }
            let pass = await drain(store: store)
            total = total.adding(pass)
        } while rerunRequested

        return total
    }

    private func drain(store: WhoopStore) async -> HistoricalReceiptAnalysisDrainResult {
        var result = HistoricalReceiptAnalysisDrainResult.idle

        for _ in 0..<Self.maximumBatchesPerDrain {
            let pendingScopes: [HistoricalAnalysisPendingScope]
            do {
                pendingScopes = try await store.pendingHistoricalAnalysisScopes(consumerId: Self.consumerId)
            } catch {
                return result.adding(deferredScopes: 1)
            }
            guard !pendingScopes.isEmpty else { break }

            var advancedThisBatch = false
            for pendingScope in pendingScopes {
                switch await process(pendingScope, in: store) {
                case .acknowledged(let runCount):
                    advancedThisBatch = true
                    result = result.adding(acknowledgedReceipts: 1, analysisRuns: runCount)
                case .deferred:
                    result = result.adding(deferredScopes: 1)
                }
            }
            guard advancedThisBatch else { break }
        }

        return result
    }

    private func process(
        _ pendingScope: HistoricalAnalysisPendingScope,
        in store: WhoopStore
    ) async -> ScopeResult {
        guard await scopeIsCurrent(store, pendingScope.scope) else {
            // Raw analysis rows are currently keyed by device id. A replacement source therefore cannot
            // safely replay a prior lineage under that same id. Preserve its durable work for an explicit
            // source-cleanup path instead of producing an untruthful mixed-source score.
            return .deferred
        }

        do {
            let work = try await resolveWork(pendingScope, in: store)
            let runCount = try await execute(work, in: store)
            // The registry check and checkpoint mutation share one database write. A source switch after
            // the last run therefore leaves the exact staged receipt pending instead of advancing it.
            guard try await store.acknowledgeHistoricalAnalysisIfCurrentScope(
                consumerId: Self.consumerId,
                through: work.receipt
            ) != nil else {
                return .deferred
            }
            return .acknowledged(runCount: runCount)
        } catch {
            return .deferred
        }
    }

    private func resolveWork(
        _ pendingScope: HistoricalAnalysisPendingScope,
        in store: WhoopStore
    ) async throws -> ResolvedWork {
        if let pendingWork = pendingScope.pendingWork {
            let payload = try JSONDecoder().decode(PendingPayload.self, from: pendingWork.payload)
            let calendar = try payload.calendar()
            guard payload.plan.scope == pendingScope.scope,
                  payload.plan.databaseInstanceId == pendingWork.target.databaseInstanceId,
                  payload.plan.throughGeneration == pendingWork.target.generation else {
                throw ConsumerError.invalidPayload
            }
            let receipt = try await targetReceipt(
                pendingWork.target,
                scope: pendingScope.scope,
                in: store
            )
            return ResolvedWork(receipt: receipt, plan: payload.plan, calendar: calendar)
        }

        let throughGeneration = pendingScope.checkpoint?.throughGeneration ?? 0
        let receipts = try await store.historicalDataCommitReceipts(
            deviceId: pendingScope.scope.deviceId,
            afterGeneration: throughGeneration,
            limit: Self.receiptLimit,
            lineage: pendingScope.scope.lineage,
            cursorEpoch: pendingScope.scope.cursorEpoch,
            trimScope: pendingScope.scope.trimScope
        )
        guard let targetReceipt = receipts.last else {
            throw ConsumerError.targetReceiptMissing
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZoneProvider()
        let plan = try HistoricalReceiptAnalysisPlanner.plan(
            receipts: receipts,
            using: calendar,
            scope: pendingScope.scope,
            databaseInstanceId: targetReceipt.databaseInstanceId
        )
        guard plan.throughGeneration == targetReceipt.generation else {
            throw ConsumerError.targetReceiptMismatch
        }

        let payload = try PendingPayload(plan: plan, calendar: calendar)
        let encodedPayload = try JSONEncoder().encode(payload)
        _ = try await store.stageHistoricalAnalysis(
            consumerId: Self.consumerId,
            for: pendingScope.scope,
            through: targetReceipt,
            payload: encodedPayload
        )
        return ResolvedWork(receipt: targetReceipt, plan: plan, calendar: calendar)
    }

    private func targetReceipt(
        _ target: HistoricalAnalysisReceiptFrontier,
        scope: HistoricalCursorScope,
        in store: WhoopStore
    ) async throws -> HistoricalDataCommitReceipt {
        guard target.generation > 0 else {
            throw ConsumerError.targetReceiptMismatch
        }
        let receipts = try await store.historicalDataCommitReceipts(
            deviceId: scope.deviceId,
            afterGeneration: target.generation - 1,
            limit: 1,
            lineage: scope.lineage,
            cursorEpoch: scope.cursorEpoch,
            trimScope: scope.trimScope
        )
        guard let receipt = receipts.first else {
            throw ConsumerError.targetReceiptMissing
        }
        guard receipt.databaseInstanceId == target.databaseInstanceId,
              receipt.generation == target.generation,
              receipt.trim == target.trim,
              receipt.receiptId == target.receiptId,
              receipt.fingerprint == target.fingerprint else {
            throw ConsumerError.targetReceiptMismatch
        }
        return receipt
    }

    private func execute(_ work: ResolvedWork, in store: WhoopStore) async throws -> Int {
        guard case .analysis(let window) = work.plan.outcome else { return 0 }
        let context = try CommittedAnalysisExecutionContext(
            reference: now(),
            timeZoneIdentifier: work.calendar.timeZone.identifier
        )
        let affectedDays = try window.affectedDays(using: work.calendar)
        let runs = try CommittedAnalysisRunPlanner.runs(
            for: affectedDays,
            reference: context.reference,
            calendar: work.calendar
        )

        for run in runs {
            guard !Task.isCancelled else { throw ConsumerError.cancelled }
            // A source switch may happen while the prior run suspends in the analysis engine. Check before
            // every distinct run so the next run cannot execute under the replacement source.
            guard await scopeIsCurrent(store, work.plan.scope) else {
                throw ConsumerError.scopeNoLongerCurrent
            }
            guard await executeRun(run, context) else {
                throw ConsumerError.analysisDidNotComplete
            }
        }
        return runs.count
    }
}

private extension HistoricalReceiptAnalysisDrainResult {
    func adding(_ other: Self) -> Self {
        adding(
            acknowledgedReceipts: other.acknowledgedReceiptCount,
            analysisRuns: other.analysisRunCount,
            deferredScopes: other.deferredScopeCount
        )
    }

    func adding(
        acknowledgedReceipts: Int = 0,
        analysisRuns: Int = 0,
        deferredScopes: Int = 0
    ) -> Self {
        Self(
            acknowledgedReceiptCount: acknowledgedReceiptCount + acknowledgedReceipts,
            analysisRunCount: analysisRunCount + analysisRuns,
            deferredScopeCount: deferredScopeCount + deferredScopes,
            isAlreadyDraining: isAlreadyDraining
        )
    }
}
