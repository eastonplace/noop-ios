import Foundation
import NoopPhase34Core

extension HistoricalPipelineRuntimeResult: DrainSignalResultAccumulating {
    static func combineDrainResults(_ accumulated: Any, _ next: Any) -> Any {
        guard let lhs = accumulated as? HistoricalPipelineRuntimeResult,
              let rhs = next as? HistoricalPipelineRuntimeResult else {
            return next
        }
        return HistoricalPipelineRuntimeResult(
            admittedReceipts: lhs.admittedReceipts + rhs.admittedReceipts,
            completedWork: lhs.completedWork + rhs.completedWork,
            deferredWork: lhs.deferredWork + rhs.deferredWork,
            pendingWork: rhs.pendingWork ?? lhs.pendingWork,
            alreadyRunning: lhs.alreadyRunning || rhs.alreadyRunning
        )
    }
}
