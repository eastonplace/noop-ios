import SwiftUI
import XCTest
@testable import NOOP

/// Today pushes the Your Cards catalog with `navigationDestination(isPresented:)`, whose content closure runs on every
/// pass of Today's body. The destination takes its items as a closure and resolves them in its own body, so an
/// unopened catalog costs Today nothing, and an open one is built from the figures current at that moment.
@MainActor
final class DashboardCatalogDestinationTests: XCTestCase {
    private func item(_ card: DashboardCard, value: String) -> DashboardCatalogItem {
        DashboardCatalogItem(card: card, value: value, spark: [1, 2, 3], tint: .blue)
    }

    func testBuildingTheDestinationResolvesNoItemsUntilItsBodyRuns() {
        var resolved = 0
        // What Today's body does on every pass while the catalog is closed.
        for _ in 0..<25 {
            _ = DashboardCatalogDestination(
                items: { resolved += 1; return [] }, selectionRaw: .constant(""), hydrationEnabled: false)
        }
        XCTAssertEqual(resolved, 0, "a closed catalog resolves nothing")
    }

    func testItsBodyResolvesTheItemsOnceAndHandsThemToTheCatalog() {
        var resolved = 0
        let items = [item(.steps, value: "8,123"), item(.calories, value: "2,410 kcal")]
        let destination = DashboardCatalogDestination(
            items: { resolved += 1; return items }, selectionRaw: .constant(""), hydrationEnabled: true)
        let catalog = destination.body
        XCTAssertEqual(resolved, 1)
        XCTAssertEqual(catalog.items.map(\.value), ["8,123", "2,410 kcal"], "the figures are the closure's, unchanged")
        XCTAssertEqual(catalog.items.map(\.card), [.steps, .calories])
        XCTAssertTrue(catalog.hydrationEnabled)
    }

    func testEachOpenResolvesTheFiguresCurrentAtThatMoment() {
        var value = "2,000 kcal"
        let destination = DashboardCatalogDestination(
            items: { [DashboardCatalogItem(card: .calories, value: value, spark: [], tint: .blue)] },
            selectionRaw: .constant(""), hydrationEnabled: false)
        XCTAssertEqual(destination.body.items.first?.value, "2,000 kcal")
        value = "2,350 kcal"
        XCTAssertEqual(destination.body.items.first?.value, "2,350 kcal")
    }
}
