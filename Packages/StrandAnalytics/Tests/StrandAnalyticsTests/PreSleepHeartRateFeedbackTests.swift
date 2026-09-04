import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

final class PreSleepHeartRateFeedbackTests: XCTestCase {
    private let dayWindow = 0..<100_000
    private let sleep = SleepSession(start: 10_000, end: 36_000, efficiency: 0.9,
                                     stages: [], restingHR: nil, avgHRV: nil)

    private func samples(_ start: Int, bpm: Int, count: Int) -> [HRSample] {
        (0..<count).map { HRSample(ts: start + $0 * 60, bpm: bpm) }
    }

    func testOptOutReturnsNoObservation() {
        let feedback = PreSleepHeartRateFeedback.evaluate(
            enabled: false, sessions: [sleep], hr: samples(8_800, bpm: 70, count: 12),
            history: [], journalEntries: [], day: "2026-08-05", dayWindow: dayWindow
        )
        XCTAssertEqual(feedback.eligibility, .disabled)
        XCTAssertNil(feedback.observation)
        XCTAssertEqual(feedback.recommendation, .unsupported)
    }

    func testEligibleReadingUsesPriorNightsOnlyAndKeepsJournalAsContext() throws {
        let history = [60.0, 61.0, 62.0, 63.0].enumerated().map {
            PreSleepHeartRateFeedback.HistoricalReading(day: "2026-08-0\($0.offset + 1)", meanBpm: $0.element)
        }
        let journal = JournalEntry(day: "2026-08-05", question: "Late meal", answeredYes: true, notes: nil)
        let feedback = PreSleepHeartRateFeedback.evaluate(
            enabled: true, sessions: [sleep],
            hr: samples(8_800, bpm: 70, count: 12) + samples(10_000, bpm: 55, count: 12),
            history: history, journalEntries: [journal], day: "2026-08-05", dayWindow: dayWindow
        )
        XCTAssertEqual(feedback.eligibility, .eligible)
        XCTAssertEqual(feedback.observation?.meanBpm, 70)
        XCTAssertEqual(feedback.comparison?.baselineBpm, 61.5)
        XCTAssertEqual(feedback.comparison?.deltaBpm, 8.5)
        XCTAssertEqual(feedback.inference, .notEstablished)
        XCTAssertEqual(feedback.journalContext.count, 1)

        let stored = PreSleepHeartRateFeedback.evaluate(
            observation: try XCTUnwrap(feedback.observation),
            history: history,
            journalEntries: [journal],
            day: "2026-08-05"
        )
        XCTAssertEqual(stored, feedback)
    }

    func testInsufficientCoverageAndInvalidDayFailClosed() {
        let sparse = PreSleepHeartRateFeedback.evaluate(
            enabled: true, sessions: [sleep], hr: samples(8_800, bpm: 70, count: 9),
            history: [], journalEntries: [], day: "2026-08-05", dayWindow: dayWindow
        )
        XCTAssertEqual(sparse.eligibility, .insufficientPreSleepSamples(valid: 9, required: 10))
        let invalid = PreSleepHeartRateFeedback.evaluate(
            enabled: true, sessions: [sleep], hr: samples(8_800, bpm: 70, count: 12),
            history: [], journalEntries: [], day: "2026-02-31", dayWindow: dayWindow
        )
        XCTAssertEqual(invalid.eligibility, .invalidDay)
    }

    func testPrimarySessionMustEndInsideTheEvaluationDay() {
        let longerWrongDay = SleepSession(start: 100_000, end: 150_000, efficiency: 0.9,
                                          stages: [], restingHR: nil, avgHRV: nil)
        let feedback = PreSleepHeartRateFeedback.evaluate(
            enabled: true, sessions: [longerWrongDay, sleep],
            hr: samples(8_800, bpm: 70, count: 12), history: [], journalEntries: [],
            day: "2026-08-05", dayWindow: dayWindow
        )
        XCTAssertEqual(feedback.observation?.primarySleepStartTs, sleep.start)
    }

    func testBridgedMainSleepUsesFirstFragmentOnsetForPreSleepWindow() {
        let first = SleepSession(start: 10_000, end: 20_000, efficiency: 0.9,
                                 stages: [], restingHR: nil, avgHRV: nil)
        let longerSecond = SleepSession(start: 21_000, end: 36_000, efficiency: 0.9,
                                        stages: [], restingHR: nil, avgHRV: nil)
        let feedback = PreSleepHeartRateFeedback.evaluate(
            enabled: true,
            sessions: [longerSecond, first],
            hr: samples(8_200, bpm: 68, count: 30),
            history: [], journalEntries: [], day: "2026-08-05", dayWindow: dayWindow
        )

        XCTAssertEqual(feedback.observation?.primarySleepStartTs, first.start)
        XCTAssertEqual(feedback.observation?.primarySleepEndTs, longerSecond.end)
        XCTAssertEqual(feedback.observation?.windowEndTs, first.start)
        XCTAssertEqual(feedback.observation?.meanBpm, 68)
    }

    func testHabitualTimingCanSelectShiftSleepOverLongerDaytimeNap() {
        let shiftSleep = SleepSession(start: 10 * 3_600, end: 14 * 3_600, efficiency: 0.9,
                                      stages: [], restingHR: nil, avgHRV: nil)
        let longerNap = SleepSession(start: 18 * 3_600, end: 23 * 3_600, efficiency: 0.9,
                                     stages: [], restingHR: nil, avgHRV: nil)
        let feedback = PreSleepHeartRateFeedback.evaluate(
            enabled: true,
            sessions: [longerNap, shiftSleep],
            hr: samples(10 * 3_600 - 1_800, bpm: 66, count: 30),
            history: [], journalEntries: [], day: "2026-08-05", dayWindow: dayWindow,
            habitualMidsleepSec: 12 * 3_600,
            timeZoneOffsetSeconds: 0
        )

        XCTAssertEqual(feedback.observation?.primarySleepStartTs, shiftSleep.start)
        XCTAssertEqual(feedback.observation?.meanBpm, 66)
    }

    func testDuplicateHistoryDaysAreExcludedIndependentOfInputOrder() {
        let unique = [60.0, 61.0, 62.0, 63.0].enumerated().map {
            PreSleepHeartRateFeedback.HistoricalReading(
                day: "2026-08-0\($0.offset + 1)", meanBpm: $0.element
            )
        }
        let duplicate = PreSleepHeartRateFeedback.HistoricalReading(day: "2026-08-01", meanBpm: 90)
        let arguments = (enabled: true, sessions: [sleep], hr: samples(8_800, bpm: 70, count: 12),
                         journalEntries: [JournalEntry](), day: "2026-08-05", dayWindow: dayWindow)
        let first = PreSleepHeartRateFeedback.evaluate(
            enabled: arguments.enabled, sessions: arguments.sessions, hr: arguments.hr,
            history: unique + [duplicate], journalEntries: arguments.journalEntries,
            day: arguments.day, dayWindow: arguments.dayWindow
        )
        let reversed = PreSleepHeartRateFeedback.evaluate(
            enabled: arguments.enabled, sessions: arguments.sessions, hr: arguments.hr,
            history: ([duplicate] + unique).reversed(), journalEntries: arguments.journalEntries,
            day: arguments.day, dayWindow: arguments.dayWindow
        )
        XCTAssertEqual(first, reversed)
        XCTAssertEqual(first.eligibility, .insufficientBaseline(validNights: 3, required: 4))
    }
}
