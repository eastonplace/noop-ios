#if os(iOS)
import Foundation
import WidgetKit

/// The iOS boundary that makes source transitions visible to system surfaces.
/// Core lifecycle code persists the transition. This adapter performs the
/// ordered WidgetKit and ActivityKit barrier work for that durable transition.
@MainActor
final class IOSVerifiedSinkLifecycle: VerifiedSinkLifecycle {
    struct Dependencies {
        let suspendAndEndLiveActivity: @MainActor @Sendable () async -> Void
        let clearWidgetState: @MainActor @Sendable () -> Void
        let reloadWidgets: @MainActor @Sendable () -> Void
        let activateLiveActivity: @MainActor @Sendable (_ contextId: String, _ epoch: UInt64) -> Bool
    }

    private let dependencies: Dependencies

    init(liveActivity: LiveActivityController) {
        self.dependencies = Dependencies(
            suspendAndEndLiveActivity: {
                await liveActivity.suspendForSourceTransition()
            },
            clearWidgetState: {
                guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName) else { return }
                ActiveSinkEpochRecovery.clearVerifiedWidgetState(defaults: defaults)
                ActiveSinkEpochRecovery.clearLiveActivityGeneration(defaults: defaults)
            },
            reloadWidgets: {
                WidgetCenter.shared.reloadAllTimelines()
            },
            activateLiveActivity: { contextId, epoch in
                liveActivity.activateVerifiedSink(contextId: contextId, epoch: epoch)
            }
        )
    }

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// The ActivityKit barrier completes before any privacy-visible Widget state
    /// is cleared. A process death therefore cannot race an older live command.
    func prepareTransition(scope: VerifiedSinkTransitionScope) async {
        await dependencies.suspendAndEndLiveActivity()
        if scope == .clearPrivacyVisibleState {
            clearPrivacyVisibleState()
        }
    }

    func clearPrivacyVisibleState() {
        dependencies.clearWidgetState()
        dependencies.reloadWidgets()
    }

    /// Resume the lifecycle lane only when the App Group token matches the
    /// context and epoch that core transition recovery activated.
    @discardableResult
    func activate(contextId: String, epoch: UInt64) -> Bool {
        guard dependencies.activateLiveActivity(contextId, epoch) else { return false }
        dependencies.reloadWidgets()
        return true
    }
}
#endif
