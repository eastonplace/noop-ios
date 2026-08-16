import Foundation

/// The smallest decision surface for normal-launch verified-sink repair.
///
/// This policy is intentionally pure. AppModel must still run the selected action
/// under `sourceTransitionFence`, after durable transition recovery, and must not
/// signal publication until both iOS sink activations succeed.
public enum VerifiedSinkBootstrapDecision: Equatable, Sendable {
    case keep
    case waitForPendingTransition
    case clearClosedSource
    case activate(contextId: String)
}

public enum VerifiedSinkBootstrapPolicy {
    public static func decide(
        activeToken: VerifiedSinkToken?,
        expectedContextId: String?,
        hasPendingTransition: Bool
    ) -> VerifiedSinkBootstrapDecision {
        if hasPendingTransition {
            return .waitForPendingTransition
        }

        guard let expectedContextId = expectedContextId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expectedContextId.isEmpty else {
            return .clearClosedSource
        }

        if activeToken?.contextId == expectedContextId {
            return .keep
        }
        return .activate(contextId: expectedContextId)
    }
}
