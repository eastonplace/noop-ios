#if os(iOS)
import Foundation
import HealthKit

extension HealthKitAnchorPager {
    /// Preserve the established HealthKitBridge call label while the pager's implementation keeps its concise
    /// internal `anchor:` spelling. This is a source-compatibility overload only; it delegates to the same
    /// bounded, paged scan and cannot create a second cursor or alter commit ordering.
    func scan(
        type: HKSampleType,
        predicate: NSPredicate?,
        priorAnchor: HKQueryAnchor?,
        handlePage: PageHandler? = nil
    ) async throws -> HealthKitAnchorScanResult {
        try await scan(
            type: type,
            predicate: predicate,
            anchor: priorAnchor,
            handlePage: handlePage)
    }
}
#endif
