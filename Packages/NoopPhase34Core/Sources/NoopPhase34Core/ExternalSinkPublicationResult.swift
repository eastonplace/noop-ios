import Foundation

/// A durable outbox row is acknowledged only after the sink reports one of
/// these outcomes. `superseded` is a successful no-op for a stale latest-state
/// row, but remains distinct for diagnostics and monotonic ordering.
public enum ExternalSinkPublicationResult: Equatable, Sendable {
    case published
    case alreadyCurrent
    case superseded
    case notApplicable
}
