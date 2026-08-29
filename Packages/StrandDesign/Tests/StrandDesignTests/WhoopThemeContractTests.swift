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

    func testCommandSurfaceStaysDarkAndReadableUnderFixedTheme() {
        assertColor(StrandPalette.commandSurface, equalsHex: "#07120E")
        XCTAssertGreaterThanOrEqual(
            contrastRatio(StrandPalette.textPrimary, StrandPalette.commandSurface),
            7.0,
            "Operational cards must keep high-contrast white copy on a dark command surface."
        )
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

    private func contrastRatio(_ foreground: Color, _ background: Color) -> Double {
        let foregroundLuminance = relativeLuminance(foreground.rgbaComponents)
        let backgroundLuminance = relativeLuminance(background.rgbaComponents)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ components: (r: Double, g: Double, b: Double, a: Double)) -> Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(components.r)
            + 0.7152 * linear(components.g)
            + 0.0722 * linear(components.b)
    }
}
