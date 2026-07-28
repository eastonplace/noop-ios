import XCTest
@testable import NOOP

@MainActor
final class IntelligenceAnalysisPublicationContractTests: XCTestCase {
    func testThreeLabelPublicationOverloadReturnsCompletionStatus() {
        // Compile-time contract only: HealthKit and post-source publication paths must be able to fail closed.
        // If this overload drifts back to Void, the assignment fails to compile before a stale Home generation
        // can ship behind an apparently-passing string audit.
        let operation: @MainActor (IntelligenceEngine) async -> Bool = { engine in
            await engine.analyzeRecent(
                maxDays: 21,
                startOffset: 0,
                refreshRepository: false)
        }
        _ = operation
    }
}
