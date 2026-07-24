import SwiftUI
import XCTest
@testable import StrandDesign

@MainActor
final class SettingsKitComponentsTests: XCTestCase {
    func testNavigationDestinationIsBuiltLazily() {
        var buildCount = 0
        let buildDestination: () -> Text = {
            buildCount += 1
            return Text("Destination")
        }
        let row = SettingsRowModel.nav(
            id: "lazy",
            icon: "gear",
            tint: .blue,
            title: "Lazy"
        ) {
            buildDestination()
        }

        XCTAssertEqual(buildCount, 0)
        guard case .nav(_, _, _, _, _, let makeDestination) = row else {
            return XCTFail("Expected navigation row")
        }
        _ = makeDestination()
        XCTAssertEqual(buildCount, 1)
    }

    func testDetailedNavigationDestinationIsBuiltLazily() {
        var buildCount = 0
        let buildDestination: () -> Text = {
            buildCount += 1
            return Text("Destination")
        }
        let row = SettingsRowModel.navDetail(
            id: "lazy-detail",
            icon: "gear",
            tint: .blue,
            title: "Lazy",
            subtitle: "Detail"
        ) {
            buildDestination()
        }

        XCTAssertEqual(buildCount, 0)
        guard case .navDetail(_, _, _, _, _, _, let makeDestination) = row else {
            return XCTFail("Expected detailed navigation row")
        }
        _ = makeDestination()
        XCTAssertEqual(buildCount, 1)
    }
}
