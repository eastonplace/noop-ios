import SwiftUI
import XCTest
@testable import StrandDesign

final class SettingsCatalogTests: XCTestCase {
    private func indexSections() -> [SettingsSectionModel] {
        [
            SettingsSectionModel(
                id: "browse",
                header: "Browse",
                rows: [
                    .navDetail(
                        id: "understand",
                        icon: "brain.head.profile",
                        tint: .purple,
                        title: "Understand your data",
                        subtitle: "Patterns, coaching, metric exploration, and comparisons"
                    ) { EmptyView() },
                    .navDetail(
                        id: "train-recover",
                        icon: "figure.run",
                        tint: .blue,
                        title: "Train & recover",
                        subtitle: "Workouts, health, stress, and timing"
                    ) { EmptyView() },
                    .navDetail(
                        id: "data-devices",
                        icon: "externaldrive",
                        tint: .cyan,
                        title: "Data & devices",
                        subtitle: "Sources, backups, and exports"
                    ) { EmptyView() },
                    .navDetail(
                        id: "plan-automate",
                        icon: "wand.and.stars",
                        tint: .orange,
                        title: "Plan & automate",
                        subtitle: "Alarms, automations, diagnostics, and shortcuts"
                    ) { EmptyView() }
                ]
            ),
            SettingsSectionModel(
                id: "account-help",
                header: "Account & Help",
                rows: [
                    .navDetail(
                        id: "settings",
                        icon: "gearshape",
                        tint: .gray,
                        title: "Settings",
                        subtitle: "Profile and app preferences"
                    ) { EmptyView() }
                ]
            )
        ]
    }

    private func resultSections() -> [SettingsSectionModel] {
        [
            SettingsSectionModel(
                id: "train-results",
                header: "Train & recover",
                rows: [
                    .navDetail(
                        id: "intervals",
                        icon: "timer",
                        tint: .orange,
                        title: "Intervals",
                        subtitle: "Simple interval timing"
                    ) { EmptyView() },
                    .navDetail(
                        id: "lab-book",
                        icon: "books.vertical",
                        tint: .purple,
                        title: "Lab Book",
                        subtitle: "Experiments and observations"
                    ) { EmptyView() }
                ]
            ),
            SettingsSectionModel(
                id: "data-results",
                header: "Data & devices",
                rows: [
                    .navDetail(
                        id: "backup-sync",
                        icon: "externaldrive",
                        tint: .cyan,
                        title: "Backup & Sync",
                        subtitle: "Create and restore portable backups"
                    ) { EmptyView() },
                    .navDetail(
                        id: "data-sources",
                        icon: "externaldrive.fill",
                        tint: .cyan,
                        title: "Data Sources",
                        subtitle: "Imports, source priority, storage, and cleanup"
                    ) { EmptyView() }
                ]
            ),
            SettingsSectionModel(
                id: "plan-results",
                header: "Plan & automate",
                rows: [
                    .navDetail(
                        id: "test-centre",
                        icon: "stethoscope",
                        tint: .cyan,
                        title: "Test Centre",
                        subtitle: "Connection, sensor, scoring, and notification checks"
                    ) { EmptyView() }
                ]
            )
        ]
    }

    func testSearchMatchesSectionBreadcrumbAndKeywords() {
        let results = SettingsCatalog.filteredSections(resultSections(), query: "data backup")
        XCTAssertEqual(results.flatMap(\.rows).map(\.id), ["backup-sync"])
    }

    func testEmptySearchPreservesIndexInsteadOfFlatteningResults() {
        let results = SettingsCatalog.searchSections(
            indexSections: indexSections(),
            resultSections: resultSections(),
            query: "   "
        )
        XCTAssertEqual(results.map(\.id), ["browse", "account-help"])
        XCTAssertEqual(results.flatMap(\.rows).map(\.id), [
            "understand",
            "train-recover",
            "data-devices",
            "plan-automate",
            "settings"
        ])
    }

    func testNonemptySearchReturnsDirectLeafRoutes() {
        XCTAssertEqual(
            SettingsCatalog.searchSections(
                indexSections: indexSections(),
                resultSections: resultSections(),
                query: "interval"
            ).flatMap(\.rows).map(\.id),
            ["intervals"]
        )
        XCTAssertEqual(
            SettingsCatalog.searchSections(
                indexSections: indexSections(),
                resultSections: resultSections(),
                query: "lab"
            ).flatMap(\.rows).map(\.id),
            ["lab-book"]
        )
        XCTAssertEqual(
            SettingsCatalog.searchSections(
                indexSections: indexSections(),
                resultSections: resultSections(),
                query: "backup"
            ).flatMap(\.rows).map(\.id),
            ["backup-sync"]
        )
        XCTAssertEqual(
            SettingsCatalog.searchSections(
                indexSections: indexSections(),
                resultSections: resultSections(),
                query: "data sources"
            ).flatMap(\.rows).map(\.id),
            ["data-sources"]
        )
        XCTAssertEqual(
            SettingsCatalog.searchSections(
                indexSections: indexSections(),
                resultSections: resultSections(),
                query: "test centre"
            ).flatMap(\.rows).map(\.id),
            ["test-centre"]
        )
    }

    func testItemsPreserveStableRouteIDsAndInput() {
        let original = resultSections()
        let items = SettingsCatalog.items(from: original)

        XCTAssertEqual(items.map(\.id), [
            "train-results/intervals",
            "train-results/lab-book",
            "data-results/backup-sync",
            "data-results/data-sources",
            "plan-results/test-centre"
        ])
        XCTAssertEqual(original.flatMap(\.rows).count, 5)
    }
}
