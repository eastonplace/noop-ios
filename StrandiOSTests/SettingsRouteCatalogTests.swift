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

    /// The Apple-ID-style profile row opens Personal profile, so it is not also a row under a section of its own.
    func testTheProfileRowIsNotAlsoAListRow() {
        let rowRoutes = SettingsRouteCatalog.rootSections.flatMap(\.routes).map(\.id)
        XCTAssertFalse(rowRoutes.contains(.personalProfile))
        XCTAssertFalse(SettingsRouteCatalog.rootSections.map(\.title).contains("Profile"))
        XCTAssertEqual(SettingsRouteCatalog.search("personal profile").first?.route, .personalProfile)
    }

    /// Every page is reachable from the profile row, a root row or a search result, and no row is listed twice.
    func testEveryRouteIsReachableAndNothingIsListedTwice() {
        let rows = SettingsRouteCatalog.rootSections.flatMap(\.routes).map(\.id)
        let reachable = Set(rows).union(SettingsRouteCatalog.searchItems.map(\.route)).union([.personalProfile])
        XCTAssertEqual(reachable, Set(SettingsRouteID.allCases))
        XCTAssertEqual(Set(rows).count, rows.count)
    }

    /// The consolidation: Scoring & baselines is a section of Personal profile, Storage belongs to Advanced, the
    /// Live Activity toggle to Workouts, and the duplicate Automations page is gone (Siri & Shortcuts keeps its row).
    func testTheMergedPagesAreFoundWhereTheyMoved() {
        XCTAssertEqual(SettingsRouteCatalog.search("recovery baseline").map(\.route), [.personalProfile])
        XCTAssertEqual(SettingsRouteCatalog.search("step calibration").map(\.route), [.personalProfile])
        // "Storage" is also half of the old Data Sources & Storage page, so Data Sources answers it too.
        XCTAssertEqual(SettingsRouteCatalog.search("storage").map(\.route), [.dataSources, .diagnosticsExperimental])
        XCTAssertEqual(SettingsRouteCatalog.search("dynamic island").map(\.route), [.workouts])
        XCTAssertEqual(SettingsRouteCatalog.search("siri").map(\.route), [.siriShortcuts])
        XCTAssertEqual(SettingsRouteCatalog.search("hydration").map(\.route), [.workouts])
        let titles = SettingsRouteCatalog.rootSections.flatMap(\.routes).map(\.title)
        XCTAssertFalse(titles.contains("Scoring & baselines"))
        XCTAssertFalse(titles.contains("Automations & Shortcuts"))
        XCTAssertFalse(titles.contains("Data Sources & Storage"))
    }

    /// The names of the pages that were merged away (and quoted by older What's New entries) still find where their
    /// content lives now. Matching is by substring, so a singular keyword never found the plural name.
    func testEveryOldPageNameStillFindsItsNewHome() {
        let oldNames: [(name: String, home: Set<SettingsRouteID>)] = [
            ("Automations", [.notificationsAlerts]),
            ("Automations & Shortcuts", [.notificationsAlerts]),
            ("automations shortcuts", [.notificationsAlerts]),
            ("triggers", [.notificationsAlerts]),
            ("baselines", [.personalProfile]),
            ("Scoring & baselines", [.personalProfile]),
            ("scoring baselines", [.personalProfile]),
            ("Data Sources & Storage", [.dataSources]),
            ("data sources storage", [.dataSources]),
            ("storage", [.diagnosticsExperimental]),
            ("Workout & feature preferences", [.workouts]),
            ("workout feature preferences", [.workouts]),
            ("features", [.workouts]),
        ]
        for (name, home) in oldNames {
            let found = Set(SettingsRouteCatalog.search(name).map(\.route))
            XCTAssertTrue(home.isSubset(of: found), "\(name) should find \(home), found \(found)")
        }
    }

    /// Every row the root shows has a tile symbol and colour, so no row falls back to a bare label.
    func testEveryRouteHasATileSymbol() {
        for route in SettingsRouteID.allCases {
            XCTAssertFalse(route.tileSymbol.isEmpty, "\(route) has a symbol")
        }
        let symbols = SettingsRouteID.allCases.map(\.tileSymbol)
        XCTAssertEqual(Set(symbols).count, symbols.count, "each tile shows its own symbol")
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
