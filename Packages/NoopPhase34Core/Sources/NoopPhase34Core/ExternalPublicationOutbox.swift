import Foundation

public enum ExternalPublicationState: String, Codable, Sendable {
    case pending
    case inFlight
    case retryable
    case succeeded
    /// A newer verified snapshot replaced this undelivered latest-state item. Historical HealthKit work is
    /// never superseded because every analyzed day must be exported at least once.
    case superseded
    case quarantined
}

public struct ExternalPublicationOutboxItem: Codable, Equatable, Sendable {
    public let idempotencyKey: String
    public let contextId: String
    public let deviceId: String
    public let snapshotGeneration: Int64
    public let analysisGeneration: Int64
    public let changedDays: Set<CivilDay>
    public let destination: DownstreamDestination
    public var state: ExternalPublicationState
    public var attemptCount: Int
    public var nextAttemptAt: Date?
    public var lease: HistoricalWorkLease?
    public var lastErrorCode: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        contextId: String,
        deviceId: String,
        snapshotGeneration: Int64,
        analysisGeneration: Int64,
        changedDays: Set<CivilDay>,
        destination: DownstreamDestination,
        createdAt: Date
    ) throws {
        guard !contextId.isEmpty,
              !deviceId.isEmpty,
              snapshotGeneration > 0,
              analysisGeneration > 0,
              !changedDays.isEmpty,
              createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw ExternalPublicationError.invalidIdentity
        }
        self.idempotencyKey = Self.makeIdempotencyKey(
            contextId: contextId,
            snapshotGeneration: snapshotGeneration,
            analysisGeneration: analysisGeneration,
            destination: destination
        )
        self.contextId = contextId
        self.deviceId = deviceId
        self.snapshotGeneration = snapshotGeneration
        self.analysisGeneration = analysisGeneration
        self.changedDays = changedDays
        self.destination = destination
        self.state = .pending
        self.attemptCount = 0
        self.nextAttemptAt = nil
        self.lease = nil
        self.lastErrorCode = nil
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    /// Widget, Live Activity, and Watch are latest-state destinations. HealthKit is a historical mutation
    /// destination, so its replay identity is the analysis generation rather than the current snapshot.
    public static func makeIdempotencyKey(
        contextId: String,
        snapshotGeneration: Int64,
        analysisGeneration: Int64,
        destination: DownstreamDestination
    ) -> String {
        switch destination {
        case .healthKit:
            return [contextId, "analysis", String(analysisGeneration), destination.rawValue]
                .joined(separator: "|")
        case .widget, .liveActivity, .watch:
            return [contextId, "snapshot", String(snapshotGeneration), destination.rawValue]
                .joined(separator: "|")
        }
    }

    public var isLatestStateDestination: Bool {
        switch destination {
        case .widget, .liveActivity, .watch: return true
        case .healthKit: return false
        }
    }

    public var isTerminal: Bool {
        state == .succeeded || state == .superseded || state == .quarantined
    }

    public func canAttempt(at now: Date) -> Bool {
        guard state == .pending || state == .retryable else { return false }
        guard lease == nil || lease!.expiresAt <= now else { return false }
        return nextAttemptAt.map { $0 <= now } ?? true
    }
}

public enum ExternalPublicationEvent: Equatable, Sendable {
    case acquire(owner: String, expiresAt: Date)
    case renew(owner: String, expiresAt: Date)
    case begin(owner: String)
    case succeeded(owner: String)
    /// Store-side latest-state coalescing. Only an unleased pending/retryable item may be superseded.
    case supersede
    case failed(owner: String, code: String, retryable: Bool)
    case leaseExpired
}

public enum ExternalPublicationError: Error, Equatable, Sendable {
    case invalidIdentity
    case invalidTransition
    case wrongLeaseOwner
    case leaseExpired
}

public enum ExternalPublicationReducer {
    @discardableResult
    public static func apply(
        _ event: ExternalPublicationEvent,
        to item: inout ExternalPublicationOutboxItem,
        now: Date
    ) throws -> ExternalPublicationOutboxItem {
        switch event {
        case let .acquire(owner, expiresAt):
            guard item.canAttempt(at: now) else { throw ExternalPublicationError.invalidTransition }
            item.lease = try HistoricalWorkLease(owner: owner, expiresAt: expiresAt)
            item.updatedAt = now

        case let .renew(owner, expiresAt):
            try requireLease(owner, item: item, now: now)
            guard !item.isTerminal, expiresAt > now else {
                throw ExternalPublicationError.invalidTransition
            }
            item.lease = try HistoricalWorkLease(owner: owner, expiresAt: expiresAt)
            item.updatedAt = now

        case let .begin(owner):
            try requireLease(owner, item: item, now: now)
            guard item.state == .pending || item.state == .retryable else {
                throw ExternalPublicationError.invalidTransition
            }
            item.state = .inFlight
            item.updatedAt = now

        case let .succeeded(owner):
            try requireLease(owner, item: item, now: now)
            guard item.state == .inFlight else { throw ExternalPublicationError.invalidTransition }
            item.state = .succeeded
            item.lease = nil
            item.nextAttemptAt = nil
            item.lastErrorCode = nil
            item.updatedAt = now

        case .supersede:
            guard item.isLatestStateDestination,
                  item.lease == nil,
                  item.state == .pending || item.state == .retryable else {
                throw ExternalPublicationError.invalidTransition
            }
            item.state = .superseded
            item.nextAttemptAt = nil
            item.lastErrorCode = "superseded_by_newer_snapshot"
            item.updatedAt = now

        case let .failed(owner, code, retryable):
            try requireLease(owner, item: item, now: now)
            guard item.state == .inFlight, !code.isEmpty else {
                throw ExternalPublicationError.invalidTransition
            }
            item.attemptCount += 1
            item.lastErrorCode = code
            item.lease = nil
            if retryable {
                item.state = .retryable
                item.nextAttemptAt = now.addingTimeInterval(
                    HistoricalAnalysisWorkReducer.retryDelay(attempt: item.attemptCount)
                )
            } else {
                item.state = .quarantined
                item.nextAttemptAt = nil
            }
            item.updatedAt = now

        case .leaseExpired:
            guard let lease = item.lease, lease.expiresAt <= now, !item.isTerminal else {
                throw ExternalPublicationError.invalidTransition
            }
            item.attemptCount += 1
            item.lastErrorCode = "lease_expired"
            item.lease = nil
            item.state = .retryable
            item.nextAttemptAt = now.addingTimeInterval(
                HistoricalAnalysisWorkReducer.retryDelay(attempt: item.attemptCount)
            )
            item.updatedAt = now
        }
        return item
    }

    private static func requireLease(
        _ owner: String,
        item: ExternalPublicationOutboxItem,
        now: Date
    ) throws {
        guard let lease = item.lease, lease.owner == owner else {
            throw ExternalPublicationError.wrongLeaseOwner
        }
        guard lease.expiresAt > now else { throw ExternalPublicationError.leaseExpired }
    }
}
