import Foundation
#if os(iOS)
import UIKit
#endif

/// Keeps long recovery scoring below iOS's background CPU watchdog while preserving the existing durable
/// historical pipeline as the only owner of deferred work.
enum RescoreBackgroundPolicy {
    enum Trigger: Equatable, Sendable {
        case durablePipeline
        case cadenceBackstop
    }

    enum Decision: Equatable, Sendable {
        case run
        /// Start the paced pass now and keep a discretionary processing request armed in case iOS ends the
        /// current Bluetooth wake before the durable pipeline drains.
        case runWithBackgroundFallback
        case skip
    }

    static let backgroundWorkQuantumSeconds: Double = 10
    static let backgroundRestPerWorkSecond: Double = 1
    static let maxBackgroundRestSeconds: Double = 30

    static func restSeconds(afterWorkSeconds workSeconds: Double, isBackground: Bool) -> Double {
        guard isBackground,
              workSeconds.isFinite,
              workSeconds >= backgroundWorkQuantumSeconds else { return 0 }
        return min(workSeconds * backgroundRestPerWorkSecond, maxBackgroundRestSeconds)
    }

    @MainActor
    static var isBackgrounded: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState != .active
        #else
        false
        #endif
    }

    /// True only once iOS has actually moved the app to the background. `isBackgrounded` also counts
    /// `.inactive` (Control Center, the notification shade, the app switcher, an incoming call), where the user
    /// is still looking at the app and a full-history chunk would run flat out in the foreground.
    @MainActor
    static var isGenuinelyBackground: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .background
        #else
        false
        #endif
    }

    /// Rest after each accumulated work quantum while iOS keeps the process alive in the background. The
    /// throwing sleep is deliberate: BG task expiration must cancel the detached analysis and return its
    /// durable lease to pending instead of letting CPU work continue after the grant ends.
    static func paceIfBackgrounded(since mark: inout UInt64) async throws {
        let now = DispatchTime.now().uptimeNanoseconds
        let workSeconds = Double(now &- mark) / 1_000_000_000
        let background = await MainActor.run { isBackgrounded }
        let rest = restSeconds(afterWorkSeconds: workSeconds, isBackground: background)
        if rest > 0 {
            try await Task.sleep(for: .seconds(rest))
        }
        if rest > 0 || !background {
            mark = DispatchTime.now().uptimeNanoseconds
        }
    }

    static func decide(
        isBackground: Bool,
        trigger: Trigger,
        hasBackgroundGrant: Bool
    ) -> Decision {
        guard isBackground else { return .run }
        if hasBackgroundGrant { return .run }
        switch trigger {
        case .durablePipeline:
            return .runWithBackgroundFallback
        case .cadenceBackstop:
            return .skip
        }
    }
}


/// Owns the one maintenance rescore grant a scene edge may start. The v3/settle chunks are full-history work:
/// while one runs it holds `IntelligenceEngine.computing` and the store queue, which blocks post-sync scoring,
/// refreshes and edits. So a grant starts only when the app is genuinely in the background (not on an
/// `.inactive` edge), is paused the moment that stops being true, and is cancelled on return to the foreground.
/// A cancelled chunk never advances the durable cursor (`analyzeRecent` reports non-completion and the
/// migration throws), so the next grant replays it from the same offset.
@MainActor
final class EffortRescoreGrant {
    private var task: Task<Void, Never>?
    private var token: UUID?

    /// A grant is pending its start checks or running.
    var isActive: Bool { task != nil }

    /// - Parameters:
    ///   - isBackground: iOS has moved the app to the background. Checked when the grant starts and again
    ///     before every chunk (through `shouldPause`), which is after the first `await` of the migration.
    ///   - mayRun: the other gates (first paint done, no import, no strap backfill, no workout, not active).
    ///   - run: the migration. It must poll the `shouldPause` it is handed between chunks.
    func start(
        isBackground: @escaping @MainActor () -> Bool,
        mayRun: @escaping @MainActor () -> Bool,
        run: @escaping @MainActor (_ shouldPause: () -> Bool) async -> Void
    ) {
        guard task == nil else { return }
        let token = UUID()
        self.token = token
        task = Task(priority: .background) { [weak self] in
            if isBackground(), mayRun() {
                await run { !isBackground() || !mayRun() }
            }
            self?.finish(token)
        }
    }

    /// Foreground return: stop the in-flight grant. Its chunk unwinds at the next cooperative checkpoint.
    func cancel() {
        task?.cancel()
        task = nil
        token = nil
    }

    private func finish(_ finished: UUID) {
        guard token == finished else { return }
        task = nil
        token = nil
    }
}
