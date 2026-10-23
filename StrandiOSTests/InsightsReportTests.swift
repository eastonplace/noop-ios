import XCTest
import StrandAnalytics
import WhoopStore
@testable import NOOP

final class InsightsReportTests: XCTestCase {

    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    private func day(_ offset: Int) -> String { ExploreDayKey.key(forDayNumber: ExploreDayKey.dayNumber(for: "2026-05-01")! + offset) }

    private func ts(_ offset: Int, minutes: Int) -> Int {
        let base = utc.date(from: DateComponents(year: 2026, month: 5, day: 1))!
        return Int(base.timeIntervalSince1970) + offset * 86_400 + minutes * 60
    }

    /// Sixty nights alternating 22:40 and 23:50 onsets; early nights are followed by a morning
    /// about 12 points better. Strain and steps carry no signal.
    private func inputs() -> InsightsInputs {
        var i = InsightsInputs()
        i.calendar = utc
        var recovery: [String: Double] = [:]
        var sleep: [String: Double] = [:]
        for n in 0..<60 {
            let early = n % 2 == 0
            let onset = ts(n, minutes: early ? 1360 : 1430)
            i.nights.append(AutoFactorNight(wakeDay: day(n + 1), onsetTs: onset, endTs: onset + 7 * 3600))
            let noise = Double((n * 7) % 5) - 2
            recovery[day(n + 1)] = (early ? 66 : 54) + noise
            sleep[day(n + 1)] = 80 + noise
            i.days.append(AutoFactorDay(day: day(n + 1), totalSleepMin: 400 + Double((n * 13) % 60),
                                        strain: 30 + Double((n * 11) % 40), steps: 6000 + Double((n * 17) % 5000)))
        }
        i.outcomes = [.recovery: recovery, .sleep: sleep]
        return i
    }

    func testEarlyBedtimeBecomesAPlainSentence() throws {
        let report = InsightsReportBuilder.build(inputs())
        XCTAssertTrue(report.hasEnoughData)
        let row = try XCTUnwrap(report.significant.first { $0.source == .data(.earlyBedtime) && $0.outcome == .recovery })
        func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{202F}", with: " ") }
        XCTAssertEqual(plain(row.bedtime ?? ""), "11:30 PM")
        XCTAssertTrue(plain(row.sentence).hasPrefix("On nights you went to bed before 11:30 PM, your recovery averaged 12 points higher ("))
        XCTAssertTrue(row.sentence.hasSuffix(")."))
        XCTAssertEqual(row.deltaText, "+12 pts")
        XCTAssertEqual(plain(row.rowTitle), "In bed before 11:30 PM")
        XCTAssertTrue(row.detailLine.hasSuffix("30 vs 30 nights · Solid"))
        XCTAssertEqual(row.headline, "Your bedtime moves your recovery most")
        XCTAssertEqual(plain(row.withLabel), "Before 11:30 PM")
        XCTAssertEqual(row.countsText, "30 vs 30 nights")
        XCTAssertEqual(row.source.label, "From your data")
        XCTAssertNotNil(row.effect.adjustedP)
        XCTAssertEqual(row.effect.lag, 0)
    }

    func testSleepLengthIsNeverTestedAgainstTheSleepScore() {
        let report = InsightsReportBuilder.build(inputs())
        XCTAssertFalse(report.rows.contains { $0.source == .data(.sevenHours) && $0.outcome == .sleep })
        XCTAssertTrue(report.rows.contains { $0.source == .data(.sevenHours) && $0.outcome == .recovery })
    }

    func testFactorsWithNoSignalAreListedAsUnclear() {
        let report = InsightsReportBuilder.build(inputs())
        let names = report.unclear.map(\.name)
        XCTAssertTrue(names.contains("High-strain day"))
        XCTAssertFalse(names.contains("Early bedtime"))
    }

    func testJournalAnswersRunThroughTheSameFamily() throws {
        var i = inputs()
        for n in 0..<60 {
            i.journal.append(JournalEntry(day: day(n + 1), question: "Did you drink any alcohol?",
                                          answeredYes: n % 2 == 1, notes: nil))
        }
        let report = InsightsReportBuilder.build(i)
        let row = try XCTUnwrap(report.significant.first { $0.source.isJournal && $0.outcome == .recovery })
        XCTAssertTrue(row.sentence.hasPrefix("On days you logged Alcohol, your recovery averaged"))
        XCTAssertTrue(row.sentence.contains("points lower ("))
        XCTAssertEqual(row.rowTitle, "Alcohol")
        XCTAssertTrue(row.deltaText.hasPrefix("\u{2212}"))
        XCTAssertEqual(row.source.label, "From your Journal")
    }

    func testJournalFactorsUseTheTileNames() {
        XCTAssertEqual(InsightWords.journalQuestionTitle("Did you drink any alcohol?"), "Alcohol")
        XCTAssertEqual(InsightWords.journalQuestionTitle("Did you have caffeine late in the day?"), "Late caffeine")
    }

    func testDoseRowsStartFromTheTypicalClearDay() {
        let outcome = Dictionary(uniqueKeysWithValues: (0..<10).map { (day($0), $0 < 6 ? 60.0 : 40.0) })
        let doses = Dictionary(uniqueKeysWithValues: (6..<10).map { (day($0), 2) })
        XCTAssertEqual(InsightsHubViewModel.typicalClearDay(outcome, doses: doses), 60)
    }

    func testTooLittleHistoryIsNotEnoughData() {
        var i = InsightsInputs()
        i.outcomes = [.recovery: Dictionary(uniqueKeysWithValues: (0..<10).map { (day($0), 60.0) })]
        let report = InsightsReportBuilder.build(i)
        XCTAssertFalse(report.hasEnoughData)
        XCTAssertTrue(report.significant.isEmpty)
    }
}
