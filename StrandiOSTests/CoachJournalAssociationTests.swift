#if os(iOS)
import XCTest
import StrandAnalytics
@testable import NOOP

final class CoachJournalAssociationTests: XCTestCase {
    func testJournalCardRoundTripsWithStableHabitAndWindowIdentity() throws {
        let card = LocalCoachCard.journalAssociation(try insight())
        let decoded = try JSONDecoder().decode(LocalCoachCard.self, from: JSONEncoder().encode(card))

        XCTAssertEqual(decoded, card)
        XCTAssertEqual(card.kind, "journalAssociation")
        XCTAssertTrue(card.id.contains("did you take magnesium?"))
        XCTAssertTrue(card.id.contains("2026-10-01:2026-10-10"))
        XCTAssertEqual(card.day, "2026-10-07")
        XCTAssertFalse(card.isStale, "A dated historical comparison is not current-day readiness")
    }

    func testJournalExportDisclosesCountsMissingOutcomesSourcesAndAssociationLimit() throws {
        let text = LocalCoachCardFormat.exportLine(.journalAssociation(try insight()))

        for required in ["2026-10-01", "2026-10-10", "yes 3", "no 3", "missing recovery 1",
                         "journal-native", "canonical-test", "80.0", "60.0", "association", "causation"] {
            XCTAssertTrue(text.lowercased().contains(required.lowercased()), required)
        }
        XCTAssertFalse(text.contains("0 missing"))
    }

    func testTruncatedCardHasNoNumericEffectOrPlausibleZeroCountsInExport() throws {
        let text = LocalCoachCardFormat.exportLine(.journalAssociation(try insight(truncated: true)))

        XCTAssertTrue(text.contains("4096"))
        XCTAssertTrue(text.lowercased().contains("incomplete"))
        XCTAssertTrue(text.lowercased().contains("counts withheld"))
        XCTAssertFalse(text.contains("mean"))
        XCTAssertFalse(text.contains("difference 0"))
        XCTAssertFalse(text.contains("yes 0"))
    }

    func testInsufficientCardExplainsBothMinimumGroupsAndDoesNotExportMeans() throws {
        let text = LocalCoachCardFormat.exportLine(.journalAssociation(try insight(insufficient: true)))

        XCTAssertTrue(text.contains("at least 3"))
        XCTAssertTrue(text.contains("yes 3"))
        XCTAssertTrue(text.contains("no 2"))
        XCTAssertFalse(text.contains("mean"))
    }

    func testCardSelectionPrioritizesRequestedHabitWithoutRankingByEffect() throws {
        let values = try ["Alcohol", "Caffeine", "Magnesium", "Sauna"].map { try insight(question: $0) }
        let cards = LocalCoachCard.journalAssociationCards(Array(values.reversed()), query: "Compare my sauna journal records")

        XCTAssertEqual(cards.count, 3)
        guard case .journalAssociation(let first)? = cards.first else { return XCTFail("Expected a journal insight") }
        XCTAssertEqual(first.question, "Sauna")
        XCTAssertEqual(cards, LocalCoachCard.journalAssociationCards(values, query: "Compare my sauna journal records"))
    }

    func testJournalFollowUpKeepsTheHabitAndDateRangeAndAsksAboutLimits() throws {
        let value = try insight()
        let prompt = LocalCoachCardFormat.journalFollowUp(value)
        let message = LocalCoachMessage(role: .assistant, text: "", cards: [.journalAssociation(value)])

        XCTAssertTrue(prompt.contains("Did you take magnesium?"))
        XCTAssertTrue(prompt.contains("2026-10-01"))
        XCTAssertTrue(prompt.contains("2026-10-10"))
        XCTAssertTrue(prompt.lowercased().contains("association"))
        XCTAssertEqual(CoachFollowUps.suggestions(for: message).first?.prompt, prompt)
    }

    private func insight(question: String = "Did you take magnesium?", truncated: Bool = false,
                         insufficient: Bool = false) throws -> JournalAssociationAnalysis.Insight {
        let answers = (1...7).map { day in
            JournalAssociationAnalysis.Answer(day: key(day), question: question, answeredYes: day <= 3 || day == 7)
        }
        let values = [80.0, 70.0, 90.0, 50.0, 60.0, 70.0]
        let recovery = values.prefix(insufficient ? 5 : 6).enumerated().map {
            JournalAssociationAnalysis.Recovery(day: key($0.offset + 1), value: $0.element)
        }
        return try XCTUnwrap(JournalAssociationAnalysis.analyze(
            reads: [.init(source: "journal-native", answers: answers, isTruncated: truncated)],
            recovery: recovery, nativeSource: "journal-native", recoverySource: "canonical-test",
            windowFrom: "2026-10-01", windowThrough: "2026-10-10").first)
    }

    private func key(_ day: Int) -> String { String(format: "2026-10-%02d", day) }
}

#if os(iOS)
@MainActor
final class CoachJournalAssociationConsentTests: XCTestCase {
    func testJournalReadRequiresPersonalDataConsentBeforeOpeningStore() async {
        let repo = Repository(deviceId: "coach-journal-consent-test")
        let service = LocalCoachDataService(repo: repo, access: { false }, now: Date.init)
        do {
            _ = try await service.query("journal_associations", query: "", days: 7)
            XCTFail("No journal data or card can escape without consent")
        } catch let error as LocalCoachDataError {
            XCTAssertEqual(error, .consentRequired)
        } catch { XCTFail("Expected the consent error, not a store read: \(error)") }
    }
}
#endif
#endif
