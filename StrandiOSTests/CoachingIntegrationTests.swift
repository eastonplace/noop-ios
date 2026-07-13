import XCTest
import StrandAnalytics
import WhoopStore
@testable import NOOP

/// Spec 007 / T138: the six externally approved data-integrity oracles. These pin the existing
/// journal and EffectRanker contracts around the additive coaching metadata and stack provenance.
@MainActor
final class CoachingIntegrationTests: XCTestCase {
    private func unique(_ stem: String) -> String { "T138 \(stem) \(UUID().uuidString)" }

    func testOracle1CoachingMetadataDoesNotChangeImportedNativeMerge() async throws {
        let day = "2026-07-01"
        let question = unique("collision")
        let imported = [JournalEntry(day: day, question: question, answeredYes: false, notes: "imported")]
        let native = [JournalEntry(day: day, question: question, answeredYes: true, notes: "native")]
        let before = Repository.mergeJournal(imported: imported, native: native)

        let store = try await WhoopStore.inMemory()
        _ = try await store.ensureDefaultCoachingSet(name: "Oracle", memberships: [
            CoachingBehaviorMembership(setId: "daily-fundamentals", canonicalQuestion: question,
                                       coachingGroup: "Recovery & stress", sortIndex: 0,
                                       isActive: true, isQuickAdd: true),
        ])
        let stack = CoachingStack(id: "oracle-stack", name: "Oracle", description: nil,
                                  scheduleLabel: "Daily", isActive: true, notes: nil, sortIndex: 0)
        _ = try await store.ensureDefaultCoachingStack(stack, items: [
            CoachingStackItem(stackId: stack.id, canonicalQuestion: question,
                              dose: nil, unit: nil, sortIndex: 0),
        ])

        let after = Repository.mergeJournal(imported: imported, native: native)
        XCTAssertEqual(after, before)
        XCTAssertEqual(after.first?.notes, "native", "native collision precedence must remain unchanged")
    }

    func testOracle2BooleanCheckInPersistsAcrossRepositoryRecreation() async {
        let day = Repository.localDayKey(Date())
        let question = unique("boolean")
        let first = Repository(deviceId: "my-whoop")
        await first.saveJournalAnswer(day: day, question: question, answeredYes: true)

        let relaunched = Repository(deviceId: "my-whoop")
        let answers = await relaunched.nativeJournalAnswers(day: day)
        XCTAssertEqual(answers[question], true)
        await relaunched.clearJournalAnswer(day: day, question: question)
    }

    func testOracle3PositiveQuantityRoundTripsAndRemainsBooleanOccurrence() async {
        let day = Repository.localDayKey(Date())
        let question = unique("quantity")
        let first = Repository(deviceId: "my-whoop")
        await first.saveJournalNumeric(day: day, question: question, value: 2.5)

        let relaunched = Repository(deviceId: "my-whoop")
        let quantities = await relaunched.nativeJournalNumeric(day: day)
        let answers = await relaunched.nativeJournalAnswers(day: day)
        XCTAssertEqual(quantities[question], 2.5)
        XCTAssertEqual(answers[question], true)
        await relaunched.clearJournalAnswer(day: day, question: question)
    }

    func testOracle4StackWritesTwoJournalOccurrencesAndOneUseRow() async throws {
        let day = Repository.localDayKey(Date())
        let stackId = unique("stack")
        let firstQuestion = unique("stack bool")
        let secondQuestion = unique("stack dose")
        let repo = Repository(deviceId: "my-whoop")
        let items = [
            CoachingStackItem(stackId: stackId, canonicalQuestion: firstQuestion,
                              dose: nil, unit: nil, sortIndex: 0),
            CoachingStackItem(stackId: stackId, canonicalQuestion: secondQuestion,
                              dose: 10, unit: "mg", sortIndex: 1),
        ]

        let use = await repo.logCoachingStack(stackId: stackId, day: day, items: items,
                                              notes: "oracle", skipped: false)
        XCTAssertNotNil(use)
        let answers = await repo.nativeJournalAnswers(day: day)
        let numeric = await repo.nativeJournalNumeric(day: day)
        XCTAssertEqual(answers[firstQuestion], true)
        XCTAssertEqual(answers[secondQuestion], true)
        XCTAssertEqual(numeric[secondQuestion], 10)
        let storeHandle = await repo.storeHandle()
        let store = try XCTUnwrap(storeHandle)
        let uses = try await store.coachingStackUses(stackId: stackId)
        XCTAssertEqual(uses.filter { $0.id == use?.id }.count, 1)
        await repo.clearJournalAnswer(day: day, question: firstQuestion)
        await repo.clearJournalAnswer(day: day, question: secondQuestion)
    }

    func testOracle5EffectRankerOutputIsIdenticalAfterCoachingMetadata() async throws {
        let behaviorDays = Set((1...6).map { String(format: "2026-06-%02d", $0) })
        var outcome: [String: Double] = [:]
        for day in 1...6 { outcome[String(format: "2026-06-%02d", day)] = 50 + Double(day % 3) }
        for day in 10...20 { outcome[String(format: "2026-06-%02d", day)] = 70 + Double(day % 3) }
        let inputs = ["Alcohol": behaviorDays]
        let before = EffectRanker.rank(behaviors: inputs, outcomeByDay: outcome, outcome: "Charge")

        let store = try await WhoopStore.inMemory()
        _ = try await store.ensureDefaultCoachingSet(name: "Oracle", memberships: [
            CoachingBehaviorMembership(setId: "daily-fundamentals", canonicalQuestion: "Alcohol",
                                       coachingGroup: "Fuel", sortIndex: 0,
                                       isActive: true, isQuickAdd: true),
        ])
        let after = EffectRanker.rank(behaviors: inputs, outcomeByDay: outcome, outcome: "Charge")

        XCTAssertFalse(before.isEmpty)
        XCTAssertEqual(after, before, "effects, lags, means, samples, confidence, and ordering must match")
    }

    func testOracle6ClearingNativeAnswerLeavesImportedCollisionReadable() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2026-07-02"
        let question = unique("clear collision")
        let imported = JournalEntry(day: day, question: question, answeredYes: true, notes: "imported")
        let native = JournalEntry(day: day, question: question, answeredYes: false, notes: "native")
        _ = try await store.upsertJournal([imported], deviceId: "imported-oracle")
        _ = try await store.upsertJournal([native], deviceId: Repository.journalDeviceId)
        _ = try await store.deleteJournal(deviceId: Repository.journalDeviceId, day: day, question: question)

        let importedAfterClear = try await store.journalEntries(deviceId: "imported-oracle", from: day, to: day)
        XCTAssertEqual(importedAfterClear, [imported])
        let merged = Repository.mergeJournal(imported: importedAfterClear, native: [])
        XCTAssertEqual(merged, [imported])
    }
}
