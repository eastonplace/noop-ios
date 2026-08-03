import Foundation
import WhoopStore

/// Validation failures at the boundary between durable historical receipts and later analysis.
enum HistoricalReceiptAnalysisPlannerError: Error, Equatable, Sendable {
    case emptyReceiptSequence
    case emptyDatabaseInstanceId
    case invalidDatabaseInstanceId
    case mixedDatabaseInstance
    case invalidScope
    case mixedScope
    case invalidGeneration(Int64)
    case duplicateGeneration
    case nonmonotonicGeneration
    case invalidRowCounts(Int64)
    case productiveReceiptMissingTimestampEvidence(Int64)
    case invalidTimestampEvidence(Int64)
    case timestampHealRequiresExplicitWindow(Int64)
    case nonGregorianCalendar
    case invalidAnalysisWindow(CommittedAnalysisWindowError)
}

/// The result of receipt admission. It carries no analysis result and performs no persistence.
enum HistoricalReceiptAnalysisPlanOutcome: Equatable, Sendable {
    case analysis(window: CommittedAnalysisWindow)
    case noAnalysis
}

/// One validated, single-scope historical analysis handoff.
///
/// `throughGeneration` always includes the last receipt in the admitted sequence. Therefore a zero-row
/// final receipt can advance the durable edge after an earlier productive receipt without widening the
/// analysis window.
struct HistoricalReceiptAnalysisPlan: Equatable, Sendable {
    let databaseInstanceId: String
    let scope: HistoricalCursorScope
    let throughGeneration: Int64
    let outcome: HistoricalReceiptAnalysisPlanOutcome

    var window: CommittedAnalysisWindow? {
        guard case .analysis(let window) = outcome else { return nil }
        return window
    }

    var requiresAnalysis: Bool {
        if case .analysis = outcome { return true }
        return false
    }

    var isNoAnalysis: Bool { !requiresAnalysis }
}

/// Pure Phase 2 admission for one already-scoped receipt sequence.
enum HistoricalReceiptAnalysisPlanner {
    /// The largest integer timestamp that remains exact when converted to the analytics pipeline's Double
    /// timeline. The planner does not impose a product-date floor; it only rejects unsafe representation.
    private static let exactTimelineTimestampLimit: Int64 = 9_007_199_254_740_991

    /// Build a plan using a Gregorian calendar whose time zone remains authoritative when the caller later
    /// expands `plan.window` through `CommittedAnalysisWindow.affectedDays(using:)`.
    static func plan(
        receipts: [HistoricalDataCommitReceipt],
        using calendar: Calendar,
        scope expectedScope: HistoricalCursorScope? = nil,
        databaseInstanceId expectedDatabaseInstanceId: String? = nil
    ) throws -> HistoricalReceiptAnalysisPlan {
        guard !receipts.isEmpty else {
            throw HistoricalReceiptAnalysisPlannerError.emptyReceiptSequence
        }
        guard calendar.identifier == .gregorian else {
            throw HistoricalReceiptAnalysisPlannerError.nonGregorianCalendar
        }

        if let expectedDatabaseInstanceId {
            try validateDatabaseInstanceId(expectedDatabaseInstanceId)
        }
        if let expectedScope {
            try validateExpectedScope(expectedScope)
        }

        var databaseInstanceId: String?
        var receiptScope: HistoricalCursorScope?
        var previousGeneration: Int64?
        var minimumTimestamp: Date?
        var maximumTimestamp: Date?
        var hasExactTimestampEvidence = false

        for receipt in receipts {
            let generation = receipt.generation
            guard generation >= 0 else {
                throw HistoricalReceiptAnalysisPlannerError.invalidGeneration(generation)
            }
            if let previousGeneration {
                if generation == previousGeneration {
                    throw HistoricalReceiptAnalysisPlannerError.duplicateGeneration
                }
                guard generation > previousGeneration else {
                    throw HistoricalReceiptAnalysisPlannerError.nonmonotonicGeneration
                }
            }
            previousGeneration = generation

            try validateDatabaseInstanceId(receipt.databaseInstanceId)
            if let expectedDatabaseInstanceId,
               receipt.databaseInstanceId != expectedDatabaseInstanceId {
                throw HistoricalReceiptAnalysisPlannerError.mixedDatabaseInstance
            }
            if let databaseInstanceId,
               receipt.databaseInstanceId != databaseInstanceId {
                throw HistoricalReceiptAnalysisPlannerError.mixedDatabaseInstance
            }
            databaseInstanceId = databaseInstanceId ?? receipt.databaseInstanceId

            let candidateScope = HistoricalCursorScope(
                deviceId: receipt.deviceId,
                lineage: receipt.lineage,
                cursorEpoch: receipt.cursorEpoch,
                trimScope: receipt.trimScope
            )
            try validateReceiptScope(candidateScope)
            if let expectedScope, !matches(candidateScope, expected: expectedScope) {
                throw HistoricalReceiptAnalysisPlannerError.mixedScope
            }
            if let receiptScope, receiptScope != candidateScope {
                throw HistoricalReceiptAnalysisPlannerError.mixedScope
            }
            receiptScope = receiptScope ?? candidateScope

            guard let insertedCount = checkedCount(receipt.insertedRows),
                  checkedCount(receipt.decodedRows) != nil else {
                throw HistoricalReceiptAnalysisPlannerError.invalidRowCounts(generation)
            }

            // Decoder drops did not mutate stored rows. Only a database-row deletion needs an explicit
            // affected-day window; UTC touchedDays/raw capture ranges are not a fallback for that window.
            if receipt.timestampHeal.rawRowsDeleted > 0
                || receipt.timestampHeal.computedRowsDeleted > 0
                || (receipt.timestampHeal.didChange && receipt.timestampHeal.droppedRecordCount == 0) {
                throw HistoricalReceiptAnalysisPlannerError.timestampHealRequiresExplicitWindow(generation)
            }

            let isProductive = insertedCount > 0
            guard isProductive else {
                // Empty receipts still participate in generation ordering and scope validation. Their
                // optional timestamp metadata is intentionally not allowed to widen an analysis window.
                continue
            }
            guard let minimumRaw = receipt.minDecodedTimestamp,
                  let maximumRaw = receipt.maxDecodedTimestamp else {
                // v36 migrated journal rows use a legacy fingerprint and have no decoded timestamp
                // envelope. They are acknowledged at the durable fence without inventing analysis days.
                // Any newer productive receipt must still provide both decoded bounds.
                if receipt.fingerprint.hasPrefix("legacy:"),
                   receipt.minDecodedTimestamp == nil,
                   receipt.maxDecodedTimestamp == nil {
                    continue
                }
                throw HistoricalReceiptAnalysisPlannerError.productiveReceiptMissingTimestampEvidence(generation)
            }
            guard minimumRaw <= maximumRaw,
                  let minimumDate = date(for: minimumRaw),
                  let maximumDate = date(for: maximumRaw),
                  minimumDate <= maximumDate else {
                throw HistoricalReceiptAnalysisPlannerError.invalidTimestampEvidence(generation)
            }

            if let currentMinimum = minimumTimestamp {
                minimumTimestamp = min(currentMinimum, minimumDate)
            } else {
                minimumTimestamp = minimumDate
            }
            if let currentMaximum = maximumTimestamp {
                maximumTimestamp = max(currentMaximum, maximumDate)
            } else {
                maximumTimestamp = maximumDate
            }
            hasExactTimestampEvidence = true
        }

        guard let databaseInstanceId, let receiptScope, let throughGeneration = previousGeneration else {
            // The loop cannot reach this branch for a non-empty input. Keep the guard so the returned plan
            // never carries an incomplete fence if the admission implementation changes later.
            throw HistoricalReceiptAnalysisPlannerError.emptyReceiptSequence
        }

        guard hasExactTimestampEvidence else {
            return HistoricalReceiptAnalysisPlan(
                databaseInstanceId: databaseInstanceId,
                scope: receiptScope,
                throughGeneration: throughGeneration,
                outcome: .noAnalysis
            )
        }

        guard let minimumTimestamp, let maximumTimestamp else {
            // Every productive receipt is required to contribute both bounds, so this is defensive only.
            throw HistoricalReceiptAnalysisPlannerError.invalidTimestampEvidence(throughGeneration)
        }

        let window = CommittedAnalysisWindow(
            minimumTimestamp: minimumTimestamp,
            maximumTimestamp: maximumTimestamp
        )
        do {
            // Validate the bounded civil expansion now. The plan still stores instants and leaves the
            // caller's Gregorian time zone in charge of the eventual local-day projection.
            _ = try window.affectedDays(using: calendar)
        } catch let error as CommittedAnalysisWindowError {
            throw HistoricalReceiptAnalysisPlannerError.invalidAnalysisWindow(error)
        }

        return HistoricalReceiptAnalysisPlan(
            databaseInstanceId: databaseInstanceId,
            scope: receiptScope,
            throughGeneration: throughGeneration,
            outcome: .analysis(window: window)
        )
    }

    /// Calendar-label convenience for callers that prefer `calendar:` over `using:`.
    static func plan(
        receipts: [HistoricalDataCommitReceipt],
        calendar: Calendar,
        scope expectedScope: HistoricalCursorScope? = nil,
        databaseInstanceId expectedDatabaseInstanceId: String? = nil
    ) throws -> HistoricalReceiptAnalysisPlan {
        try plan(
            receipts: receipts,
            using: calendar,
            scope: expectedScope,
            databaseInstanceId: expectedDatabaseInstanceId
        )
    }

    /// Unlabelled-sequence convenience for small pure call sites and tests.
    static func plan(
        _ receipts: [HistoricalDataCommitReceipt],
        using calendar: Calendar,
        scope expectedScope: HistoricalCursorScope? = nil,
        databaseInstanceId expectedDatabaseInstanceId: String? = nil
    ) throws -> HistoricalReceiptAnalysisPlan {
        try plan(
            receipts: receipts,
            using: calendar,
            scope: expectedScope,
            databaseInstanceId: expectedDatabaseInstanceId
        )
    }

    private static func validateDatabaseInstanceId(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HistoricalReceiptAnalysisPlannerError.emptyDatabaseInstanceId
        }
        guard value == trimmed,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw HistoricalReceiptAnalysisPlannerError.invalidDatabaseInstanceId
        }
    }

    private static func validateExpectedScope(_ scope: HistoricalCursorScope) throws {
        // An omitted device id is a compatibility wildcard. The receipt-derived scope must always carry
        // the concrete device id, so one source cannot accidentally merge with another source.
        if !scope.deviceId.isEmpty {
            try validateScopeComponent(scope.deviceId)
        }
        guard scope.cursorEpoch >= 0 else {
            throw HistoricalReceiptAnalysisPlannerError.invalidScope
        }
        try validateScopeComponent(scope.lineage)
        try validateScopeComponent(scope.trimScope)
    }

    private static func validateReceiptScope(_ scope: HistoricalCursorScope) throws {
        guard !scope.deviceId.isEmpty else {
            throw HistoricalReceiptAnalysisPlannerError.invalidScope
        }
        try validateScopeComponent(scope.deviceId)
        try validateScopeComponent(scope.lineage)
        try validateScopeComponent(scope.trimScope)
        guard scope.cursorEpoch >= 0 else {
            throw HistoricalReceiptAnalysisPlannerError.invalidScope
        }
    }

    private static func validateScopeComponent(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              value == trimmed,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw HistoricalReceiptAnalysisPlannerError.invalidScope
        }
    }

    private static func matches(
        _ receiptScope: HistoricalCursorScope,
        expected expectedScope: HistoricalCursorScope
    ) -> Bool {
        (expectedScope.deviceId.isEmpty || receiptScope.deviceId == expectedScope.deviceId)
            && receiptScope.lineage == expectedScope.lineage
            && receiptScope.cursorEpoch == expectedScope.cursorEpoch
            && receiptScope.trimScope == expectedScope.trimScope
    }

    private static func checkedCount(_ counts: HistoricalStreamInsertCounts) -> Int? {
        let values = [
            counts.hr, counts.rr, counts.events, counts.battery, counts.spo2, counts.skinTemp,
            counts.resp, counts.gravity, counts.steps, counts.sleepState, counts.ppgHr, counts.ppgWaveform,
        ]
        var total = 0
        for value in values {
            guard value >= 0 else { return nil }
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }

    private static func date(for rawTimestamp: Int) -> Date? {
        let timestamp = Int64(rawTimestamp)
        guard timestamp >= -exactTimelineTimestampLimit,
              timestamp <= exactTimelineTimestampLimit else { return nil }
        let interval = TimeInterval(rawTimestamp)
        guard interval.isFinite else { return nil }
        return Date(timeIntervalSince1970: interval)
    }
}
