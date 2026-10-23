import XCTest
import WhoopStore
@testable import NOOP

/// The edits on the Edit questions screen and a question's page: rename, group, answer type, on / off and delete.
/// Each runs against a throwaway catalog, never the app's saved one.
@MainActor
final class JournalQuestionSettingsTests: XCTestCase {
    private let alcohol = "Did you drink any alcohol?"
    private let magnesium = "Did you take magnesium?"

    private func makeCatalog() throws -> JournalCatalogStore {
        let name = "JournalQuestionSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return JournalCatalogStore(defaults: defaults)
    }

    private func membership(_ canonical: String, active: Bool = true) -> CoachingBehaviorMembership {
        CoachingBehaviorMembership(setId: "daily-fundamentals", canonicalQuestion: canonical,
                                   coachingGroup: CoachingCheckInGroup.fuel.rawValue, sortIndex: 3,
                                   isActive: active, isQuickAdd: true)
    }

    private func item(_ canonical: String, in catalog: JournalCatalogStore) throws -> JournalCatalogItem {
        try XCTUnwrap(catalog.resolvedItems(imported: [], includeHidden: true)
            .first { JournalCatalogStore.norm($0.canonical) == JournalCatalogStore.norm(canonical) })
    }

    // MARK: Rename

    func testRenameChangesTheNameButNeverTheStoredKey() throws {
        let catalog = try makeCatalog()
        catalog.addCustom("Did you nap?")
        catalog.rename("Did you nap?", to: "Nap")
        catalog.rename(alcohol, to: "Drinks")

        let nap = try item("Did you nap?", in: catalog)
        XCTAssertEqual(nap.canonical, "Did you nap?")
        XCTAssertEqual(coachingShortDisplayName(for: nap), "Nap")
        let drinks = try item(alcohol, in: catalog)
        XCTAssertEqual(drinks.canonical, alcohol, "history is keyed on the original question")
        XCTAssertEqual(coachingShortDisplayName(for: drinks), "Drinks")
        XCTAssertEqual(catalog.resolvedItems(imported: [], includeHidden: true).filter { $0.canonical == alcohol }.count, 1)
    }

    func testBlankNameGoesBackToTheOriginalWording() throws {
        let catalog = try makeCatalog()
        catalog.rename(alcohol, to: "Drinks")
        catalog.rename(alcohol, to: "   ")
        XCTAssertEqual(coachingShortDisplayName(for: try item(alcohol, in: catalog)), "Alcohol")
        XCTAssertEqual(try item(alcohol, in: catalog).canonical, alcohol)
    }

    // MARK: Group

    func testRegroupingMovesTheQuestionAndKeepsItsKey() throws {
        let catalog = try makeCatalog()
        XCTAssertEqual(coachingPresentationGroup(for: try item(alcohol, in: catalog)), .fuel)
        catalog.setGroup(alcohol, to: .supplements)
        let moved = try item(alcohol, in: catalog)
        XCTAssertEqual(moved.canonical, alcohol)
        XCTAssertEqual(moved.group, .supplements)
        XCTAssertEqual(coachingPresentationGroup(for: moved), .supplements)
    }

    func testPickingAGroupShowsTheQuestionUnderItInTheListAndOnTheTiles() throws {
        let catalog = try makeCatalog()
        for target in CoachingCheckInGroup.allCases {
            JournalQuestionEditing.setGroup(target, for: alcohol, in: catalog)
            let all = catalog.resolvedItems(imported: [], includeHidden: true)

            // The Edit questions list.
            let listed = JournalQuestionEditing.grouped(all)
            let home = listed.first { $0.items.contains { $0.canonical == alcohol } }
            XCTAssertEqual(home?.group, target, "the list should show Alcohol under \(target.rawValue)")

            // The Journal's tiles come in the list's order, so Alcohol sits inside that group's run of tiles.
            let tiles = JournalQuickLogTile.tiles(from: all, active: [])
            XCTAssertEqual(tiles.map(\.id), listed.flatMap(\.items).map(\.canonical),
                           "the Journal's tiles follow the list's groups")
        }
    }

    func testAPickedGroupIsSavedAndNeverChangesTheKey() throws {
        let name = "JournalQuestionSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let catalog = JournalCatalogStore(defaults: defaults)
        catalog.addCustom("Did you nap?")
        JournalQuestionEditing.setGroup(.sleep, for: "Did you nap?", in: catalog)
        JournalQuestionEditing.setGroup(.supplements, for: magnesium, in: catalog)

        let reloaded = JournalCatalogStore(defaults: defaults)
        let nap = try item("Did you nap?", in: reloaded)
        XCTAssertEqual(nap.canonical, "Did you nap?")
        XCTAssertEqual(coachingPresentationGroup(for: nap), .sleep)
        XCTAssertEqual(coachingPresentationGroup(for: try item(magnesium, in: reloaded)), .supplements)
    }

    func testAQuestionSavedBeforeGroupsWerePickableStillOpens() throws {
        let json = #"{"canonical":"Did you nap?","kind":{"bool":{}},"group":"other","sortIndex":0,"hidden":false,"custom":true}"#
        let decoded = try JSONDecoder().decode(JournalCatalogItem.self, from: Data(json.utf8))
        XCTAssertNil(decoded.coachingGroup)
        XCTAssertEqual(coachingPresentationGroup(for: decoded), .training, "Other still lists under Training & activity")
    }

    // MARK: Answer

    func testThePageReportsWhatTheJournalTileActuallyDoes() throws {
        let catalog = try makeCatalog()
        for item in catalog.resolvedItems(imported: [], includeHidden: true) {
            let tile = JournalQuickLogTile(item: item)
            switch JournalQuestionEditing.answerKind(of: item) {
            case .yesNo: XCTAssertNil(tile.amount, "\(item.canonical) is Yes / No on the page, so its tile must not count")
            case .number, .fixedAmount: XCTAssertNotNil(tile.amount, "\(item.canonical) counts on its tile, so the page must say so")
            }
        }
    }

    func testQuestionsTheJournalCountsAreFixedAndNameTheirUnit() throws {
        let catalog = try makeCatalog()
        let expected: [String: String] = [alcohol: "drinks", "Did you use a sauna?": "min", magnesium: "doses",
                                          "Did you have caffeine late in the day?": "servings"]
        for (question, unit) in expected {
            XCTAssertEqual(JournalQuestionEditing.answerKind(of: try item(question, in: catalog)),
                           .fixedAmount(unit: unit), question)
        }
        XCTAssertEqual(JournalQuestionEditing.answerTitle(.fixedAmount(unit: "drinks")), "Amount (drinks)")
        XCTAssertEqual(JournalQuestionEditing.answerKind(of: try item("Did you view a screen in bed?", in: catalog)), .yesNo)
    }

    func testANumberQuestionNamesItsUnit() throws {
        let catalog = try makeCatalog()
        catalog.addCustom("Water", kind: .numeric(unitLabel: "L"))
        catalog.addCustom("Steps goal", kind: .numeric(unitLabel: nil))
        XCTAssertEqual(JournalQuestionEditing.answerKind(of: try item("Water", in: catalog)), .number(unit: "L"))
        XCTAssertEqual(JournalQuestionEditing.answerTitle(.number(unit: "L")), "Number (L)")
        XCTAssertEqual(JournalQuestionEditing.answerTitle(JournalQuestionEditing.answerKind(of: try item("Steps goal", in: catalog))),
                       "Number")
    }


    func testAnswerConvertsBetweenYesNoAndNumber() throws {
        let catalog = try makeCatalog()
        catalog.addCustom("Water")
        XCTAssertEqual(JournalQuestionEditing.answer(of: try item("Water", in: catalog)), .yesNo)

        JournalQuestionEditing.setAnswer(.number, for: "Water", in: catalog)
        let counted = try item("Water", in: catalog)
        XCTAssertEqual(JournalQuestionEditing.answer(of: counted), .number)
        XCTAssertNil(counted.kind.unitLabel)
        XCTAssertEqual(counted.canonical, "Water")

        JournalQuestionEditing.setAnswer(.yesNo, for: "Water", in: catalog)
        XCTAssertEqual(JournalQuestionEditing.answer(of: try item("Water", in: catalog)), .yesNo)
        XCTAssertFalse(try item("Water", in: catalog).kind.isNumeric)
    }

    func testChoosingNumberAgainKeepsTheUnitItAlreadyHas() throws {
        let catalog = try makeCatalog()
        catalog.addCustom("Water", kind: .numeric(unitLabel: "L"))
        JournalQuestionEditing.setAnswer(.number, for: "Water", in: catalog)
        XCTAssertEqual(try item("Water", in: catalog).kind.unitLabel, "L")
    }

    func testABuiltInQuestionCanChangeItsAnswerToo() throws {
        let catalog = try makeCatalog()
        let screen = "Did you view a screen in bed?"
        JournalQuestionEditing.setAnswer(.number, for: screen, in: catalog)
        let changed = try item(screen, in: catalog)
        XCTAssertTrue(changed.kind.isNumeric)
        XCTAssertEqual(changed.canonical, screen)
        XCTAssertFalse(changed.custom)
    }

    // MARK: Show in Journal

    func testAQuestionWithNoMembershipYetIsAsked() throws {
        let catalog = try makeCatalog()
        XCTAssertTrue(JournalQuestionEditing.isShown(try item(alcohol, in: catalog), membership: nil))
    }

    func testTurningOffOnlySwitchesTheQuestionOff() throws {
        let catalog = try makeCatalog()
        catalog.addCustom("Did you nap?")
        let off = JournalQuestionEditing.setShown(false, canonical: "Did you nap?",
                                                  membership: membership("Did you nap?"), in: catalog)
        XCTAssertFalse(off.isActive)
        XCTAssertEqual(off.sortIndex, 3)
        XCTAssertEqual(off.coachingGroup, CoachingCheckInGroup.fuel.rawValue)
        let napItem = try item("Did you nap?", in: catalog)
        XCTAssertFalse(napItem.hidden)
        XCTAssertTrue(napItem.custom, "a toggle never deletes a custom question")
        XCTAssertFalse(JournalQuestionEditing.isShown(napItem, membership: off))
    }

    func testTurningOnBringsBackAQuestionThatWasHidden() throws {
        let catalog = try makeCatalog()
        catalog.remove(alcohol)   // a built-in question is hidden, not deleted
        let hidden = try item(alcohol, in: catalog)
        XCTAssertTrue(hidden.hidden)
        XCTAssertFalse(JournalQuestionEditing.isShown(hidden, membership: membership(alcohol, active: true)),
                       "a hidden question is off even though its membership says active")

        let on = JournalQuestionEditing.setShown(true, canonical: alcohol,
                                                 membership: membership(alcohol, active: false), in: catalog)
        XCTAssertTrue(on.isActive)
        let restored = try item(alcohol, in: catalog)
        XCTAssertFalse(restored.hidden)
        XCTAssertTrue(JournalQuestionEditing.isShown(restored, membership: on))
        XCTAssertTrue(catalog.resolvedItems(imported: [], includeHidden: false).contains { $0.canonical == alcohol })
    }

    // MARK: Delete

    func testDeletingACustomQuestionRemovesIt() throws {
        let catalog = try makeCatalog()
        catalog.addCustom("Did you nap?")
        XCTAssertTrue(JournalQuestionEditing.delete("Did you nap?", from: catalog))
        XCTAssertFalse(catalog.resolvedItems(imported: [], includeHidden: true).contains { $0.canonical == "Did you nap?" })
        XCTAssertFalse(catalog.isCustom("Did you nap?"))
    }

    func testABuiltInQuestionCannotBeDeleted() throws {
        let catalog = try makeCatalog()
        XCTAssertFalse(JournalQuestionEditing.delete(alcohol, from: catalog))
        XCTAssertFalse(try item(alcohol, in: catalog).hidden)
        XCTAssertEqual(catalog.resolvedItems(imported: [], includeHidden: true).count,
                       JournalCatalogStore.starterQuestions.count)
    }

    // MARK: Identifiers

    func testAccessibilitySlugIsStableAndReadable() {
        XCTAssertEqual(JournalQuestionEditing.slug(alcohol), "did-you-drink-any-alcohol")
        XCTAssertEqual(JournalQuestionEditing.slug("  Water (L)\n"), "water-l")
        XCTAssertEqual(JournalQuestionEditing.slug(alcohol), JournalQuestionEditing.slug(" DID you drink  any alcohol? "))
    }
}
