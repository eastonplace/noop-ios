import XCTest
import StrandDesign
@testable import NOOP

final class PaperIntegrationContractTests: XCTestCase {
    func testWidgetPublicationUsesCanonicalThreeScoreScales() {
        let snapshot = WidgetSnapshot.publishing(
            recovery: 49.6,
            storedStrain: 67,
            sleepScore: 85.6,
            bpm: 58,
            batteryPct: 83.6,
            bonded: true,
            hrv: 63.7,
            restingHr: 52,
            updated: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(snapshot.recovery, 50)
        XCTAssertEqual(snapshot.effort ?? -1, 14.07, accuracy: 0.0001)
        XCTAssertEqual(snapshot.rest, 86)
        XCTAssertEqual(snapshot.bpm, 58)
        XCTAssertEqual(snapshot.batteryPct, 84)
        XCTAssertEqual(snapshot.hrv, 64)
        XCTAssertEqual(snapshot.restingHr, 52)
    }

    @MainActor
    func testEveryDemoRouteResolvesToAView() {
        XCTAssertFalse(DemoScreens.routeNames.isEmpty)
        XCTAssertEqual(Set(DemoScreens.routeNames).count, DemoScreens.routeNames.count)
        for route in DemoScreens.routeNames {
            XCTAssertNotNil(DemoScreens.view(named: route), "Unresolved demo route: \(route)")
        }
        XCTAssertNil(DemoScreens.view(named: "definitely-not-a-route"))
    }

    func testPaperLocalizationCatalogsContainNoLegacyPillarKeys() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogs = [
            "Strand/Resources/Localizable.xcstrings",
            "NOOPWatch/Localizable.xcstrings",
            "NOOPWatchComplications/Localizable.xcstrings",
            "Packages/StrandDesign/Sources/StrandDesign/Resources/Localizable.xcstrings",
        ]
        let legacyPillar = try NSRegularExpression(
            pattern: #"(^|[^A-Za-z])(Charge|Effort|EFFORT)([^A-Za-z]|$)"#
        )

        for relativePath in catalogs {
            let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(relativePath))
            let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
            XCTAssertFalse(strings.isEmpty, "Empty localization catalog: \(relativePath)")
            for key in strings.keys {
                let range = NSRange(key.startIndex..., in: key)
                XCTAssertNil(
                    legacyPillar.firstMatch(in: key, range: range),
                    "Legacy Paper pillar key in \(relativePath): \(key)"
                )
            }
        }
    }
}
