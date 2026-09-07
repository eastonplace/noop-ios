import Foundation
import Testing
#if canImport(NOOP)
@testable import NOOP
#else
@testable import ExperiencePolicies
#endif

@Suite("Journal experience")
struct JournalExperiencePolicyTests {
    @Test func noAndUnansweredAreDifferent() {
        var draft = JournalDraft(day: "2026-09-06", answers: [:])
        draft.set(.boolean(false), for: "Sleep")
        #expect(draft.answers["Sleep"] == .boolean(false))
        #expect(draft.changedKeys == ["Sleep"])
        draft.set(nil, for: "Sleep")
        #expect(draft.changedKeys.isEmpty)
    }
    @Test func zeroStaysNumeric() {
        var draft = JournalDraft(day: "2026-09-06", answers: [:])
        draft.set(.number(0), for: "Amount")
        #expect(draft.answers["Amount"] == .number(0))
        #expect(draft.changedKeys == ["Amount"])
    }
    @Test func copyOnlyFillsMissingActiveQuestions() {
        var draft = JournalDraft(day: "2026-09-06", answers: ["a": .boolean(false)])
        let count = draft.copyMissing(from: ["a": .boolean(true), "b": .number(0), "c": .boolean(true)],
                                      activeKeys: ["a", "b"])
        #expect(count == 1)
        #expect(draft.answers["a"] == .boolean(false))
        #expect(draft.answers["b"] == .number(0))
        #expect(draft.answers["c"] == nil)
    }
    @Test func editsKeepTheirDayAndOnlyWriteChanges() {
        var draft = JournalDraft(day: "2026-09-06", answers: ["a": .boolean(true), "b": .number(3)])
        draft.set(.number(4), for: "b")
        #expect(draft.day == "2026-09-06")
        #expect(draft.changedKeys == ["b"])
        #expect(draft.baseline["b"] == .number(3))
    }
    @Test func acceptingSaveClearsDirtyState() {
        var draft = JournalDraft(day: "2026-09-06", answers: [:])
        draft.set(.boolean(false), for: "a")
        draft.acceptSavedAnswers(draft.answers)
        #expect(draft.changedKeys.isEmpty)
    }
    @Test func nonfiniteInitialValuesCannotPoisonEquality() {
        let draft = JournalDraft(day: "2026-09-06", answers: ["a": .number(.nan)])
        #expect(draft.changedKeys.isEmpty)
        #expect(draft.answers.isEmpty)
    }
    @Test func decimalsUseTheChosenLocale() {
        #expect(JournalNumberInput.parse("1.25", locale: Locale(identifier: "en_US")) == .value(1.25))
        #expect(JournalNumberInput.parse("1,25", locale: Locale(identifier: "de_DE")) == .value(1.25))
        #expect(JournalNumberInput.parse("0", locale: Locale(identifier: "en_US")) == .value(0))
        #expect(JournalNumberInput.parse(" ", locale: Locale(identifier: "en_US")) == .empty)
    }
    @Test(arguments: ["NaN", "inf", "-1", "1e300", "1,234", "1..2", ".", "+"])
    func invalidInputIsRejected(_ text: String) {
        #expect(JournalNumberInput.parse(text, locale: Locale(identifier: "en_US")) == .invalid)
    }
    @Test func emptyMembershipMeansNoActiveQuestions() {
        #expect(JournalExperiencePolicy.visibleKeys(catalogKeys: ["a", "b"], activeKeys: []) == [])
        #expect(JournalExperiencePolicy.visibleKeys(catalogKeys: ["a", "b"], activeKeys: ["b"]) == ["b"])
    }
    @Test func dateAnchorUsesCalendarDaysAcrossDST() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let date = cal.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        let previous = JournalExperiencePolicy.day(offset: 1, from: date, calendar: cal)
        #expect(cal.component(.day, from: previous) == 7)
        #expect(JournalExperiencePolicy.dayKey(date, calendar: cal) == "2026-03-08")
    }
}
