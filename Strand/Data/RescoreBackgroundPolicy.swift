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


/// The background-execution assertion a rescore grant holds while it runs. Without one nothing keeps the process
/// alive: iOS suspends it a few seconds after the app leaves the screen, a grant that is frozen when the owner
/// comes back is cancelled, and its chunk replays from the same durable offset, so history that needs several
/// uninterrupted background stays may never finish. In production this is `UIApplication.beginBackgroundTask`.
struct BackgroundExecutionAssertion {
    /// Begins the assertion. `onExpiry` runs on the main actor when iOS is about to end the background time: the
    /// holder must stop its work and call `end` before it returns. nil: iOS granted none.
    let begin: @MainActor (_ onExpiry: @escaping @MainActor () -> Void) -> Int?
    /// Ends an assertion `begin` returned.
    let end: @MainActor (_ id: Int) -> Void

    static let uiApplication = BackgroundExecutionAssertion(
        begin: { onExpiry in
            #if os(iOS)
            let id = UIApplication.shared.beginBackgroundTask(withName: "NOOP history rescore") { onExpiry() }
            return id == .invalid ? nil : id.rawValue
            #else
            return nil
            #endif
        },
        end: { id in
            #if os(iOS)
            UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: id))
            #endif
        })
}

/// Owns the one maintenance rescore grant a scene edge may start. The v3/settle chunks are full-history work:
/// while one runs it holds `IntelligenceEngine.computing` and the store queue, which blocks post-sync scoring,
/// refreshes and edits. So a grant starts only when the app is genuinely in the background (not on an
/// `.inactive` edge), is paused the moment that stops being true, and is cancelled on return to the foreground.
/// A cancelled chunk never advances the durable cursor (`analyzeRecent` reports non-completion and the
/// migration throws), so the next grant replays it from the same offset.
///
/// A running grant holds a background-execution assertion, so the process stays alive for the chunk instead of
/// being frozen mid-way (see `BackgroundExecutionAssertion`). The assertion is ended exactly once, by whichever
/// comes first: the grant finishing, a cancel, or iOS calling the expiration handler.
///
/// A cancelled grant may still be inside the engine, waiting for its next checkpoint. A grant started in that
/// window waits for it first, so the engine's single-run guard never drops the new grant silently.
@MainActor
final class EffortRescoreGrant {
    /// One grant's assertion: begun at most once, ended at most once, never begun after it ended.
    @MainActor
    private final class Hold {
        private let assertion: BackgroundExecutionAssertion
        private var id: Int?
        private var ended = false

        init(_ assertion: BackgroundExecutionAssertion) { self.assertion = assertion }

        func begin(onExpiry: @escaping @MainActor () -> Void) {
            guard id == nil, !ended else { return }
            id = assertion.begin(onExpiry)
        }

        func end() {
            guard !ended else { return }
            ended = true
            guard let id else { return }
            self.id = nil
            assertion.end(id)
        }
    }

    private let assertion: BackgroundExecutionAssertion
    private var task: Task<Void, Never>?
    private var token: UUID?
    private var hold: Hold?
    /// The last cancelled grant, which may still be unwinding. The next `start` runs after it.
    private var unwinding: Task<Void, Never>?
    private var unwindingToken: UUID?

    init(assertion: BackgroundExecutionAssertion = .uiApplication) {
        self.assertion = assertion
    }

    /// A grant is pending its start checks or running.
    var isActive: Bool { task != nil }

    /// A cancelled grant has not finished unwinding.
    var isUnwinding: Bool { unwinding != nil }

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
        let hold = Hold(assertion)
        let previous = unwinding
        self.token = token
        self.hold = hold
        unwinding = nil
        unwindingToken = nil
        task = Task(priority: .background) { [weak self] in
            await previous?.value
            if !Task.isCancelled, isBackground(), mayRun() {
                hold.begin { [weak self] in
                    guard let self else { hold.end(); return }
                    self.expire(token, hold: hold)
                }
                await run { !isBackground() || !mayRun() }
            }
            hold.end()
            self?.finish(token)
        }
    }

    /// Foreground return: stop the in-flight grant and release its assertion. Its chunk unwinds at the next
    /// cooperative checkpoint; a grant started before it has finished waits for that.
    func cancel() {
        guard let running = task else { return }
        running.cancel()
        unwinding = running
        unwindingToken = token
        task = nil
        token = nil
        hold?.end()
        hold = nil
    }

    /// Suspends until the live grant, or one still unwinding, has finished. Cancelling the caller cancels the grant.
    func waitUntilIdle() async {
        guard let running = task ?? unwinding else { return }
        await withTaskCancellationHandler {
            await running.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    /// iOS is about to end the background time: stop the grant and end the assertion before returning.
    private func expire(_ token: UUID, hold: Hold) {
        if self.token == token { cancel() } else { hold.end() }
    }

    private func finish(_ finished: UUID) {
        if unwindingToken == finished {
            unwinding = nil
            unwindingToken = nil
        }
        guard token == finished else { return }
        task = nil
        token = nil
        hold = nil
    }
}
