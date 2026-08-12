import XCTest
@testable import NOOP

final class BackfillAnalysisSnapshotTests: XCTestCase {
    func testSameQuiescentGenerationIsStable() {
        let before = BackfillAnalysisSnapshot(dataAvailableAt: 100, backfilling: false)
        let after = BackfillAnalysisSnapshot(dataAvailableAt: 100, backfilling: false)

        XCTAssertTrue(after.isSettledAndUnchanged(since: before))
    }

    func testNewDurableDataRequiresAnotherAnalysisPass() {
        let before = BackfillAnalysisSnapshot(dataAvailableAt: 100, backfilling: false)
        let after = BackfillAnalysisSnapshot(dataAvailableAt: 101, backfilling: false)

        XCTAssertFalse(after.isSettledAndUnchanged(since: before))
    }

    func testActiveWriterCannotPublishEvenWhenGenerationMatches() {
        let before = BackfillAnalysisSnapshot(dataAvailableAt: 100, backfilling: false)
        let after = BackfillAnalysisSnapshot(dataAvailableAt: 100, backfilling: true)

        XCTAssertFalse(after.isSettledAndUnchanged(since: before))
    }

    func testAnalysisCannotStartFromAnAlreadyActiveWriterSnapshot() {
        let before = BackfillAnalysisSnapshot(dataAvailableAt: 100, backfilling: true)
        let after = BackfillAnalysisSnapshot(dataAvailableAt: 100, backfilling: false)

        XCTAssertFalse(after.isSettledAndUnchanged(since: before))
    }
}
