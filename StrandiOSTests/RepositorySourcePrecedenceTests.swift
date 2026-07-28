import XCTest
@testable import NOOP

@MainActor
final class RepositorySourcePrecedenceTests: XCTestCase {
    func testCanonicalComputedRecoveryPrecedesLegacyActiveSiblingAfterRepair() {
        let candidates = Repository.sourceCandidates(
            forKey: "recovery",
            preferredSource: Repository.whoopSource,
            actualWhoopSource: "whoop-repaired")
        let sources = candidates.map(\.source)

        let canonicalIndex = try? XCTUnwrap(
            sources.firstIndex(of: Repository.whoopSource + "-noop"))
        let repairedIndex = try? XCTUnwrap(
            sources.firstIndex(of: "whoop-repaired-noop"))

        XCTAssertNotNil(canonicalIndex)
        XCTAssertNotNil(repairedIndex)
        if let canonicalIndex, let repairedIndex {
            XCTAssertLessThan(canonicalIndex, repairedIndex)
        }
    }
}
