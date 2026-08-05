import Foundation

public enum ExternalPublicationState: String, Codable, Sendable {
    case pending
    case inFlight
    case retryable
    /// Waiting for user authorization or protected data. It is rearmed by an explicit signal.
    case blocked
    case succeeded
    /// A newer verified snapshot replaced this undelivered latest-state item. Historical HealthKit work is
    /// never superseded because every analyzed day must be exported at least once.
    case superseded
    case quarantined
}

public struct ExternalPublicationOutboxItem: Codable, Equatable, Sendable {
    public static let maximumAutomaticAttempts = 12

    public let idempotencyKey: String
    public let contextId: String
    public let deviceId: String
    public let snapshotGeneration: Int64
    public let analysisGeneration: Int64
    public let changedDays: Set<CivilDay>
    /// The recorded calendar context for changed day keys. HealthKit must not reinterpret them through a
    /// later phone time zone after travel or a daylight-saving transition.
    public let recordedTimeZoneIdentifier: String
    /// HealthKit receives the exact mutation projection produced by the analysis generation.
    public let healthKitPayload: HistoricalHealthKitMutationPayload?
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
        recordedTimeZoneIdentifier: String = "UTC",
        healthKitPayload: HistoricalHealthKitMutationPayload? = nil,
        destination: DownstreamDestination,
        createdAt: Date
    ) throws {
        guard !contextId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              snapshotGeneration > 0,
              analysisGeneration > 0,
              !changedDays.isEmpty,
              TimeZone(identifier: recordedTimeZoneIdentifier) != nil,
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
        self.recordedTimeZoneIdentifier = recordedTimeZoneIdentifier
        self.healthKitPayload = healthKitPayload
        self.destination = destination
        self.state = .pending
        self.attemptCount = 0
        self.nextAttemptAt = nil
        self.lease = nil
        self.lastErrorCode = nil
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case idempotencyKey, contextId, deviceId, snapshotGeneration, analysisGeneration
        case changedDays, recordedTimeZoneIdentifier, healthKitPayload, destination, state, attemptCount
        case nextAttemptAt, lease, lastErrorCode, createdAt, updatedAt
    }

    /// PR #28 rows did not persist a zone. Decode with UTC only so old data is deterministic. The SQL migration
    /// replaces UTC with the owning work row's recorded zone before the item becomes leaseable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        idempotencyKey = try container.decode(String.self, forKey: .idempotencyKey)
        contextId = try container.decode(String.self, forKey: .contextId)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        snapshotGeneration = try container.decode(Int64.self, forKey: .snapshotGeneration)
        analysisGeneration = try container.decode(Int64.self, forKey: .analysisGeneration)
        changedDays = try container.decode(Set<CivilDay>.self, forKey: .changedDays)
        recordedTimeZoneIdentifier = try container.decodeIfPresent(
            String.self,
            forKey: .recordedTimeZoneIdentifier
        ) ?? "UTC"
        healthKitPayload = try container.decodeIfPresent(
            HistoricalHealthKitMutationPayload.self,
            forKey: .healthKitPayload
        )
        destination = try container.decode(DownstreamDestination.self, forKey: .destination)
        state = try container.decode(ExternalPublicationState.self, forKey: .state)
        attemptCount = try container.decode(Int.self, forKey: .attemptCount)
        nextAttemptAt = try container.decodeIfPresent(Date.self, forKey: .nextAttemptAt)
        lease = try container.decodeIfPresent(HistoricalWorkLease.self, forKey: .lease)
        lastErrorCode = try container.decodeIfPresent(String.self, forKey: .lastErrorCode)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        guard idempotencyKey == Self.makeIdempotencyKey(
            contextId: contextId,
            snapshotGeneration: snapshotGeneration,
            analysisGeneration: analysisGeneration,
            destination: destination
        ),
        !changedDays.isEmpty,
        TimeZone(identifier: recordedTimeZoneIdentifier) != nil,
        attemptCount >= 0 else {
            throw ExternalPublicationError.invalidIdentity
        }
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
    case blocked(owner: String, code: String)
    case resumeBlocked
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
            guard item.state == .inFlight,
                  !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ExternalPublicationError.invalidTransition
            }
            item.attemptCount += 1
            item.lastErrorCode = code
            item.lease = nil
            let canRetry = retryable
                && item.attemptCount < ExternalPublicationOutboxItem.maximumAutomaticAttempts
            if canRetry {
                item.state = .retryable
                item.nextAttemptAt = now.addingTimeInterval(
                    HistoricalAnalysisWorkReducer.retryDelay(attempt: item.attemptCount)
                )
            } else {
                item.state = .quarantined
                item.nextAttemptAt = nil
                if retryable { item.lastErrorCode = "retry_limit_exceeded:" + code }
            }
            item.updatedAt = now


        case let .blocked(owner, code):
            try requireLease(owner, item: item, now: now)
            guard item.state == .inFlight,
                  !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ExternalPublicationError.invalidTransition
            }
            item.state = .blocked
            item.lastErrorCode = code
            item.lease = nil
            item.nextAttemptAt = nil
            item.updatedAt = now

        case .resumeBlocked:
            guard item.state == .blocked, item.lease == nil else {
                throw ExternalPublicationError.invalidTransition
            }
            item.state = .retryable
            item.nextAttemptAt = now
            item.updatedAt = now

        case .leaseExpired:
            guard let lease = item.lease, lease.expiresAt <= now, !item.isTerminal else {
                throw ExternalPublicationError.invalidTransition
            }
            item.attemptCount += 1
            item.lastErrorCode = "lease_expired"
            item.lease = nil
            if item.attemptCount < ExternalPublicationOutboxItem.maximumAutomaticAttempts {
                item.state = .retryable
                item.nextAttemptAt = now.addingTimeInterval(
                    HistoricalAnalysisWorkReducer.retryDelay(attempt: item.attemptCount)
                )
            } else {
                item.state = .quarantined
                item.nextAttemptAt = nil
                item.lastErrorCode = "retry_limit_exceeded:lease_expired"
            }
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
