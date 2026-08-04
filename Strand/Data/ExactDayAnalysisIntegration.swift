import Foundation
import NoopPhase34Core
import WhoopStore

struct ExactCommittedAnalysisRequest: Equatable, Sendable {
    let databaseInstanceId: String
    let sourceId: String
    let throughReceiptGeneration: Int64
    let affectedDays: Set<CivilDay>
    let recordedTimeZoneIdentifier: String

    init(work: HistoricalAnalysisWork) throws {
        switch work.kind {
        case .exactDays:
            break
        case .fullHistoryRepair:
            throw PR28HistoricalPipelineError.unsupportedFullHistoryRepair
        }
        guard !work.affectedDays.isEmpty,
              work.lastReceiptGeneration > 0,
              TimeZone(identifier: work.recordedTimeZoneIdentifier) != nil else {
            throw ExactCommittedAnalysisError.invalidRequest
        }
        databaseInstanceId = work.scope.databaseInstanceId
        sourceId = work.scope.sourceId
        throughReceiptGeneration = work.lastReceiptGeneration
        affectedDays = work.affectedDays
        recordedTimeZoneIdentifier = work.recordedTimeZoneIdentifier
    }
}

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

private struct ExactAnalysisRun: Equatable {
    let startOffset: Int
    let maxDays: Int
    let days: Set<CivilDay>
}

extension IntelligenceEngine {
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

    /// Group only adjacent requested civil days. Sparse January/March evidence stays as two runs, while a
    /// normal overnight pair shares one baseline/history read instead of calling the legacy scorer twice.
    nonisolated fileprivate static func exactAnalysisRuns(
        days: Set<CivilDay>,
        reference: Date,
        calendar: Calendar
    ) throws -> [ExactAnalysisRun] {
        let referenceMidnight = calendar.startOfDay(for: reference)
        let pairs = try days.map { day -> (offset: Int, day: CivilDay) in
            let start = try day.date(in: calendar)
            guard let offset = calendar.dateComponents(
                [.day], from: start, to: referenceMidnight
            ).day, offset >= 0 else {
                throw ExactCommittedAnalysisError.futureCivilDay
            }
            return (offset, day)
        }.sorted { $0.offset < $1.offset }
        var runs: [ExactAnalysisRun] = []
        var current: [(offset: Int, day: CivilDay)] = []
        for pair in pairs {
            if let last = current.last, pair.offset != last.offset + 1 {
                runs.append(ExactAnalysisRun(
                    startOffset: current.first!.offset,
                    maxDays: current.last!.offset - current.first!.offset + 1,
                    days: Set(current.map(\.day))
                ))
                current.removeAll(keepingCapacity: true)
            }
            current.append(pair)
        }
        if !current.isEmpty {
            runs.append(ExactAnalysisRun(
                startOffset: current.first!.offset,
                maxDays: current.last!.offset - current.first!.offset + 1,
                days: Set(current.map(\.day))
            ))
        }
        return runs
    }
}

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

@MainActor
extension IntelligenceEngine {
    /// Idempotent exact-day analysis. A crash after the score transaction and mutation receipt does not score
    /// the same generation again. Adjacent days share one scorer call; sparse days stay separate.
    func analyzeCommittedWork(
        _ work: HistoricalAnalysisWork,
        store: WhoopStore,
        now: Date
    ) async throws -> AnalysisMutationReceipt {
        if let existing = try await store.analysisMutation(
            workId: work.id,
            throughReceiptGeneration: work.lastReceiptGeneration
        ) {
            return try AnalysisMutationReceipt(
                throughReceiptGeneration: existing.throughReceiptGeneration,
                analysisGeneration: existing.generation,
                analyzedDays: existing.analyzedDays,
                rawFrontierTs: existing.rawFrontierTs,
                algorithmBundleVersion: existing.algorithmBundleVersion
            )
        }
        guard case .exactDays = work.kind else {
            // Full repair has no exact civil-day evidence. It belongs to the low-priority maintenance lane,
            // never to this current-day exact pipeline. The classifier quarantines this item instead of
            // retrying it forever or silently widening one morning sync to 4,000 days.
            throw PR28HistoricalPipelineError.unsupportedFullHistoryRepair
        }
        let request = try ExactCommittedAnalysisRequest(work: work)
        guard let timeZone = TimeZone(identifier: request.recordedTimeZoneIdentifier) else {
            throw ExactCommittedAnalysisError.invalidRequest
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let runs = try Self.exactAnalysisRuns(
            days: request.affectedDays,
            reference: now,
            calendar: calendar
        )
        var analyzedDays = Set<CivilDay>()
        for run in runs {
            let completed = await analyzeRecent(
                maxDays: run.maxDays,
                startOffset: run.startOffset,
                force: true,
                refreshRepository: false,
                analysisReference: now,
                analysisCalendar: calendar
            )
            guard completed else { throw ExactCommittedAnalysisError.incompleteAnalysis }
            analyzedDays.formUnion(run.days)
        }
        let rawFrontierTs = try await store.latestHRSampleTs(deviceId: work.scope.deviceId)
        return try await ExactAnalysisMutationCommitter.commit(
            work: work,
            result: ExactAnalysisPersistedResult(
                analyzedDays: analyzedDays,
                rawFrontierTs: rawFrontierTs,
                algorithmBundleVersion: "noop-health-v2|strain-v2|sleep-performance-v2",
                completed: work.affectedDays.isSubset(of: analyzedDays)
            ),
            store: store,
            now: now
        )
    }
}
