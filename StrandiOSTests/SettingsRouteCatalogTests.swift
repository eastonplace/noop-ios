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

    func testSearchIncludesCategoryAndBreadcrumbTerms() {
        XCTAssertEqual(
            SettingsRouteCatalog.search("advanced test").map(\.route),
            [.testCentre]
        )
        XCTAssertEqual(
            SettingsRouteCatalog.search("profile baseline").map(\.id),
            ["recovery-baseline"]
        )
        XCTAssertEqual(
            SettingsRouteCatalog.search("device sync battery").map(\.id),
            ["power-saving"]
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

    // MARK: Search in the person's language

    private func german() throws -> Bundle {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "de", ofType: "lproj"), "the app ships a German table")
        return try XCTUnwrap(Bundle(path: path))
    }

    /// The root shows translated titles, so a query typed from what is on screen has to find its row.
    func testAGermanQueryFindsTheRowsItNames() throws {
        let german = try german()
        XCTAssertEqual(SettingsRouteCatalog.search("Akku", in: german).map(\.id), [
            "whoop",
            "continuous-hrv",
            "power-saving",
        ])
        let titleShown = String(localized: "Appearance & units", bundle: german)
        XCTAssertNotEqual(titleShown, "Appearance & units", "the page title has a German entry")
        let found = SettingsRouteCatalog.search(titleShown, in: german).map(\.route)
        XCTAssertTrue(found.contains(.appearanceUnits), "searching for \(titleShown) finds Appearance & units")
    }

    func testEnglishStillWorksWhenTheAppIsInAnotherLanguage() throws {
        let german = try german()
        XCTAssertEqual(SettingsRouteCatalog.search("battery", in: german).map(\.id), [
            "whoop",
            "continuous-hrv",
            "power-saving",
        ])
        XCTAssertEqual(SettingsRouteCatalog.search("healthkit", in: german).map(\.id), ["apple-health"])
    }
}
