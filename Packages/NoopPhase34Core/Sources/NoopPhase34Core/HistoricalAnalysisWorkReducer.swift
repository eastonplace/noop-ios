import Foundation

public enum HistoricalWorkEvent: Equatable, Sendable {
    case acquireLease(owner: String, expiresAt: Date)
    case renewLease(owner: String, expiresAt: Date)
    case beginAnalysis(owner: String)
    case analysisSucceeded(
        owner: String,
        throughReceiptGeneration: Int64,
        analysisGeneration: Int64,
        analyzedDays: Set<CivilDay>
    )
    case verificationSucceeded(
        owner: String,
        throughReceiptGeneration: Int64,
        analysisGeneration: Int64,
        snapshotGeneration: Int64
    )
    case repositoryPublished(owner: String)
    case outboxCommitted(owner: String, destinations: Set<DownstreamDestination>)
    case failed(owner: String?, code: String, retryable: Bool)
    case leaseExpired
    case quarantine(code: String)
}

public enum HistoricalAnalysisWorkReducer {
    @discardableResult
    public static func apply(
        _ event: HistoricalWorkEvent,
        to work: inout HistoricalAnalysisWork,
        now: Date
    ) throws -> HistoricalAnalysisWork {
        switch event {
        case let .acquireLease(owner, expiresAt):
            guard work.canAttempt(at: now) else { throw HistoricalWorkError.invalidTransition }
            work.lease = try HistoricalWorkLease(owner: owner, expiresAt: expiresAt)
            work.updatedAt = now

        case let .renewLease(owner, expiresAt):
            try requireLease(owner, work: work, now: now)
            guard !work.isTerminal, expiresAt > now else {
                throw HistoricalWorkError.invalidTransition
            }
            work.lease = try HistoricalWorkLease(owner: owner, expiresAt: expiresAt)
            work.updatedAt = now

        case let .beginAnalysis(owner):
            try requireLease(owner, work: work, now: now)
            guard work.state == .pending || work.state == .retryable else {
                throw HistoricalWorkError.invalidTransition
            }
            work.state = .analyzing
            work.nextAttemptAt = nil
            work.updatedAt = now

        case let .analysisSucceeded(owner, throughReceiptGeneration, analysisGeneration, analyzedDays):
            try requireLease(owner, work: work, now: now)
            // Receipt, analysis, and snapshot generations are independent monotonic domains. Only compare
            // a receipt generation to another receipt generation; numeric cross-domain comparisons are invalid.
            guard work.state == .analyzing,
                  throughReceiptGeneration == work.lastReceiptGeneration,
                  analysisGeneration > 0,
                  work.affectedDays.isSubset(of: analyzedDays) else {
                throw HistoricalWorkError.invalidTransition
            }
            work.analyzedThroughReceiptGeneration = throughReceiptGeneration
            work.analysisGeneration = analysisGeneration
            work.state = .verifying
            work.updatedAt = now

        case let .verificationSucceeded(
            owner, throughReceiptGeneration, analysisGeneration, snapshotGeneration
        ):
            try requireLease(owner, work: work, now: now)
            guard work.state == .verifying,
                  throughReceiptGeneration == work.lastReceiptGeneration,
                  work.analyzedThroughReceiptGeneration == throughReceiptGeneration,
                  work.analysisGeneration == analysisGeneration,
                  snapshotGeneration > 0 else {
                throw HistoricalWorkError.invalidTransition
            }
            work.snapshotGeneration = snapshotGeneration
            work.state = .snapshotCommitted
            work.updatedAt = now

        case let .repositoryPublished(owner):
            try requireLease(owner, work: work, now: now)
            guard work.state == .snapshotCommitted else {
                throw HistoricalWorkError.invalidTransition
            }
            work.state = .repositoryPublished
            work.updatedAt = now

        case let .outboxCommitted(owner, destinations):
            try requireLease(owner, work: work, now: now)
            guard work.state == .repositoryPublished else {
                throw HistoricalWorkError.invalidTransition
            }
            // The external outbox owns all destination retries. Once its rows are durable, this analysis
            // work is complete and must release its lease. Keeping the analysis lease while HealthKit or Watch
            // retries would cause lease expiry to rescore an already-published generation.
            work.pendingDestinations = destinations
            work.state = .complete
            work.lease = nil
            work.updatedAt = now

        case let .failed(owner, code, retryable):
            if let owner { try requireLease(owner, work: work, now: now) }
            guard !work.isTerminal, !code.isEmpty else { throw HistoricalWorkError.invalidTransition }
            work.attemptCount += 1
            work.lastErrorCode = code
            work.lease = nil
            if retryable {
                work.state = .retryable
                work.nextAttemptAt = now.addingTimeInterval(retryDelay(attempt: work.attemptCount))
            } else {
                work.state = .quarantined
                work.nextAttemptAt = nil
            }
            work.updatedAt = now

        case .leaseExpired:
            guard let lease = work.lease, lease.expiresAt <= now, !work.isTerminal else {
                throw HistoricalWorkError.invalidTransition
            }
            work.attemptCount += 1
            work.lastErrorCode = "lease_expired"
            work.lease = nil
            work.state = .retryable
            work.nextAttemptAt = now.addingTimeInterval(retryDelay(attempt: work.attemptCount))
            work.updatedAt = now

        case let .quarantine(code):
            guard !work.isTerminal, !code.isEmpty else { throw HistoricalWorkError.invalidTransition }
            work.state = .quarantined
            work.lastErrorCode = code
            work.nextAttemptAt = nil
            work.lease = nil
            work.updatedAt = now
        }
        return work
    }

    public static func retryDelay(attempt: Int) -> TimeInterval {
        let clamped = max(1, min(attempt, 8))
        return min(15 * 60, pow(2, Double(clamped - 1)) * 5)
    }

    private static func requireLease(
        _ owner: String,
        work: HistoricalAnalysisWork,
        now: Date
    ) throws {
        guard let lease = work.lease else { throw HistoricalWorkError.wrongLeaseOwner }
        guard lease.owner == owner else { throw HistoricalWorkError.wrongLeaseOwner }
        guard lease.expiresAt > now else { throw HistoricalWorkError.leaseExpired }
    }
}
