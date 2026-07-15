import XCTest
@testable import StrandDesign

final class PaperSearchFieldTests: XCTestCase {
    func testPlatformDefaultPreservesExistingInputBehavior() {
        XCTAssertEqual(
            PaperSearchInputConfiguration.platformDefault,
            PaperSearchInputConfiguration()
        )
        XCTAssertEqual(
            PaperSearchInputConfiguration.platformDefault.capitalization,
            .platformDefault
        )
        XCTAssertEqual(
            PaperSearchInputConfiguration.platformDefault.autocorrection,
            .platformDefault
        )
    }

    func testSearchQueryUsesLiteralFilterInputBehavior() {
        XCTAssertEqual(PaperSearchInputConfiguration.searchQuery.capitalization, .never)
        XCTAssertEqual(PaperSearchInputConfiguration.searchQuery.autocorrection, .disabled)
    }
}
