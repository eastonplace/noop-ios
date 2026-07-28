import XCTest
@testable import NOOP

@MainActor
final class IntelligenceAnalysisPublicationContractTests: XCTestCase {
    func testThreeLabelPublicationOverloadReturnsCompletionStatus() {
        // Compile-time contract only: publication paths must be able to fail closed. If this overload drifts
        // back to Void, the assignment fails before stale Home can ship behind a string-only source audit.
        let operation: @MainActor (IntelligenceEngine) async -> Bool = { engine in
            await engine.analyzeRecent(
                maxDays: 21,
                startOffset: 0,
                refreshRepository: false)
        }
        _ = operation
    }

    func testDurableReceiptRunsInsidePublicationSensitiveAnalysisAPI() {
        // The verifier receives the exact result snapshot produced inside the admitted batch. Its Bool is part
        // of completion: false must remain retryable and must never be converted into a successful publication.
        let operation: @MainActor (IntelligenceEngine) async -> Bool = { engine in
            await engine.analyzeRecentForPublication(
                maxDays: 21,
                startOffset: 0,
                refreshRepository: false,
                verifyDurableRecovery: { results in
                    _ = results.map(\.day)
                    return true
                })
        }
        _ = operation
    }

    func testDurableReceiptSemanticDoesNotCoalesceWithBestEffortRequest() {
        let ordinary = IntelligenceAnalysisRequest(
            maxDays: 21,
            startOffset: 0,
            force: true,
            refreshRepository: false)
        let durable = IntelligenceAnalysisRequest(
            maxDays: 21,
            startOffset: 0,
            force: true,
            refreshRepository: false,
            requiresDurableRecoveryReceipt: true)

        XCTAssertFalse(ordinary.canCoalesce(with: durable))
        XCTAssertFalse(durable.canCoalesce(with: ordinary))
    }
}
