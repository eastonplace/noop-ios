// Copy into Packages/WhoopStore/Sources/WhoopStore after the Phase 3/4 receipt fields exist.
// Receipt reads may occur outside the admission transaction because journal rows are immutable. The work
// upserts and consumer-watermark advance MUST remain in one SQLite transaction.

import Foundation
import GRDB
import NoopPhase34Core

public enum HistoricalCursorWriteError: Error, Equatable, Sendable {
    case invalidScope
    case invalidGeneration
    case generationRegression(existing: Int64, attempted: Int64)
    case equalGenerationConflict(generation: Int64, existingTrim: Int, attemptedTrim: Int)
    case concurrentMutation
}

public struct HistoricalReceiptAdmissionContext: Sendable {
    public let consumerId: String
    public let sourceId: String
    public let scope: HistoricalCursorScope
    public let maximumReceiptsPerDrain: Int
    public let now: Date

    public init(
        consumerId: String = "phase34.analysis",
        sourceId: String,
        scope: HistoricalCursorScope,
        maximumReceiptsPerDrain: Int = 2_000,
        now: Date = Date()
    ) {
        self.consumerId = consumerId
        self.sourceId = sourceId
        self.scope = scope
        self.maximumReceiptsPerDrain = max(1, maximumReceiptsPerDrain)
        self.now = now
    }
}

public struct HistoricalReceiptAdmissionResult: Equatable, Sendable {
    public let admittedReceiptCount: Int
    public let createdOrCoalescedWorkCount: Int
    public let throughGeneration: Int64
    public let hasMoreReceipts: Bool
}

public enum HistoricalReceiptAdmissionError: Error {
    case invalidContext
    case invalidConsumerRow
    case consumerMoved(expected: Int64, actual: Int64)
    case unsupportedReceiptSchema
}

private struct PlannedHistoricalWork {
    let work: HistoricalAnalysisWork
    let priority: Int
}

extension WhoopStore {
    /// Drains immutable receipt rows, converts them into exact work, then atomically persists work and the
    /// admission watermark. Replaying this method after a crash is safe: either neither work nor watermark
    /// committed, or both did.
    public func admitHistoricalReceipts(
        _ context: HistoricalReceiptAdmissionContext
    ) async throws -> HistoricalReceiptAdmissionResult {
        guard !context.consumerId.isEmpty, !context.sourceId.isEmpty else {
            throw HistoricalReceiptAdmissionError.invalidContext
        }
        let databaseId = try await databaseInstanceId()
        let expectedGeneration = try await historicalReceiptConsumerGeneration(
            consumerId: context.consumerId,
            databaseInstanceId: databaseId,
            scope: context.scope
        )

        var receipts: [HistoricalDataCommitReceipt] = []
        var after = expectedGeneration
        while receipts.count < context.maximumReceiptsPerDrain {
            let remaining = min(200, context.maximumReceiptsPerDrain - receipts.count)
            let page = try await historicalDataCommitReceipts(
                deviceId: context.scope.deviceId,
                afterGeneration: after,
                limit: remaining,
                lineage: context.scope.lineage,
                cursorEpoch: context.scope.cursorEpoch,
                trimScope: context.scope.trimScope
            )
            guard !page.isEmpty else { break }
            receipts.append(contentsOf: page)
            after = page.last!.generation
            if page.count < remaining { break }
        }

        guard let through = receipts.last?.generation else {
            return HistoricalReceiptAdmissionResult(
                admittedReceiptCount: 0,
                createdOrCoalescedWorkCount: 0,
                throughGeneration: expectedGeneration,
                hasMoreReceipts: false
            )
        }

        let plans = try Self.planHistoricalWork(
            receipts: receipts,
            databaseInstanceId: databaseId,
            sourceId: context.sourceId,
            now: context.now
        )

        let coalescedCount = try syncWrite { db -> Int in
            let actualGeneration = try Self.historicalReceiptConsumerGeneration(
                consumerId: context.consumerId,
                databaseInstanceId: databaseId,
                scope: context.scope,
                in: db
            )
            guard actualGeneration == expectedGeneration else {
                throw HistoricalReceiptAdmissionError.consumerMoved(
                    expected: expectedGeneration,
                    actual: actualGeneration
                )
            }

            for plan in plans {
                try Self.upsertPlannedHistoricalWork(plan, in: db)
            }
            try Self.setHistoricalReceiptConsumerGeneration(
                consumerId: context.consumerId,
                databaseInstanceId: databaseId,
                scope: context.scope,
                throughGeneration: through,
                now: context.now,
                in: db
            )
            return plans.count
        }

        let hasMore = receipts.count == context.maximumReceiptsPerDrain
        return HistoricalReceiptAdmissionResult(
            admittedReceiptCount: receipts.count,
            createdOrCoalescedWorkCount: coalescedCount,
            throughGeneration: through,
            hasMoreReceipts: hasMore
        )
    }

    private static func planHistoricalWork(
        receipts: [HistoricalDataCommitReceipt],
        databaseInstanceId: String,
        sourceId: String,
        now: Date
    ) throws -> [PlannedHistoricalWork] {
        // Travel is a real boundary. Never reinterpret a New York receipt through a later London calendar.
        // Legacy v1 receipts never recorded a trustworthy zone; group them into the UTC-labelled broad-repair
        // lane instead of blocking the consumer watermark forever. Exact analysis is permitted only for v2.
        let groupedByZone = receipts.reduce(into: [String: [HistoricalDataCommitReceipt]]()) { result, receipt in
            let zone = receipt.fingerprintVersion >= 2 ? receipt.recordedTimeZoneIdentifier : "UTC"
            result[zone, default: []].append(receipt)
        }
        var result: [PlannedHistoricalWork] = []

        for (timeZoneIdentifier, zoneReceipts) in groupedByZone {
            guard TimeZone(identifier: timeZoneIdentifier) != nil else {
                throw HistoricalReceiptAdmissionError.unsupportedReceiptSchema
            }
            let scopeReceipt = try zoneReceipts.first.unwrap()
            let scope = try HistoricalAnalysisScope(
                databaseInstanceId: databaseInstanceId,
                sourceId: sourceId,
                deviceId: scopeReceipt.deviceId,
                deviceLineageId: scopeReceipt.lineage,
                cursorEpoch: scopeReceipt.cursorEpoch,
                trimScope: scopeReceipt.trimScope
            )

            let evidence = try zoneReceipts.map(Self.phase34Evidence)
            let exactEvidence = evidence.filter { item in
                if case .fullHistoryRepair = item.healMode { return false }
                return item.requiresAnalysis
            }
            let exactBatches = try HistoricalExactWorkBatchPlanner.batches(
                for: exactEvidence,
                maximumDaysPerBatch: HistoricalAnalysisWork.maximumExactDayCount
            )
            for batch in exactBatches {
                let work = try HistoricalAnalysisWork(
                    scope: scope,
                    firstReceiptGeneration: batch.firstReceiptGeneration,
                    lastReceiptGeneration: batch.lastReceiptGeneration,
                    minimumTs: batch.minimumTs,
                    maximumTs: batch.maximumTs,
                    affectedDays: batch.affectedDays,
                    kind: .exactDays,
                    recordedTimeZoneIdentifier: timeZoneIdentifier,
                    createdAt: now
                )
                result.append(PlannedHistoricalWork(
                    work: work,
                    priority: try Self.historicalWorkPriority(
                        days: batch.affectedDays,
                        timeZoneIdentifier: timeZoneIdentifier,
                        now: now
                    )
                ))
            }

            let fullRepairs = evidence.filter {
                if case .fullHistoryRepair = $0.healMode { return true }
                return false
            }
            if !fullRepairs.isEmpty {
                let reasons = fullRepairs.compactMap { item -> String? in
                    guard case .fullHistoryRepair(let reason) = item.healMode else { return nil }
                    return reason
                }.sorted().joined(separator: ",")
                let work = try HistoricalAnalysisWork(
                    scope: scope,
                    firstReceiptGeneration: fullRepairs.map { $0.generation }.min()!,
                    lastReceiptGeneration: fullRepairs.map { $0.generation }.max()!,
                    affectedDays: [],
                    kind: .fullHistoryRepair(reason: reasons),
                    recordedTimeZoneIdentifier: timeZoneIdentifier,
                    createdAt: now
                )
                result.append(PlannedHistoricalWork(work: work, priority: 10))
            }
        }
        return result
    }

    private static func phase34Evidence(
        _ receipt: HistoricalDataCommitReceipt
    ) throws -> HistoricalReceiptEvidence {
        let inserted = try HistoricalStreamCounts(receipt.insertedRows)
        let decoded = try HistoricalStreamCounts(receipt.decodedRows)
        guard receipt.fingerprintVersion >= 2 else {
            // Legacy receipts are not exact day evidence. Any decoded physiological rows become one durable
            // low-priority repair item, even when the rows were duplicates and insertedRows is zero. Empty
            // final/console receipts advance the watermark without forcing a rescore. Decoder-only dropped
            // records are diagnostic and do not prove that stored projections changed.
            let storageHealChanged = receipt.timestampHeal.rawRowsDeleted > 0
                || receipt.timestampHeal.computedRowsDeleted > 0
                || (receipt.timestampHeal.didChange && receipt.timestampHeal.droppedRecordCount == 0)
            let needsRepair = decoded.total > 0 || storageHealChanged
            return try HistoricalReceiptEvidence(
                generation: receipt.generation,
                recordedTimeZoneIdentifier: "UTC",
                decodedRows: HistoricalStreamCounts(),
                insertedRows: inserted,
                timestampBuckets: [],
                explicitDays: [],
                healMode: needsRepair
                    ? .fullHistoryRepair(reason: "legacy_receipt_v1")
                    : .none
            )
        }
        guard TimeZone(identifier: receipt.recordedTimeZoneIdentifier) != nil else {
            throw HistoricalReceiptAdmissionError.unsupportedReceiptSchema
        }
        // Phase 2 `touchedDays` is UTC-derived. Only schema-v2 explicitAffectedDays owns local-day
        // authority for a heal/edit. Normal decoded work is derived from timestamp buckets.
        let explicitDays = Set(try receipt.explicitAffectedDays.map(CivilDay.init(key:)))
        let healMode: HistoricalHealMode
        let storageHealChanged = receipt.timestampHeal.rawRowsDeleted > 0
            || receipt.timestampHeal.computedRowsDeleted > 0
            || (receipt.timestampHeal.didChange && receipt.timestampHeal.droppedRecordCount == 0)
        if storageHealChanged {
            healMode = explicitDays.isEmpty
                ? .fullHistoryRepair(reason: "timestamp_heal_without_exact_days")
                : .exactDays(explicitDays)
        } else {
            healMode = .none
        }
        return try HistoricalReceiptEvidence(
            generation: receipt.generation,
            recordedTimeZoneIdentifier: receipt.recordedTimeZoneIdentifier,
            decodedRows: decoded,
            insertedRows: inserted,
            timestampBuckets: receipt.timestampBuckets,
            explicitDays: explicitDays,
            healMode: healMode
        )
    }

    private static func historicalWorkPriority(
        days: Set<CivilDay>,
        timeZoneIdentifier: String,
        now: Date
    ) throws -> Int {
        let calendar = try HealthCalendar(timeZoneIdentifier: timeZoneIdentifier)
        let today = try calendar.physiologicalDay(containing: now)
        let yesterday = try calendar.adding(days: -1, to: today)
        if days.contains(today) { return 1_000 }
        if days.contains(yesterday) { return 900 }
        let recentFloor = try calendar.adding(days: -14, to: today)
        return days.contains(where: { $0 >= recentFloor }) ? 500 : 100
    }

    private func historicalReceiptConsumerGeneration(
        consumerId: String,
        databaseInstanceId: String,
        scope: HistoricalCursorScope
    ) async throws -> Int64 {
        try syncRead { db in
            try Self.historicalReceiptConsumerGeneration(
                consumerId: consumerId,
                databaseInstanceId: databaseInstanceId,
                scope: scope,
                in: db
            )
        }
    }

    private static func historicalReceiptConsumerGeneration(
        consumerId: String,
        databaseInstanceId: String,
        scope: HistoricalCursorScope,
        in db: Database
    ) throws -> Int64 {
        try Int64.fetchOne(db, sql: """
            SELECT throughGeneration FROM historicalReceiptConsumer
            WHERE consumerId = ? AND databaseInstanceId = ? AND deviceId = ? AND lineage = ?
              AND cursorEpoch = ? AND trimScope = ?
            """, arguments: [
                consumerId, databaseInstanceId, scope.deviceId, scope.lineage,
                scope.cursorEpoch, scope.trimScope,
            ]) ?? 0
    }

    private static func setHistoricalReceiptConsumerGeneration(
        consumerId: String,
        databaseInstanceId: String,
        scope: HistoricalCursorScope,
        throughGeneration: Int64,
        now: Date,
        in db: Database
    ) throws {
        try db.execute(sql: """
            INSERT INTO historicalReceiptConsumer
                (consumerId, databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope,
                 throughGeneration, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(consumerId, databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope)
            DO UPDATE SET
                throughGeneration = MAX(historicalReceiptConsumer.throughGeneration, excluded.throughGeneration),
                updatedAt = excluded.updatedAt
            """, arguments: [
                consumerId, databaseInstanceId, scope.deviceId, scope.lineage,
                scope.cursorEpoch, scope.trimScope, throughGeneration,
                Int(now.timeIntervalSince1970),
            ])
    }

    private static func upsertPlannedHistoricalWork(
        _ plan: PlannedHistoricalWork,
        in db: Database
    ) throws {
        let candidates = try Row.fetchAll(db, sql: """
            SELECT * FROM historicalAnalysisWork
            WHERE databaseInstanceId = ? AND sourceId = ? AND deviceId = ? AND lineage = ?
              AND cursorEpoch = ? AND trimScope = ? AND recordedTimeZoneIdentifier = ?
              AND workKindKey = ? AND state IN ('pending', 'retryable') AND leaseOwner IS NULL
            ORDER BY priority DESC, createdAt ASC LIMIT 128
            """, arguments: [
                plan.work.scope.databaseInstanceId,
                plan.work.scope.sourceId,
                plan.work.scope.deviceId,
                plan.work.scope.deviceLineageId,
                plan.work.scope.cursorEpoch,
                plan.work.scope.trimScope,
                plan.work.recordedTimeZoneIdentifier,
                plan.work.kind.storageKey,
            ])
        for candidate in candidates {
            var work = try decodeHistoricalAnalysisWork(candidate)
            do {
                try work.mergePending(plan.work, now: plan.work.updatedAt)
            } catch HistoricalWorkError.incompatibleMerge {
                continue
            }
            let oldPriority: Int = candidate["priority"]
            try updateHistoricalAnalysisWork(work, priority: max(oldPriority, plan.priority), in: db)
            return
        }
        try insertHistoricalAnalysisWork(plan.work, priority: plan.priority, in: db)
    }
}

private extension HistoricalStreamCounts {
    init(_ counts: HistoricalStreamInsertCounts) throws {
        try self.init(
            hr: counts.hr,
            rr: counts.rr,
            events: counts.events,
            battery: counts.battery,
            spo2: counts.spo2,
            skinTemp: counts.skinTemp,
            respiration: counts.resp,
            gravity: counts.gravity,
            steps: counts.steps,
            sleepState: counts.sleepState,
            ppgHR: counts.ppgHr,
            ppgWaveform: counts.ppgWaveform
        )
    }
}

private extension Optional {
    func unwrap(file: StaticString = #fileID, line: UInt = #line) throws -> Wrapped {
        guard let self else { throw HistoricalReceiptAdmissionError.invalidContext }
        return self
    }
}

// MARK: - PR #28 root-fix support for WhoopStore
extension WhoopStore {
    static func setHistoricalCursorV2(
            _ scope: HistoricalCursorScope,
            value: Int,
            watermarkGeneration: Int64,
            in db: Database
        ) throws {
            guard !scope.deviceId.isEmpty,
                  !scope.lineage.isEmpty,
                  scope.cursorEpoch >= 0,
                  !scope.trimScope.isEmpty else {
                throw HistoricalCursorWriteError.invalidScope
            }
            guard watermarkGeneration > 0 else {
                throw HistoricalCursorWriteError.invalidGeneration
            }

            let row = try Row.fetchOne(db, sql: """
                SELECT trim, watermarkGeneration
                FROM historicalCursor
                WHERE deviceId = ? AND lineage = ? AND cursorEpoch = ? AND trimScope = ?
                """, arguments: [scope.deviceId, scope.lineage, scope.cursorEpoch, scope.trimScope])

            guard let row else {
                try db.execute(sql: """
                    INSERT INTO historicalCursor
                        (deviceId, lineage, cursorEpoch, trimScope, trim, watermarkGeneration)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        scope.deviceId, scope.lineage, scope.cursorEpoch, scope.trimScope,
                        value, watermarkGeneration,
                    ])
                return
            }

            let existingTrim: Int = row["trim"]
            let existingGeneration: Int64 = row["watermarkGeneration"]
            if watermarkGeneration < existingGeneration {
                throw HistoricalCursorWriteError.generationRegression(
                    existing: existingGeneration,
                    attempted: watermarkGeneration
                )
            }
            if watermarkGeneration == existingGeneration {
                guard value == existingTrim else {
                    throw HistoricalCursorWriteError.equalGenerationConflict(
                        generation: watermarkGeneration,
                        existingTrim: existingTrim,
                        attemptedTrim: value
                    )
                }
                return // exact idempotent replay
            }

            try db.execute(sql: """
                UPDATE historicalCursor
                SET trim = ?, watermarkGeneration = ?
                WHERE deviceId = ? AND lineage = ? AND cursorEpoch = ? AND trimScope = ?
                  AND watermarkGeneration = ?
                """, arguments: [
                    value, watermarkGeneration,
                    scope.deviceId, scope.lineage, scope.cursorEpoch, scope.trimScope,
                    existingGeneration,
                ])
            guard db.changesCount == 1 else {
                throw HistoricalCursorWriteError.concurrentMutation
            }
        }
}
