import XCTest
@testable import NOOP

final class SettingsRouteCatalogTests: XCTestCase {
    func testRootHasOneStableOwnerPerRouteAndNoSupport() {
        let routes = SettingsRouteCatalog.rootSections.flatMap(\.routes).map(\.id)
        XCTAssertEqual(Set(routes).count, routes.count)
        XCTAssertFalse(routes.map(\.rawValue).contains(where: {
            $0.localizedCaseInsensitiveContains("support")
        }))
        XCTAssertEqual(SettingsRouteCatalog.rootSections.map(\.id), [
            .profile,
            .deviceSync,
            .healthData,
            .appPreferences,
            .automation,
            .advanced,
            .about,
        ])
    }

    func testSearchReturnsLeafSettingsWithBreadcrumbs() {
        XCTAssertEqual(SettingsRouteCatalog.search("battery").map(\.id), [
            "whoop",
            "continuous-hrv",
            "power-saving",
        ])
        XCTAssertEqual(SettingsRouteCatalog.search("baseline").map(\.id), [
            "recovery-baseline",
        ])
        XCTAssertEqual(SettingsRouteCatalog.search("healthkit").map(\.id), [
            "apple-health",
        ])
        XCTAssertEqual(SettingsRouteCatalog.search("test centre").map(\.route), [
            .testCentre,
        ])
    }

    func testSearchUsesAllTermsAndNormalizesPunctuation() {
        XCTAssertEqual(
            SettingsRouteCatalog.search("background history").map(\.id),
            ["background-sync"]
        )
        XCTAssertEqual(
            SettingsRouteCatalog.search("r-r capture").map(\.id),
            ["continuous-hrv"]
        )
    }

    func testTestCentreHasOneSemanticRoute() {
        let testItems = SettingsRouteCatalog.searchItems.filter { $0.route == .testCentre }
        XCTAssertEqual(testItems.count, 1)
        XCTAssertEqual(testItems.first?.breadcrumb, "Advanced › Diagnostics & Experimental")
    }

    func testEverySearchResultResolvesToKnownRoute() {
        let known = Set(SettingsRouteID.allCases)
        XCTAssertTrue(SettingsRouteCatalog.searchItems.allSatisfy {
            known.contains($0.route)
        })
    }
}
