import Foundation

public enum VerifiedSinkTransitionScope: Equatable, Sendable {
    case preserveCarryForward
    case clearPrivacyVisibleState
}

/// Target adapter for WidgetKit and ActivityKit lifecycle barriers. Core source
/// transitions can depend on this protocol without importing either framework.
@MainActor
public protocol VerifiedSinkLifecycle: Sendable {
    func prepareTransition(scope: VerifiedSinkTransitionScope) async
    func clearPrivacyVisibleState()
    @discardableResult
    func activate(contextId: String, epoch: UInt64) -> Bool
}
