import XCTest
import StrandDesign
@testable import NOOP

final class TodaySummaryPreferencesTests: XCTestCase {
    func testFreshSelectionKeepsAllExistingPillarsInOrder() {
        XCTAssertEqual(TodaySummaryPreferences.decodeEnabled(""), [.recovery, .strain, .sleep])
    }

    func testInvalidIDsAndDuplicatesAreRemovedWithoutChangingSavedOrder() {
        XCTAssertEqual(TodaySummaryPreferences.decodeEnabled(#"["sleep","unknown","strain","sleep"]"#),
                       [.sleep, .strain])
        XCTAssertEqual(TodaySummaryPreferences.decodeEnabled(" strain, sleep, strain, unknown "), [.strain, .sleep])
    }

    func testEmptyOrCorruptSavedSelectionsCannotHideEveryScore() {
        for raw in ["[]", "[null]", "[", #"["unknown"]"#] {
            XCTAssertEqual(TodaySummaryPreferences.decodeEnabled(raw), [.recovery], raw)
        }
        XCTAssertEqual(TodaySummaryPreferences.decodeEnabled(TodaySummaryPreferences.encode([])), [.recovery])
    }

    func testEncodingPreservesSelectionOrderAndDeduplicates() {
        let raw = TodaySummaryPreferences.encode([.sleep, .recovery, .sleep])
        XCTAssertEqual(TodaySummaryPreferences.decodeEnabled(raw), [.sleep, .recovery])
    }

    func testSummaryPersistenceDoesNotUseLegacyOrHealthKeys() {
        XCTAssertEqual(TodaySummaryPreferences.selectionKey, "today.summaryMetrics")
        XCTAssertNotEqual(TodaySummaryPreferences.selectionKey, KeyMetricPrefs.layoutKey)
        XCTAssertNotEqual(TodaySummaryPreferences.selectionKey, DashboardCardPrefs.selectionKey)
        XCTAssertEqual(DashboardCardPrefs.selectionKey, "today.dashboardCards")
        XCTAssertEqual(DashboardCardPrefs.normalizedV2Key, "today.dashboardCards.v2Normalized")
    }

    func testPersistedSummaryIsIndependentFromExistingHealthSelection() throws {
        let suite = "TodaySummaryPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let health = #"["steps","hrv"]"#
        defaults.set(health, forKey: DashboardCardPrefs.selectionKey)
        defaults.set(TodaySummaryPreferences.encode([.strain]), forKey: TodaySummaryPreferences.selectionKey)
        XCTAssertEqual(TodaySummaryPreferences.decodeEnabled(defaults.string(forKey: TodaySummaryPreferences.selectionKey) ?? ""), [.strain])
        XCTAssertEqual(defaults.string(forKey: DashboardCardPrefs.selectionKey), health)
    }

    func testSelectedPillarsRetainValuesMissingStatesAndProvenanceInSelectedOrder() {
        let pillars = [
            TodayPillarModel(id: "recovery", label: "Recovery", value: 71, maximum: 100,
                             valueText: "71", state: "Ready", detail: "Yesterday", accent: .green),
            TodayPillarModel(id: "strain", label: "Strain", value: 9.8, maximum: 21,
                             valueText: "9.8", state: "Moderate", accent: .orange),
            TodayPillarModel(id: "sleep", label: "Sleep", value: nil, maximum: 100,
                             valueText: "—", state: "No reading", detail: "Waiting for sleep", accent: .blue),
        ]
        let selected = TodaySummaryPreferences.orderedValues(pillars, raw: #"["sleep","recovery"]"#, id: \.id)
        XCTAssertEqual(selected, [pillars[2], pillars[0]])
        XCTAssertNil(selected[0].value)
        XCTAssertEqual(selected[0].valueText, "—")
        XCTAssertEqual(selected[0].detail, "Waiting for sleep")
        XCTAssertEqual(selected[1].value, 71)
        XCTAssertEqual(selected[1].detail, "Yesterday")
    }
}
