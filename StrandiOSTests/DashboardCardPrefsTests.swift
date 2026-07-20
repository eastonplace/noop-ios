import XCTest
@testable import NOOP

final class DashboardCardPrefsTests: XCTestCase {
    func testFreshDefaultIsNineCardsWithoutHydration() {
        XCTAssertEqual(DashboardCardPrefs.decodeEnabled(""), [
            .hrv, .restingHr, .respiratory, .bloodOxygen, .skinTemp,
            .sleep, .stress, .steps, .calories,
        ])
    }

    func testFreshHydrationDefaultReplacesCalories() {
        let cards = DashboardCardPrefs.decodeEnabled("", hydrationEnabled: true)
        XCTAssertEqual(cards.count, 9)
        XCTAssertEqual(cards.last, .hydration)
        XCTAssertFalse(cards.contains(.calories))
    }

    func testMigrationPreservesOrderDeduplicatesAndCapsAtNine() {
        let raw = #"["steps","hrv","steps","bogus","stress","sleep","restingHr","respiratory","bloodOxygen","skinTemp","fitnessAge","vitality"]"#
        XCTAssertEqual(DashboardCardPrefs.migratedSelection(raw, hydrationEnabled: false), [
            .steps, .hrv, .stress, .sleep, .restingHr, .respiratory,
            .bloodOxygen, .skinTemp, .fitnessAge,
        ])
    }

    func testMigrationFillsOldShortLayoutFromDefaults() {
        let cards = DashboardCardPrefs.migratedSelection(#"["stress","hrv"]"#, hydrationEnabled: false)
        XCTAssertEqual(Array(cards.prefix(2)), [.stress, .hrv])
        XCTAssertEqual(cards.count, 9)
        XCTAssertEqual(Set(cards).count, cards.count)
    }

    func testSavedOneTileLayoutRemainsOneAfterNormalization() {
        XCTAssertEqual(DashboardCardPrefs.decodeEnabled(#"["sleep"]"#), [.sleep])
    }

    func testHydrationIsGatedWithoutRewritingSavedLayout() {
        let raw = #"["hydration","hrv"]"#
        XCTAssertEqual(DashboardCardPrefs.decodeEnabled(raw, hydrationEnabled: false), [.hrv])
        XCTAssertEqual(DashboardCardPrefs.decodeEnabled(raw, hydrationEnabled: true), [.hydration, .hrv])
        XCTAssertFalse(DashboardCardPrefs.eligibleCards(hydrationEnabled: false).contains(.hydration))
    }

    func testEncodePreservesOrderAndCapsAtNine() {
        let cards: [DashboardCard] = [
            .vitality, .fitnessAge, .stress, .steps, .hrv, .sleep,
            .restingHr, .respiratory, .bloodOxygen, .skinTemp,
        ]
        XCTAssertEqual(DashboardCardPrefs.decodeEnabled(DashboardCardPrefs.encode(cards)), Array(cards.prefix(9)))
    }
}
