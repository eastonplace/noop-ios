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

    /// What the native root shows in every language: the section headers, the row titles, each search result's title and
    /// every part of its breadcrumb, the profile row and the search field's prompt.
    func testEverythingTheRootShowsIsTranslatedEverywhere() throws {
        let marker = "§missing§"
        var keys: Set<String> = ["Personal profile", "Search Settings", "Search Results", "Settings", "Age", "Max HR"]
        for section in SettingsRouteCatalog.rootSections {
            keys.insert(section.title)
            section.routes.forEach { keys.insert($0.title) }
        }
        for item in SettingsRouteCatalog.searchItems {
            keys.insert(item.title)
            item.breadcrumb.components(separatedBy: " › ").forEach { keys.insert($0) }
        }
        var untranslated: [String] = []
        for language in Self.shippedLanguages {
            let table = try table(for: language)
            for key in keys.sorted() where table.localizedString(forKey: key, value: marker, table: nil) == marker {
                untranslated.append("\(language): \(key)")
            }
        }
        XCTAssertEqual(untranslated, [], "root strings with no entry in a shipped language")
    }

    /// The search terms kept for the pages that were merged away are translated like every other keyword, so a query
    /// typed in the person's language finds the row too.
    func testTheSearchTermsKeptForMergedPagesAreTranslatedEverywhere() throws {
        let marker = "§missing§"
        let keys = [
            "Automations", "Automations & Shortcuts", "triggers", "baselines", "Scoring & baselines",
            "Data Sources & Storage", "Workout & feature preferences", "Features",
        ]
        var untranslated: [String] = []
        for language in Self.shippedLanguages {
            let table = try table(for: language)
            for key in keys where table.localizedString(forKey: key, value: marker, table: nil) == marker {
                untranslated.append("\(language): \(key)")
            }
        }
        XCTAssertEqual(untranslated, [], "search terms with no entry in a shipped language")
    }

    /// The breadcrumb under a search result keeps its separators and translates each part on its own.
    func testABreadcrumbIsTranslatedPartByPart() throws {
        let german = try table(for: "de")
        let shown = SettingsRootView.localizedBreadcrumb("Device & Sync › Sync & battery", in: german)
        XCTAssertEqual(shown.components(separatedBy: " › ").count, 2)
        XCTAssertNotEqual(shown, "Device & Sync › Sync & battery")
    }
}
