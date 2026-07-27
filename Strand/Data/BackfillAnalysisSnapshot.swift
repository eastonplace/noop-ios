import Foundation

/// Immutable observation around one post-backfill analysis pass. Home may publish only when the store is
/// still quiescent and the durable-data edge is unchanged after analysis. A reconnect or periodic burst that
/// starts or completes in the middle therefore requires another current-day pass instead of allowing an older
/// generation to publish a final-looking blank Recovery state.
struct BackfillAnalysisSnapshot: Equatable, Sendable {
    let dataAvailableAt: TimeInterval?
    let backfilling: Bool

    func isSettledAndUnchanged(since earlier: Self) -> Bool {
        !backfilling && !earlier.backfilling && dataAvailableAt == earlier.dataAvailableAt
    }
}
