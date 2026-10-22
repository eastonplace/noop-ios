import XCTest
import StrandAnalytics
@testable import NOOP

final class TestReportDestinationTests: XCTestCase {
    func testReportOpensThisForkAndPreservesDiagnosticFields() throws {
        let url = try XCTUnwrap(TestReportLink.reportURL(
            profile: .battery, title: "connection & battery",
            version: "1.7.0", platform: "iOS", osVersion: "26.0",
            reportText: "redacted diagnostic", whatHappensSeed: "Battery drains"))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/eastonplace/noop-ios/issues/new")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let fields = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(fields["template"], "bug_report.yml")
        XCTAssertEqual(fields["title"], "[battery] connection & battery")
        XCTAssertEqual(fields["labels"], "bug,test:battery")
        XCTAssertEqual(fields["what_happens"], "Battery drains")
        XCTAssertTrue((fields["log"] ?? nil)?.contains("redacted diagnostic") == true)
    }
}
