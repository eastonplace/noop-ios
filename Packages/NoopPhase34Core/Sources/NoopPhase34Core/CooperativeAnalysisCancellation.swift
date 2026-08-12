import Foundation

public enum CooperativeAnalysisCancellation {
    /// Parent cancellation explicitly cancels an unstructured/detached child.
    public static func runDetached<T: Sendable>(
        priority: TaskPriority = .utility,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let child = Task.detached(priority: priority, operation: operation)
        return try await withTaskCancellationHandler {
            try await child.value
        } onCancel: {
            child.cancel()
        }
    }

    @inline(__always)
    public static func checkpoint() throws {
        try Task.checkCancellation()
    }
}

/// Reducer event to add to HistoricalAnalysisWorkReducer and ExternalPublicationReducer.
/// Cancellation is not a failure and must not consume an attempt or wait for lease expiry.
public struct OwnedLeaseCancellation: Equatable, Sendable {
    public let owner: String
    public let code: String

    public init(owner: String, code: String = "owner_cancelled") {
        self.owner = owner
        self.code = code
    }
}

/*
IntelligenceEngine.analyzeRecent integration:

Replace:

    scanned = try await Task.detached(priority: .utility) { ... }.value

with:

    scanned = try await CooperativeAnalysisCancellation.runDetached {
        var out: [DayScan] = []
        for civilDay in civilDays {
            try CooperativeAnalysisCancellation.checkpoint()
            let bundle = try await store.analysisDayBundle(...)
            try CooperativeAnalysisCancellation.checkpoint()
            ...
            out.append(...)
        }
        return out
    }

Add checkpoints:

1. before baseline/full-history reads;
2. before and after each civil-day `analysisDayBundle`;
3. before optional 200k skin/HR/RR reads;
4. before returning from the detached scan;
5. immediately after `await`ing the scan on MainActor;
6. before each score/session/series persistence transaction;
7. before `recordAnalysisMutation`;
8. before Repository publication/outbox commit.

Cancellation handling in HistoricalPipelineCoordinator:

    } catch is CancellationError {
        try? await dependencies.applyEvent(
            leased.id,
            .cancelOwnedLease(owner: owner),
            dependencies.now()
        )
        return
    }

Reducer semantics for `.cancelOwnedLease(owner:)`:

- require the current lease owner to match;
- clear leaseOwner/leaseExpiresAt;
- preserve resumePhase and every durable generation;
- state becomes `.pending` when no analysis generation exists;
- otherwise state becomes the retryable phase represented by resumePhase;
- do not increment attemptCount;
- nextAttemptAt = nil;
- lastErrorCode = "owner_cancelled".

ExternalPublicationWorker uses the equivalent outbox event. Source transitions
must await this release before committing the new source, so a replacement owner
can lease immediately instead of waiting 60–90 seconds.
*/
