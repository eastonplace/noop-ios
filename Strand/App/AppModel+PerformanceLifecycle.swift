import Foundation

/// The scene-phase bridge deliberately has no migration of its own. `AppModel.setApplicationActive(_:)`
/// remains the one owner of the active flag, workout flush, and the guarded/resumable Effort migration.
///
/// A second 4,000-day driver existed here alongside the launch/cadence owner in `AppModel`. That let a
/// foreground transition contend with live sleep analysis while bypassing the engine's single admission
/// guard. Keep this seam as a forwarding adapter: lifecycle state is applied exactly once and all migration
/// admission continues through the established guard.
@MainActor
enum PerformanceLifecycleOwnership {
    static func apply(_ active: Bool, using standardLifecycle: (Bool) -> Void) {
        standardLifecycle(active)
    }
}

extension AppModel {
    func setApplicationActiveOptimized(_ active: Bool) {
        // Presentation time has its own lifecycle. Re-arm on every active transition so a suspended app,
        // timezone change, or wall-clock correction recomputes the next midnight/04:00 boundary correctly.
        TodayDayBoundaryScheduler.shared.setActive(active, repository: repo)
        PerformanceLifecycleOwnership.apply(active) { [weak self] active in
            self?.setApplicationActive(active)
        }
    }
}

/// Unbalanced view dismissals must never release the recording session's realtime lease.
enum WorkoutRealtimeLeasePolicy {
    static func remaining(afterRelease count: Int, workoutOwnsLease: Bool) -> Int {
        max(workoutOwnsLease ? 1 : 0, count - 1)
    }
}

/// The Lift provider's paired async begin/end calls share this owner. Every begin owns one token;
/// cancellation or provider teardown can release only the tokens acquired by this provider.
@MainActor
final class RealtimeHRLeaseOwner {
    private weak var model: AppModel?
    private let consumer: RealtimeHRConsumer
    private var tokens: [RealtimeHRLeaseToken] = []

    init(model: AppModel, consumer: RealtimeHRConsumer) {
        self.model = model
        self.consumer = consumer
    }

    func begin() {
        if let token = model?.acquireRealtimeHR(for: consumer) { tokens.append(token) }
    }

    func end() {
        if let token = tokens.popLast() { model?.releaseRealtimeHR(token) }
    }

    deinit {
        let heldTokens = tokens
        Task { @MainActor [weak model] in
            for token in heldTokens { model?.releaseRealtimeHR(token) }
        }
    }
}
