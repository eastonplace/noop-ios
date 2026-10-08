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
#endif
