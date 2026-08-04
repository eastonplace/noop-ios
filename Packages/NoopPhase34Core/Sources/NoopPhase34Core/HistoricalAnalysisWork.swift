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
        guard !databaseInstanceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sourceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !deviceLineageId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              cursorEpoch >= 0,
              !trimScope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
        guard !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              expiresAt.timeIntervalSinceReferenceDate.isFinite else {
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
    /// Waiting for an external condition, such as protected data or user authorization.
    case blocked
    case quarantined
}

/// The next durable side effect that the pipeline owes.
///
/// `state` records the activity that last ran. `resumePhase` is the crash-recovery contract. A failure after
/// snapshot commit resumes at Repository publication instead of scoring the same durable generation again.
public enum HistoricalPipelineResumePhase: String, Codable, CaseIterable, Sendable {
    case analysis
    case verification
    case repositoryPublication
    case outboxCommit
    case done
}

public struct HistoricalAnalysisWork: Codable, Equatable, Sendable {
    /// Keeps one exact work item bounded. Admission may create several items for a deep receipt backlog.
    public static let maximumExactDayCount = 64
    /// Prevents an unbounded poison-item retry loop. A quarantined item stays available for diagnosis.
    public static let maximumAutomaticAttempts = 12

    public let id: UUID
    public let scope: HistoricalAnalysisScope
    public var firstReceiptGeneration: Int64
    public var lastReceiptGeneration: Int64
    public var minimumTs: Int?
    public var maximumTs: Int?
    public var affectedDays: Set<CivilDay>
    public let kind: HistoricalAnalysisWorkKind
    /// All exact day windows in one work item use this recorded zone. Admission splits unlike zones.
    public let recordedTimeZoneIdentifier: String
    public var state: HistoricalAnalysisWorkState
    public var resumePhase: HistoricalPipelineResumePhase
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
        self.resumePhase = .analysis
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

    private enum CodingKeys: String, CodingKey {
        case id, scope, firstReceiptGeneration, lastReceiptGeneration, minimumTs, maximumTs
        case affectedDays, kind, recordedTimeZoneIdentifier, state, resumePhase, attemptCount
        case nextAttemptAt, lease, analyzedThroughReceiptGeneration, analysisGeneration
        case snapshotGeneration, pendingDestinations, lastErrorCode, createdAt, updatedAt
    }

    /// Backward-compatible decode for PR #28 rows written before stage-aware resume existed.
    /// The persisted state and durable generation fields determine the first safe resume phase.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        scope = try container.decode(HistoricalAnalysisScope.self, forKey: .scope)
        firstReceiptGeneration = try container.decode(Int64.self, forKey: .firstReceiptGeneration)
        lastReceiptGeneration = try container.decode(Int64.self, forKey: .lastReceiptGeneration)
        minimumTs = try container.decodeIfPresent(Int.self, forKey: .minimumTs)
        maximumTs = try container.decodeIfPresent(Int.self, forKey: .maximumTs)
        affectedDays = try container.decode(Set<CivilDay>.self, forKey: .affectedDays)
        kind = try container.decode(HistoricalAnalysisWorkKind.self, forKey: .kind)
        recordedTimeZoneIdentifier = try container.decode(String.self, forKey: .recordedTimeZoneIdentifier)
        state = try container.decode(HistoricalAnalysisWorkState.self, forKey: .state)
        attemptCount = try container.decode(Int.self, forKey: .attemptCount)
        nextAttemptAt = try container.decodeIfPresent(Date.self, forKey: .nextAttemptAt)
        lease = try container.decodeIfPresent(HistoricalWorkLease.self, forKey: .lease)
        analyzedThroughReceiptGeneration = try container.decodeIfPresent(
            Int64.self,
            forKey: .analyzedThroughReceiptGeneration
        )
        analysisGeneration = try container.decodeIfPresent(Int64.self, forKey: .analysisGeneration)
        snapshotGeneration = try container.decodeIfPresent(Int64.self, forKey: .snapshotGeneration)
        pendingDestinations = try container.decodeIfPresent(
            Set<DownstreamDestination>.self,
            forKey: .pendingDestinations
        ) ?? []
        lastErrorCode = try container.decodeIfPresent(String.self, forKey: .lastErrorCode)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        resumePhase = try container.decodeIfPresent(
            HistoricalPipelineResumePhase.self,
            forKey: .resumePhase
        ) ?? Self.inferredResumePhase(
            state: state,
            analysisGeneration: analysisGeneration,
            snapshotGeneration: snapshotGeneration
        )
        try Self.validateDecoded(self)
    }

    public var isTerminal: Bool { state == .complete || state == .quarantined }

    public func canAttempt(at now: Date) -> Bool {
        guard state == .pending || state == .retryable else { return false }
        guard resumePhase != .done else { return false }
        guard lease == nil || lease!.expiresAt <= now else { return false }
        return nextAttemptAt.map { $0 <= now } ?? true
    }

    /// Coalesce only work that has not crossed the analysis edge. A running or published item retains its
    /// immutable receipt range; new receipts become a follow-up work item.
    public mutating func mergePending(_ other: HistoricalAnalysisWork, now: Date) throws {
        guard scope == other.scope,
              kind == other.kind,
              recordedTimeZoneIdentifier == other.recordedTimeZoneIdentifier,
              [HistoricalAnalysisWorkState.pending, .retryable].contains(state),
              [HistoricalAnalysisWorkState.pending, .retryable].contains(other.state),
              resumePhase == .analysis,
              other.resumePhase == .analysis,
              analysisGeneration == nil,
              other.analysisGeneration == nil,
              lease == nil,
              other.lease == nil else {
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

    static func inferredResumePhase(
        state: HistoricalAnalysisWorkState,
        analysisGeneration: Int64?,
        snapshotGeneration: Int64?
    ) -> HistoricalPipelineResumePhase {
        switch state {
        case .complete, .quarantined:
            return .done
        case .repositoryPublished:
            return .outboxCommit
        case .snapshotCommitted:
            return .repositoryPublication
        case .verifying:
            return .verification
        case .analyzing, .pending, .retryable, .blocked:
            if snapshotGeneration != nil { return .repositoryPublication }
            if analysisGeneration != nil { return .verification }
            return .analysis
        }
    }

    private static func validateDecoded(_ work: HistoricalAnalysisWork) throws {
        guard work.firstReceiptGeneration > 0,
              work.lastReceiptGeneration >= work.firstReceiptGeneration,
              TimeZone(identifier: work.recordedTimeZoneIdentifier) != nil,
              work.createdAt.timeIntervalSinceReferenceDate.isFinite,
              work.updatedAt.timeIntervalSinceReferenceDate.isFinite,
              work.attemptCount >= 0,
              work.nextAttemptAt?.timeIntervalSinceReferenceDate.isFinite ?? true else {
            throw HistoricalWorkError.invalidGeneration
        }
        if let minimumTs = work.minimumTs,
           let maximumTs = work.maximumTs,
           minimumTs > maximumTs {
            throw HistoricalWorkError.invalidRange
        }
        switch work.kind {
        case .exactDays:
            guard !work.affectedDays.isEmpty,
                  work.affectedDays.count <= Self.maximumExactDayCount else {
                throw HistoricalWorkError.invalidRange
            }
        case .fullHistoryRepair(let reason):
            guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HistoricalWorkError.invalidRange
            }
        }
        switch work.resumePhase {
        case .analysis:
            break
        case .verification:
            guard work.analyzedThroughReceiptGeneration == work.lastReceiptGeneration,
                  work.analysisGeneration.map({ $0 > 0 }) == true else {
                throw HistoricalWorkError.invalidTransition
            }
        case .repositoryPublication, .outboxCommit:
            guard work.analyzedThroughReceiptGeneration == work.lastReceiptGeneration,
                  work.analysisGeneration.map({ $0 > 0 }) == true,
                  work.snapshotGeneration.map({ $0 > 0 }) == true else {
                throw HistoricalWorkError.invalidTransition
            }
        case .done:
            guard work.isTerminal else { throw HistoricalWorkError.invalidTransition }
        }
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
