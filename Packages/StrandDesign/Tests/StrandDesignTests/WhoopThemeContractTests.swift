import XCTest
import SwiftUI
@testable import StrandDesign

final class WhoopThemeContractTests: XCTestCase {
    func testEveryStoredAppearanceValueResolvesToDark() {
        for raw in ["system", "light", "dark", "unknown"] {
            XCTAssertEqual(
                AppearanceMode.resolve(raw).colorScheme,
                .dark,
                "Stored appearance value \(raw) must resolve to the single dark theme."
            )
        }
        XCTAssertEqual(AppearanceMode.allCases.count, 1)
    }

    func testEveryStoredChartStyleResolvesToWhoopStyle() {
        for raw in ["titanium", "classic", "unknown"] {
            XCTAssertEqual(ChartStyle.resolve(raw), .titanium)
        }
        XCTAssertEqual(ChartStyle.allCases, [.titanium])
    }

    func testCompatibilityColorsAlwaysResolveDarkValue() {
        assertColor(
            Color(light: "#FFFFFF", dark: "#101518"),
            equalsHex: "#101518"
        )
    }

    func testWhoopRecoveryBandsUseExactInclusiveRanges() {
        for score in [0.0, 1.0, 33.0] {
            assertColor(StrandPalette.recoveryColor(score), equalsHex: "#FF0026")
        }
        for score in [34.0, 50.0, 66.0] {
            assertColor(StrandPalette.recoveryColor(score), equalsHex: "#FFDE00")
        }
        for score in [67.0, 90.0, 100.0] {
            assertColor(StrandPalette.recoveryColor(score), equalsHex: "#16EC06")
        }
    }

    func testWhoopMetricColorsStayDistinct() {
        assertColor(StrandPalette.strainAccent, equalsHex: "#0093E7")
        assertColor(StrandPalette.sleepAccent, equalsHex: "#7BA1BB")
        assertColor(StrandPalette.sleepNeedTeal, equalsHex: "#00F19F")
        assertColor(StrandPalette.recoveryData, equalsHex: "#67AEE6")
    }

    private func assertColor(
        _ actual: Color,
        equalsHex expectedHex: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actualComponents = actual.rgbaComponents
        let expected = Color.sRGBComponents(hex: expectedHex)
        XCTAssertEqual(actualComponents.r, expected.r, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualComponents.g, expected.g, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualComponents.b, expected.b, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualComponents.a, expected.a, accuracy: 0.001, file: file, line: line)
    }
}
