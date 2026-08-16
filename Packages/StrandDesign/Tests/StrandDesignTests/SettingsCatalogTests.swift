import SwiftUI
import XCTest
@testable import StrandDesign

final class SettingsCatalogTests: XCTestCase {
    private func sections() -> [SettingsSectionModel] {
        [
            SettingsSectionModel(
                id: "health",
                header: "Health & Scoring",
                rows: [
                    .navDetail(
                        id: "recovery-and-scoring",
                        icon: "waveform.path.ecg",
                        tint: .blue,
                        title: "Recovery & scoring",
                        subtitle: "Baseline calibration and score controls"
                    ) { EmptyView() },
                    .navDetail(
                        id: "skin-temperature",
                        icon: "thermometer.medium",
                        tint: .orange,
                        title: "Skin temperature",
                        subtitle: "Overnight temperature and illness context"
                    ) { EmptyView() }
                ]
            ),
            SettingsSectionModel(
                id: "advanced",
                header: "Advanced",
                rows: [
                    .navDetail(
                        id: "test-centre",
                        icon: "stethoscope",
                        tint: .cyan,
                        title: "Test Centre",
                        subtitle: "Diagnostics and sensor evidence"
                    ) { EmptyView() }
                ]
            )
        ]
    }

    func testSearchMatchesSectionBreadcrumbAndKeywords() {
        let results = SettingsCatalog.filteredSections(sections(), query: "baseline")
        XCTAssertEqual(results.flatMap(\.rows).map(\.id), ["recovery-and-scoring"])
    }

    func testSearchPreservesStableRouteIDsAndDoesNotMutateInput() {
        let original = sections()
        let items = SettingsCatalog.items(from: original)
        let filtered = SettingsCatalog.filteredSections(original, query: "advanced")

        XCTAssertEqual(items.map(\.id), [
            "health/recovery-and-scoring",
            "health/skin-temperature",
            "advanced/test-centre"
        ])
        XCTAssertEqual(filtered.flatMap(\.rows).map(\.id), ["test-centre"])
        XCTAssertEqual(original.flatMap(\.rows).count, 3)
    }

    func testEmptySearchReturnsAllSections() {
        XCTAssertEqual(
            SettingsCatalog.filteredSections(sections(), query: "").flatMap(\.rows).map(\.id),
            ["recovery-and-scoring", "skin-temperature", "test-centre"]
        )
    }
}
