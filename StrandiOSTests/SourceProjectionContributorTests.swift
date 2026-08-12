import XCTest
import NoopPhase34Core
@testable import NOOP

#if os(iOS)
@MainActor
final class SourceProjectionContributorTests: XCTestCase {
    func testActiveSourceAndCanonicalHistoryShareOneProjectionSet() throws {
        let repository = Repository(deviceId: Repository.whoopSource)
        let sourceB = try RepositoryLiveSourceDescriptor(
            id: "source-B",
            historyLineage: "lineage-B",
            cursorEpoch: 2
        )
        XCTAssertTrue(repository.adoptActiveSource(sourceB))

        let contributors = repository.activeProjectionContributorIds
        XCTAssertTrue(contributors.contains("source-B"))
        XCTAssertTrue(contributors.contains("source-B-noop"))
        XCTAssertTrue(contributors.contains(Repository.whoopSource))
        XCTAssertTrue(contributors.contains(Repository.whoopSource + "-noop"))
        XCTAssertTrue(contributors.contains(Repository.appleHealthSource))
        XCTAssertFalse(contributors.contains("unrelated-C"))
    }
}
#endif
