import Foundation

/// Records permission-request completion, never a read grant. HealthKit does not disclose read
/// permission. Completed flows may attempt reads, which can legitimately return empty or fail.
/// Write authorization remains a separate per-type HealthKit check at each write site.
public struct HealthKitReadResumePolicy {
    public enum PriorRequestStatus: Sendable {
        case unknown, shouldRequest, unnecessary
    }

    private static let completedKey = "healthKit.permissionRequestCompleted.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var canAttemptReads: Bool { defaults.bool(forKey: Self.completedKey) }

    public func recordCompletedRequestFlow() {
        defaults.set(true, forKey: Self.completedKey)
    }

    /// The OS's nonprompting request-status probe can recover an old completed legacy request.
    /// `.unnecessary` says that a sheet is unnecessary for that set; it says nothing about grants.
    /// No status here requests permission, clears consent history, or infers reads from writes.
    @discardableResult
    public func resumeIfPreviouslyRequested(_ status: PriorRequestStatus) -> Bool {
        if status == .unnecessary { recordCompletedRequestFlow() }
        return canAttemptReads
    }
}
