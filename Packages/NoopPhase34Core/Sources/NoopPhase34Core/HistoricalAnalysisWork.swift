import Foundation

public struct HistoricalAnalysisScope: Codable, Equatable, Hashable, Sendable {
    public let databaseInstanceId: String
    public let sourceId: String
    public let deviceId: String
    public let deviceLineageId: String
    public let cursorEpoch: Int
    public let trimScope: String

    public init(
        databaseInstanceId: String,
        sourceId: String,
        deviceId: String,
        deviceLineageId: String,
        cursorEpoch: Int,
        trimScope: String
    ) throws {
        guard !databaseInstanceId.isEmpty, !sourceId.isEmpty, !deviceId.isEmpty, !deviceLineageId.isEmpty,
              cursorEpoch >= 0, !trimScope.isEmpty else {
            throw HistoricalWorkError.invalidScope
        }
        self.databaseInstanceId = databaseInstanceId
        self.sourceId = sourceId
        self.deviceId = deviceId
        self.deviceLineageId = deviceLineageId
        self.cursorEpoch = cursorEpoch
        self.trimScope = trimScope
    }
}

public struct HistoricalWorkLease: Codable, Equatable, Sendable {
    public let owner: String
    public let expiresAt: Date

    public init(owner: String, expiresAt: Date) throws {
        guard !owner.isEmpty, expiresAt.timeIntervalSinceReferenceDate.isFinite else {
            throw HistoricalWorkError.invalidLease
        }
        self.owner = owner
        self.expiresAt = expiresAt
    }
}

public enum DownstreamDestination: String, Codable, CaseIterable, Hashable, Sendable {
    case widget
    case liveActivity
    case healthKit
    case watch
}


public enum HistoricalAnalysisWorkKind: Codable, Equatable, Sendable {
    case exactDays
    case fullHistoryRepair(reason: String)

    /// Stable SQL identity. Never compare JSON-encoded enum bytes: encoder layout is payload, not identity.
    public var storageKey: String {
        switch self {
        case .exactDays:
            return "exact-days"
        case .fullHistoryRepair(let reason):
            return "full-history-repair:" + Data(reason.utf8).base64EncodedString()
        }
    }
}

public enum HistoricalAnalysisWorkState: String, Codable, Sendable {
    case pending
    case analyzing
    case verifying
    case snapshotCommitted
    case repositoryPublished
    case complete
    case retryable
    case quarantined
}

public struct HistoricalAnalysisWork: Codable, Equatable, Sendable {
    /// Keeps one exact work item bounded. Admission may create several items for a deep receipt backlog.
    public static let maximumExactDayCount = 64
    public let id: UUID
    public let scope: HistoricalAnalysisScope
    public var firstReceiptGeneration: Int64
    public var lastReceiptGeneration: Int64
    public var minimumTs: Int?
    public var maximumTs: Int?
    public var affectedDays: Set<CivilDay>
    public let kind: HistoricalAnalysisWorkKind
    /// All exact day windows in one work item are interpreted in this recorded zone. Admission must split
    /// receipts when the user travelled between zones instead of merging unlike calendar contexts.
    public let recordedTimeZoneIdentifier: String
    public var state: HistoricalAnalysisWorkState
    public var attemptCount: Int
    public var nextAttemptAt: Date?
    public var lease: HistoricalWorkLease?
    public var analyzedThroughReceiptGeneration: Int64?
    public var analysisGeneration: Int64?
    public var snapshotGeneration: Int64?
    public var pendingDestinations: Set<DownstreamDestination>
    public var lastErrorCode: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        scope: HistoricalAnalysisScope,
        firstReceiptGeneration: Int64,
        lastReceiptGeneration: Int64,
        minimumTs: Int? = nil,
        maximumTs: Int? = nil,
        affectedDays: Set<CivilDay>,
        kind: HistoricalAnalysisWorkKind = .exactDays,
        recordedTimeZoneIdentifier: String,
        createdAt: Date
    ) throws {
        guard firstReceiptGeneration > 0,
              lastReceiptGeneration >= firstReceiptGeneration,
              TimeZone(identifier: recordedTimeZoneIdentifier) != nil,
              createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw HistoricalWorkError.invalidGeneration
        }
        if let minimumTs, let maximumTs, minimumTs > maximumTs {
            throw HistoricalWorkError.invalidRange
        }
        switch kind {
        case .exactDays:
            guard !affectedDays.isEmpty,
                  affectedDays.count <= Self.maximumExactDayCount else {
                throw HistoricalWorkError.invalidRange
            }
        case .fullHistoryRepair(let reason):
            guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HistoricalWorkError.invalidRange
            }
        }
        self.id = id
        self.scope = scope
        self.firstReceiptGeneration = firstReceiptGeneration
        self.lastReceiptGeneration = lastReceiptGeneration
        self.minimumTs = minimumTs
        self.maximumTs = maximumTs
        self.affectedDays = affectedDays
        self.kind = kind
        self.recordedTimeZoneIdentifier = recordedTimeZoneIdentifier
        self.state = .pending
        self.attemptCount = 0
        self.nextAttemptAt = nil
        self.lease = nil
        self.analyzedThroughReceiptGeneration = nil
        self.analysisGeneration = nil
        self.snapshotGeneration = nil
        self.pendingDestinations = []
        self.lastErrorCode = nil
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    public var isTerminal: Bool { state == .complete || state == .quarantined }

    public func canAttempt(at now: Date) -> Bool {
        guard state == .pending || state == .retryable else { return false }
        guard lease == nil || lease!.expiresAt <= now else { return false }
        return nextAttemptAt.map { $0 <= now } ?? true
    }

    /// Coalesce only unstarted work from the same durable source fence. Running or published work retains its
    /// immutable receipt edge; new receipts become another work item or a follow-up rerun.
    public mutating func mergePending(_ other: HistoricalAnalysisWork, now: Date) throws {
        guard scope == other.scope,
              kind == other.kind,
              recordedTimeZoneIdentifier == other.recordedTimeZoneIdentifier,
              [HistoricalAnalysisWorkState.pending, .retryable].contains(state),
              [HistoricalAnalysisWorkState.pending, .retryable].contains(other.state),
              lease == nil, other.lease == nil else {
            throw HistoricalWorkError.incompatibleMerge
        }
        firstReceiptGeneration = min(firstReceiptGeneration, other.firstReceiptGeneration)
        lastReceiptGeneration = max(lastReceiptGeneration, other.lastReceiptGeneration)
        minimumTs = minOptional(minimumTs, other.minimumTs)
        maximumTs = maxOptional(maximumTs, other.maximumTs)
        let mergedDays = affectedDays.union(other.affectedDays)
        if case .exactDays = kind, mergedDays.count > Self.maximumExactDayCount {
            throw HistoricalWorkError.incompatibleMerge
        }
        affectedDays = mergedDays
        state = .pending
        nextAttemptAt = nil
        lastErrorCode = nil
        updatedAt = now
    }
}

public enum HistoricalWorkError: Error, Equatable, Sendable {
    case invalidScope
    case invalidLease
    case invalidGeneration
    case invalidRange
    case incompatibleMerge
    case invalidTransition
    case wrongLeaseOwner
    case leaseExpired
}

private func minOptional(_ lhs: Int?, _ rhs: Int?) -> Int? {
    switch (lhs, rhs) {
    case let (lhs?, rhs?): return min(lhs, rhs)
    case let (lhs?, nil): return lhs
    case let (nil, rhs?): return rhs
    case (nil, nil): return nil
    }
}

private func maxOptional(_ lhs: Int?, _ rhs: Int?) -> Int? {
    switch (lhs, rhs) {
    case let (lhs?, rhs?): return max(lhs, rhs)
    case let (lhs?, nil): return lhs
    case let (nil, rhs?): return rhs
    case (nil, nil): return nil
    }
}
