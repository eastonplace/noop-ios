import Foundation

extension AppModel {
    /// Canonical user-initiated workout finish path. `endWorkout()` retains its existing scoring, persistence,
    /// read-back verification, and error semantics; this wrapper only supplies the narrow repository refresh
    /// intent inherited by the internal compatibility `repo.refresh()` call after a successful save.
    func endWorkoutOptimized() async -> Result<WorkoutRow, WorkoutFinishError> {
        await RepositoryRefreshContext.$disposition.withValue(.intent(.currentDay)) {
            await endWorkout()
        }
    }
}
