import Foundation
import GRDB

public struct WorkoutSuggestionSpan: Equatable, Sendable {
    public let startSec: Int
    public let endSec: Int

    public init(startSec: Int, endSec: Int) {
        self.startSec = startSec
        self.endSec = endSec
    }
}

public struct StoredWorkoutSuggestionSpan: Equatable, Sendable {
    public let deviceId: String
    public let startSec: Int
    public let endSec: Int
    public let source: String

    /// Matches the existing visible-workout policy: only derived detected rows can be hidden by
    /// a detected-workout dismissal. A manual/imported row always remains an overlap suppressor.
    public func isDismissed(by spans: [WorkoutSuggestionSpan]) -> Bool {
        source.lowercased().hasSuffix("-noop") && spans.contains {
            $0.endSec > $0.startSec && startSec < $0.endSec && $0.startSec < endSec
        }
    }
}

public enum WorkoutSuggestionInsertOutcome: Equatable, Sendable {
    case inserted
    case overlapsExisting
    case staleDatabase
    case staleSource
}

public enum WorkoutSuggestionStoreError: Error, Equatable {
    case invalidWorkout
}

extension WhoopStore {
    /// Capture a writable raw-source owner before reading a suggestion. A source whose data has been
    /// archived, deleted, or purged is history only and cannot admit a new manual suggestion.
    public func workoutSuggestionSourceOwner(deviceId: String) async throws -> HistoricalCursorScope {
        try Task.checkCancellation()
        return try syncRead { db in
            let owner = try currentReceiptLiftSourceOwnerInTransaction(deviceId: deviceId, db: db)
            try assertReceiptLiftSourceOwner(owner, db: db)
            return owner
        }
    }

    /// True closed-interval overlap, including a long session that started before the scan window.
    /// Only the requested namespaces contribute. Unlike the general workout list this query has no
    /// oldest-first row cap that could silently drop a recent suppressor.
    public func workoutSuggestionSpans(deviceIds: [String], from: Int, to: Int) async throws
        -> [StoredWorkoutSuggestionSpan] {
        try Task.checkCancellation()
        guard to >= from else { return [] }
        return try syncRead { db in
            try Self.workoutSuggestionSpans(in: db, deviceIds: deviceIds, from: from, to: to)
        }
    }

    /// A user-confirmed suggestion is inserted only if its database and durable source owner still
    /// match the review and no visible saved workout overlaps it. All checks and the insert share one
    /// transaction, so a queued save cannot recreate a manual row after a purge or source reuse.
    public func insertWorkoutSuggestion(_ row: WorkoutRow, deviceId: String,
                                        overlapDeviceIds: [String],
                                        dismissedDetectedSpans: [WorkoutSuggestionSpan] = [],
                                        expectedDatabaseInstanceId: String,
                                        sourceOwner: HistoricalCursorScope) async throws
        -> WorkoutSuggestionInsertOutcome {
        try Task.checkCancellation()
        let (duration, overflow) = row.endTs.subtractingReportingOverflow(row.startTs)
        guard !overflow, row.startTs > 0, duration > 0, duration <= 2 * 86_400,
              row.source == "manual", row.durationS == Double(duration),
              !row.sport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              row.sport.count <= 80, !row.sport.contains("\0"),
              !deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkoutSuggestionStoreError.invalidWorkout
        }
        guard sourceOwner.deviceId == deviceId, !sourceOwner.lineage.isEmpty,
              sourceOwner.cursorEpoch >= 0,
              sourceOwner.trimScope == HistoricalCursorScope.defaultTrimScope else { return .staleSource }
        return try syncWrite { db in
            try Task.checkCancellation()
            guard try Self.databaseInstanceId(in: db) == expectedDatabaseInstanceId else { return .staleDatabase }
            do {
                try assertReceiptLiftSourceOwner(sourceOwner, db: db)
            } catch let error as LiftReceiptStateError {
                switch error {
                case .ownerUnavailable, .ownerArchived, .ownerDeleting, .ownerPurged, .ownerChanged:
                    return .staleSource
                default: throw error
                }
            }
            let spans = try Self.workoutSuggestionSpans(
                in: db, deviceIds: overlapDeviceIds + [deviceId], from: row.startTs, to: row.endTs)
            guard spans.allSatisfy({ $0.isDismissed(by: dismissedDetectedSpans) }) else { return .overlapsExisting }
            try Task.checkCancellation()
            _ = try Self.upsertWorkoutRows(db: db, rows: [row], deviceId: deviceId)
            return .inserted
        }
    }

    private static func workoutSuggestionSpans(in db: Database, deviceIds: [String], from: Int, to: Int) throws
        -> [StoredWorkoutSuggestionSpan] {
        let ids = Array(Set(deviceIds.filter { !$0.isEmpty })).sorted()
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var arguments = StatementArguments(ids)
        arguments += StatementArguments([to, from])
        return try Row.fetchAll(db, sql: """
            SELECT deviceId, startTs, endTs, source FROM workout
            WHERE deviceId IN (\(placeholders)) AND startTs <= ? AND endTs >= ? AND endTs > startTs
            ORDER BY startTs ASC, deviceId ASC
            """, arguments: arguments).map {
                StoredWorkoutSuggestionSpan(deviceId: $0["deviceId"], startSec: $0["startTs"],
                                            endSec: $0["endTs"], source: $0["source"])
            }
    }
}
