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
