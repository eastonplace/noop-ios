import Foundation

public enum HistoricalWorkEvent: Equatable, Sendable {
    case acquireLease(owner: String, expiresAt: Date)
    case renewLease(owner: String, expiresAt: Date)
    /// Start or resume the side effect named by `work.resumePhase`.
    case beginCurrentPhase(owner: String)
    /// Compatibility alias for callers that know the work is still at `.analysis`.
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
    case blocked(owner: String?, code: String)
    case resumeBlocked
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
            guard work.resumePhase == .analysis else {
                throw HistoricalWorkError.invalidTransition
            }
            try beginCurrentPhase(owner: owner, work: &work, now: now)

        case let .beginCurrentPhase(owner):
            try beginCurrentPhase(owner: owner, work: &work, now: now)

        case let .analysisSucceeded(owner, throughReceiptGeneration, analysisGeneration, analyzedDays):
            try requireLease(owner, work: work, now: now)
            guard work.state == .analyzing,
                  work.resumePhase == .analysis,
                  throughReceiptGeneration == work.lastReceiptGeneration,
                  analysisGeneration > 0,
                  work.affectedDays.isSubset(of: analyzedDays) else {
                throw HistoricalWorkError.invalidTransition
            }
            work.analyzedThroughReceiptGeneration = throughReceiptGeneration
            work.analysisGeneration = analysisGeneration
            work.state = .verifying
            work.resumePhase = .verification
            work.updatedAt = now

        case let .verificationSucceeded(
            owner, throughReceiptGeneration, analysisGeneration, snapshotGeneration
        ):
            try requireLease(owner, work: work, now: now)
            guard work.state == .verifying,
                  work.resumePhase == .verification,
                  throughReceiptGeneration == work.lastReceiptGeneration,
                  work.analyzedThroughReceiptGeneration == throughReceiptGeneration,
                  work.analysisGeneration == analysisGeneration,
                  snapshotGeneration > 0 else {
                throw HistoricalWorkError.invalidTransition
            }
            work.snapshotGeneration = snapshotGeneration
            work.state = .snapshotCommitted
            work.resumePhase = .repositoryPublication
            work.updatedAt = now

        case let .repositoryPublished(owner):
            try requireLease(owner, work: work, now: now)
            guard work.state == .snapshotCommitted,
                  work.resumePhase == .repositoryPublication else {
                throw HistoricalWorkError.invalidTransition
            }
            work.state = .repositoryPublished
            work.resumePhase = .outboxCommit
            work.updatedAt = now

        case let .outboxCommitted(owner, destinations):
            try requireLease(owner, work: work, now: now)
            guard work.state == .repositoryPublished,
                  work.resumePhase == .outboxCommit else {
                throw HistoricalWorkError.invalidTransition
            }
            work.pendingDestinations = destinations
            work.state = .complete
            work.resumePhase = .done
            work.lease = nil
            work.nextAttemptAt = nil
            work.lastErrorCode = nil
            work.updatedAt = now

        case let .failed(owner, code, retryable):
            if let owner { try requireLease(owner, work: work, now: now) }
            guard !work.isTerminal,
                  !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HistoricalWorkError.invalidTransition
            }
            work.attemptCount += 1
            work.lastErrorCode = code
            work.lease = nil
            let canRetry = retryable
                && work.attemptCount < HistoricalAnalysisWork.maximumAutomaticAttempts
            if canRetry {
                work.state = .retryable
                work.nextAttemptAt = now.addingTimeInterval(retryDelay(attempt: work.attemptCount))
            } else {
                work.state = .quarantined
                work.resumePhase = .done
                work.nextAttemptAt = nil
                if retryable { work.lastErrorCode = "retry_limit_exceeded:" + code }
            }
            work.updatedAt = now


        case let .blocked(owner, code):
            if let owner { try requireLease(owner, work: work, now: now) }
            guard !work.isTerminal,
                  !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HistoricalWorkError.invalidTransition
            }
            work.state = .blocked
            work.lastErrorCode = code
            work.lease = nil
            work.nextAttemptAt = nil
            work.updatedAt = now

        case .resumeBlocked:
            guard work.state == .blocked else { throw HistoricalWorkError.invalidTransition }
            work.state = .retryable
            work.nextAttemptAt = now
            work.lease = nil
            work.updatedAt = now

        case .leaseExpired:
            guard let lease = work.lease, lease.expiresAt <= now, !work.isTerminal else {
                throw HistoricalWorkError.invalidTransition
            }
            work.attemptCount += 1
            work.lastErrorCode = "lease_expired"
            work.lease = nil
            if work.attemptCount < HistoricalAnalysisWork.maximumAutomaticAttempts {
                work.state = .retryable
                work.nextAttemptAt = now.addingTimeInterval(retryDelay(attempt: work.attemptCount))
            } else {
                work.state = .quarantined
                work.resumePhase = .done
                work.nextAttemptAt = nil
                work.lastErrorCode = "retry_limit_exceeded:lease_expired"
            }
            work.updatedAt = now

        case let .quarantine(code):
            guard !work.isTerminal,
                  !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HistoricalWorkError.invalidTransition
            }
            work.state = .quarantined
            work.resumePhase = .done
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

    private static func beginCurrentPhase(
        owner: String,
        work: inout HistoricalAnalysisWork,
        now: Date
    ) throws {
        try requireLease(owner, work: work, now: now)
        guard work.state == .pending || work.state == .retryable else {
            throw HistoricalWorkError.invalidTransition
        }
        switch work.resumePhase {
        case .analysis:
            work.state = .analyzing
        case .verification:
            guard work.analysisGeneration != nil else {
                throw HistoricalWorkError.invalidTransition
            }
            work.state = .verifying
        case .repositoryPublication:
            guard work.snapshotGeneration != nil else {
                throw HistoricalWorkError.invalidTransition
            }
            work.state = .snapshotCommitted
        case .outboxCommit:
            guard work.snapshotGeneration != nil else {
                throw HistoricalWorkError.invalidTransition
            }
            work.state = .repositoryPublished
        case .done:
            throw HistoricalWorkError.invalidTransition
        }
        work.nextAttemptAt = nil
        work.updatedAt = now
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
