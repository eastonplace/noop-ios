#if os(iOS)
import Foundation

/// Every `BGTaskScheduler.register(forTaskWithIdentifier:using:launchHandler:)` in the app passes this queue.
///
/// The registrars are `@MainActor`, so their launch-handler closures inherit main-actor isolation. With
/// `using: nil` iOS invokes the handler on a BackgroundTasks worker queue, and Swift 6's runtime isolation
/// check traps (`_dispatch_assert_queue_fail`), killing the app whenever a background task fires, mid-workout
/// included. Delivering on the main queue satisfies that check. Expiration handlers may still be invoked
/// from any queue, so each registrar builds them `nonisolated` and `@Sendable`.
enum BackgroundTaskLaunchPolicy {
    static let launchQueue: DispatchQueue = .main
}

/// Heavy BGProcessingTask work (rescoring, privacy cleanup, a history offload) must not run while a run or lift
/// is active: iOS kills a background app that holds 80% CPU for 60 s, and a history offload also suspends the
/// realtime-HR keep-alive. When one fires mid-session the registrar re-arms its request for later and completes
/// the task unsuccessfully instead of running. The app wires `isActive` at launch (before any handler can fire,
/// including on a background relaunch that rehydrates an in-flight run).
@MainActor
enum ActiveSessionGate {
    static var isActive: () -> Bool = { false }
    /// How long a deferred request waits before iOS may offer it again.
    static let retryDelay: TimeInterval = 15 * 60
}
#endif
