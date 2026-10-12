import XCTest
@testable import NOOP

/// The translations of what the Settings sheet puts on screen: the profile button that opens it, the titles of the
/// root and its search results, and European Portuguese, which is not Spanish.
@MainActor
final class SettingsLocalizationTests: XCTestCase {
    private static let shippedLanguages = ["de", "es", "fr", "it", "pt-PT", "ru", "zh-Hans", "zh-Hant"]

    private func table(for language: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"), "the app ships \(language)")
        return try XCTUnwrap(Bundle(path: path))
    }

    /// The top bar's profile button is the only way into Settings, so its VoiceOver label is in every language.
    func testTheProfileButtonsAccessibilityLabelIsTranslatedEverywhere() throws {
        let marker = "§missing§"
        for language in Self.shippedLanguages {
            let table = try table(for: language)
            XCTAssertNotEqual(table.localizedString(forKey: "Profile and settings", value: marker, table: nil), marker,
                              "no \(language) label for the profile button")
        }
    }

    /// European Portuguese is not Spanish: the titles it shows are its own words.
    func testPortugueseSettingsTitlesAreNotTheSpanishOnes() throws {
        let portuguese = try table(for: "pt-PT")
        let spanish = try table(for: "es")
        for key in ["Advanced", "Automation", "Age", "Appearance", "Step calibration", "Test Centre", "Storage"] {
            XCTAssertNotEqual(portuguese.localizedString(forKey: key, value: nil, table: nil),
                              spanish.localizedString(forKey: key, value: nil, table: nil), key)
        }
    }
}
