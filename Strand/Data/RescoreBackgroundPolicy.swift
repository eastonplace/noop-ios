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
