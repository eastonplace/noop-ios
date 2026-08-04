// Add to Strand/Data and use while refactoring IntelligenceEngine.swift.
// Existing scoring formulas and per-day scan bodies stay unchanged. Only scheduling, exact windows, and the
// durable mutation boundary change.

import Foundation
import NoopPhase34Core
import WhoopStore

struct ExactCommittedAnalysisRequest: Equatable, Sendable {
    let databaseInstanceId: String
    let sourceId: String
    let throughReceiptGeneration: Int64
    let affectedDays: Set<CivilDay>
    let recordedTimeZoneIdentifier: String

    init(
        databaseInstanceId: String,
        sourceId: String,
        throughReceiptGeneration: Int64,
        affectedDays: Set<CivilDay>,
        recordedTimeZoneIdentifier: String
    ) throws {
        guard !databaseInstanceId.isEmpty,
              !sourceId.isEmpty,
              throughReceiptGeneration > 0,
              !affectedDays.isEmpty,
              TimeZone(identifier: recordedTimeZoneIdentifier) != nil else {
            throw ExactCommittedAnalysisError.invalidRequest
        }
        self.databaseInstanceId = databaseInstanceId
        self.sourceId = sourceId
        self.throughReceiptGeneration = throughReceiptGeneration
        self.affectedDays = affectedDays
        self.recordedTimeZoneIdentifier = recordedTimeZoneIdentifier
    }
}

/// The minimum exact result returned after the scorer's row transaction commits. Changed-row details can stay
/// on the existing Intelligence result type; these fields are the durable handoff contract.
struct ExactAnalysisPersistedResult: Equatable, Sendable {
    let analyzedDays: Set<CivilDay>
    let rawFrontierTs: Int?
    let algorithmBundleVersion: String
    let completed: Bool
}

enum ExactCommittedAnalysisError: Error {
    case invalidRequest
    case unrepresentableDay
    case futureCivilDay
    case incompleteAnalysis
    case verificationFailed
}

extension IntelligenceEngine {
    /// Build exactly the civil windows requested by committed receipt evidence. This replaces the
    /// CommittedAnalysisRun relative-offset adapter, which forced disjoint days through a contiguous range.
    nonisolated static func exactCivilDayWindows(
        days: Set<CivilDay>,
        timeZoneIdentifier: String
    ) throws -> [CivilDayWindow] {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw ExactCommittedAnalysisError.invalidRequest
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return try days.sorted().map { day in
            let start = try day.date(in: calendar)
            guard let next = calendar.date(byAdding: .day, value: 1, to: start) else {
                throw ExactCommittedAnalysisError.unrepresentableDay
            }
            return CivilDayWindow(
                day: day.key,
                start: Int(start.timeIntervalSince1970),
                nextStart: Int(next.timeIntervalSince1970)
            )
        }
    }
}

/// Create the analysis mutation receipt only after score rows are committed. The journal's AUTOINCREMENT value
/// is the analysis generation. No receipt, Repository, or snapshot generation is substituted for it.
enum ExactAnalysisMutationCommitter {
    static func commit(
        work: HistoricalAnalysisWork,
        result: ExactAnalysisPersistedResult,
        store: WhoopStore,
        now: Date
    ) async throws -> AnalysisMutationReceipt {
        let databaseInstanceId = try await store.databaseInstanceId()
        guard result.completed,
              work.affectedDays.isSubset(of: result.analyzedDays),
              work.scope.databaseInstanceId == databaseInstanceId else {
            throw ExactCommittedAnalysisError.incompleteAnalysis
        }
        let durable = try await store.recordAnalysisMutation(
            work: work,
            analyzedDays: result.analyzedDays,
            rawFrontierTs: result.rawFrontierTs,
            algorithmBundleVersion: result.algorithmBundleVersion,
            now: now
        )
        return try AnalysisMutationReceipt(
            throughReceiptGeneration: durable.throughReceiptGeneration,
            analysisGeneration: durable.generation,
            analyzedDays: durable.analyzedDays,
            rawFrontierTs: durable.rawFrontierTs,
            algorithmBundleVersion: durable.algorithmBundleVersion
        )
    }
}

/*
Required IntelligenceEngine extraction. Do not rewrite formulas.

A. Extract the existing body of `analyzeRecent` after request validation into:

    private func analyzeWindows(
        _ windows: [CivilDayWindow],
        force: Bool,
        refreshRepository: Bool,
        analysisReference: Date,
        analysisCalendar: Calendar
    ) async throws -> IntelligenceExactAnalysisResult

`IntelligenceExactAnalysisResult` must include:

    analyzedDays: Set<CivilDay>
    changedDays: Set<String>
    persistedRecoveryReceipts: [RecoveryPersistenceReceipt]
    changedDailyRows: [DailyMetric]
    changedSleepScoreDays: Set<String>
    changedSleepSessionDays: Set<String>
    rawFrontierTs: Int?
    algorithmBundleVersion: String
    completed: Bool

The existing score-row writes remain one transaction per exact run. Do not report `completed` before those
writes commit.

B. Existing `analyzeRecent(maxDays:startOffset:...)` becomes a thin legacy adapter that builds contiguous
calendar windows and calls `analyzeWindows`.

C. Add one coordinator route:

    func analyzeCommittedWork(
        _ work: HistoricalAnalysisWork,
        store: WhoopStore,
        now: Date
    ) async throws -> AnalysisMutationReceipt

It must:

    1. build `ExactCommittedAnalysisRequest` from the work item;
    2. call `exactCivilDayWindows`;
    3. call `analyzeWindows` once with `refreshRepository: false`;
    4. require every requested day in the authoritative analyzed-day set, including no-score outcomes;
    5. call `ExactAnalysisMutationCommitter.commit` after score rows commit;
    6. never call Repository.refresh.

D. Baselines:

Keep formula inputs unchanged. Cache imported/computed daily baseline aggregates by:

    databaseInstanceId + source lineage + baseline epoch + latest aggregate generation

An exact morning run may read baseline daily aggregates once. It must not reread raw HR/RR for baseline days.

E. Time zones:

Use every exact `CivilDayWindow.start/nextStart`. Keep civil-day boundaries calendar-derived in the exact path.
*/

@MainActor
extension IntelligenceEngine {
    /// Score one committed work item through the durable exact-day owner. The existing scorer remains the
    /// formula owner. This adapter invokes it once per admitted civil day, so a sparse receipt never expands
    /// into a contiguous range and the Repository is not refreshed until the coordinator publishes success.
    func analyzeCommittedWork(
        _ work: HistoricalAnalysisWork,
        store: WhoopStore,
        now: Date
    ) async throws -> AnalysisMutationReceipt {
        guard case .exactDays = work.kind, !work.affectedDays.isEmpty else {
            throw ExactCommittedAnalysisError.invalidRequest
        }
        let request = try ExactCommittedAnalysisRequest(
            databaseInstanceId: work.scope.databaseInstanceId,
            sourceId: work.scope.sourceId,
            throughReceiptGeneration: work.lastReceiptGeneration,
            affectedDays: work.affectedDays,
            recordedTimeZoneIdentifier: work.recordedTimeZoneIdentifier
        )
        let windows = try Self.exactCivilDayWindows(
            days: request.affectedDays,
            timeZoneIdentifier: request.recordedTimeZoneIdentifier
        )
        guard let timeZone = TimeZone(identifier: request.recordedTimeZoneIdentifier) else {
            throw ExactCommittedAnalysisError.invalidRequest
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let referenceMidnight = calendar.startOfDay(for: now)
        var analyzedDays = Set<CivilDay>()

        for window in windows {
            let dayStart = Date(timeIntervalSince1970: TimeInterval(window.start))
            guard let offset = calendar.dateComponents(
                [.day], from: dayStart, to: referenceMidnight
            ).day, offset >= 0 else {
                throw ExactCommittedAnalysisError.futureCivilDay
            }

            // The six-label call selects the existing formula implementation. Its calendar windows use
            // the supplied civil calendar, including DST transitions, and refreshRepository is suppressed.
            let completed = await analyzeRecent(
                maxDays: 1,
                startOffset: offset,
                force: true,
                refreshRepository: false,
                analysisReference: now,
                analysisCalendar: calendar
            )
            guard completed else { throw ExactCommittedAnalysisError.incompleteAnalysis }
            analyzedDays.insert(try CivilDay(key: window.day))
        }

        let rawFrontierTs = try? await store.latestHRSampleTs(deviceId: work.scope.deviceId)
        let result = ExactAnalysisPersistedResult(
            analyzedDays: analyzedDays,
            rawFrontierTs: rawFrontierTs ?? nil,
            algorithmBundleVersion: "noop-health-v2|strain-v2|sleep-performance-v2",
            completed: work.affectedDays.isSubset(of: analyzedDays)
        )
        return try await ExactAnalysisMutationCommitter.commit(
            work: work,
            result: result,
            store: store,
            now: now
        )
    }
}
