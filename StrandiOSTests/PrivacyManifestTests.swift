import XCTest
@testable import NOOP

#if os(iOS)
final class PrivacyManifestTests: XCTestCase {
    func testAppBundleDeclaresItsRequiredReasonAPIs() throws {
        let reasons = try apiReasons(in: Bundle.main)
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryUserDefaults"], ["CA92.1", "1C8F.1"])
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryFileTimestamp"], ["C617.1", "3B52.1"])
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategorySystemBootTime"], ["35F9.1"])
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryDiskSpace"], ["E174.1"])
    }

    func testEmbeddedWidgetBundleDeclaresSharedPreferences() throws {
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let widget = try XCTUnwrap(Bundle(url: plugins.appendingPathComponent("NOOPWidgets.appex")))
        XCTAssertEqual(try apiReasons(in: widget)["NSPrivacyAccessedAPICategoryUserDefaults"], ["1C8F.1"])
    }

    private func apiReasons(in bundle: Bundle) throws -> [String: Set<String>] {
        // Inspect compiled bundles, so a source file omitted from Copy Bundle Resources also fails.
        let url = try XCTUnwrap(bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let manifest = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), format: nil) as? [String: Any])
        let declarations = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var result: [String: Set<String>] = [:]
        for declaration in declarations {
            let category = try XCTUnwrap(declaration["NSPrivacyAccessedAPIType"] as? String)
            XCTAssertNil(result[category], "Each API category has one reason list")
            result[category] = Set(try XCTUnwrap(declaration["NSPrivacyAccessedAPITypeReasons"] as? [String]))
        }
        return result
    }
}
#endif
