import Foundation

extension HistoricalPipelineDrainResult: DrainSignalResultAccumulating {
    public static func combineDrainResults(_ accumulated: Any, _ next: Any) -> Any {
        guard let lhs = accumulated as? HistoricalPipelineDrainResult,
              let rhs = next as? HistoricalPipelineDrainResult else {
            return next
        }
        return HistoricalPipelineDrainResult(
            completedWorkCount: lhs.completedWorkCount + rhs.completedWorkCount,
            deferredWorkCount: lhs.deferredWorkCount + rhs.deferredWorkCount,
            alreadyDraining: lhs.alreadyDraining || rhs.alreadyDraining
        )
    }
}
