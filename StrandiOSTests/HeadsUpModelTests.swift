import XCTest
import StrandAnalytics
import WhoopStore
@testable import NOOP

/// The Heads-Up snapshot is built from the same evaluation as the alert, so these pin both: the level each history
/// reaches, the readings the card shows, the Journal words that count and the wording the surfaces use.
final class HeadsUpModelTests: XCTestCase {
    private func key(_ index: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        let date = calendar.date(byAdding: .day, value: index, to: start)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func night(_ index: Int, rhr: Int, hrv: Double, resp: Double, skin: Double) -> DailyMetric {
        DailyMetric(day: key(index), totalSleepMin: 450, efficiency: 0.9, deepMin: 80, remMin: 100, lightMin: 250,
                    disturbances: 3, restingHr: rhr, avgHrv: hrv, recovery: 60, strain: 9, exerciseCount: 1,
                    spo2Pct: 97, skinTempDevC: skin, respRateBpm: resp)
    }

    /// A steady history whose last `spiked` nights move resting HR up, HRV down and skin temperature up together.
    private func history(count: Int, spiked: Int = 0) -> [DailyMetric] {
        (0..<count).map { index in
            if index >= count - spiked {
                return night(index, rhr: 60, hrv: 45, resp: 15.2, skin: 0.8)
            }
            return night(index, rhr: 52 + (index % 3 - 1), hrv: 62 + Double(index % 5 - 2),
                         resp: 15.1 + Double(index % 3 - 1) * 0.1, skin: Double(index % 3 - 1) * 0.05)
        }
    }

    private func logged(_ question: String, on day: String) -> JournalEntry {
        JournalEntry(day: day, question: question, answeredYes: true, notes: nil)
    }

    // MARK: Phases

    func testOffWhenHeadsUpIsTurnedOff() {
        let built = HeadsUpBuilder.snapshot(days: history(count: 40, spiked: 2), journal: [], enabled: false)
        XCTAssertEqual(built.snapshot.phase, .off)
        XCTAssertNil(built.latest)
    }

    func testShortHistoryLearnsAndNeverWarns() {
        let built = HeadsUpBuilder.snapshot(days: history(count: 10, spiked: 2), journal: [], enabled: true)
        XCTAssertEqual(built.snapshot.phase, .learning(nights: 10))
        XCTAssertNil(built.latest, "The alert has never published anything below 14 days")
        XCTAssertTrue(built.snapshot.signals.allSatisfy { !$0.fired && $0.z == nil },
                      "Nothing is up or down before there is a normal to compare with")
    }

    func testSteadyHistoryIsAllClear() {
        let built = HeadsUpBuilder.snapshot(days: history(count: 40), journal: [], enabled: true)
        XCTAssertEqual(built.snapshot.phase, .scored(.quiet))
        XCTAssertEqual(built.snapshot.firedCount, 0)
        XCTAssertEqual(built.snapshot.presentCount, 4)
        XCTAssertEqual(built.snapshot.history.count, HeadsUpSnapshot.historyLength)
    }

    func testCoordinatedSpikeRaisesAndKeepsEveryReading() throws {
        let built = HeadsUpBuilder.snapshot(days: history(count: 40, spiked: 2), journal: [], enabled: true)
        XCTAssertEqual(built.snapshot.phase, .scored(.raised))
        XCTAssertEqual(built.latest?.result.level, .raised)
        XCTAssertEqual(Set(built.snapshot.signals.filter(\.fired).map(\.kind)), [.restingHR, .hrv, .skinTemp])
        XCTAssertEqual(built.snapshot.signals.map(\.kind), [.restingHR, .hrv, .skinTemp, .respiration])
        let respiration = try XCTUnwrap(built.snapshot.signals.last)
        XCTAssertFalse(respiration.fired, "A normal signal is still shown, not dropped")
        XCTAssertNotNil(respiration.z)
        XCTAssertNotNil(built.snapshot.confidence)
        XCTAssertEqual(built.snapshot.history.count, HeadsUpSnapshot.historyLength)
        let last = try XCTUnwrap(built.snapshot.history.last)
        XCTAssertEqual(last.day, key(39))
        XCTAssertEqual(last.score, built.snapshot.score, accuracy: 1e-9, "The chart ends on today's read")
        let restingHR = try XCTUnwrap(built.snapshot.signals.first)
        XCTAssertEqual(restingHR.history.count, HeadsUpSnapshot.historyLength)
        let band = try XCTUnwrap(restingHR.normalBand)
        XCTAssertTrue(band.contains(52), "The normal range surrounds the usual resting HR")
        XCTAssertFalse(band.contains(60), "The spiked nights sit outside it")
    }

    func testLoggedAlcoholExplainsTheSpike() throws {
        let days = history(count: 40, spiked: 2)
        let journal = [logged("Did you drink any alcohol?", on: key(39))]
        let built = HeadsUpBuilder.snapshot(days: days, journal: journal, enabled: true)
        XCTAssertEqual(built.snapshot.phase, .scored(.suppressed))
        XCTAssertEqual(built.snapshot.causes, [.alcohol])
        let raw = try XCTUnwrap(built.snapshot.rawScore)
        XCTAssertEqual(raw * IllnessSignalEngine.confounderDampen, built.snapshot.score, accuracy: 1e-9)
        XCTAssertNil(built.snapshot.confidence, "Confidence grades only a raised read")
    }

    func testLoggedSicknessSwitchesToRest() {
        let days = history(count: 40, spiked: 2)
        let journal = [logged("Did you feel sick or ill?", on: key(38))]
        let built = HeadsUpBuilder.snapshot(days: days, journal: journal, enabled: true)
        XCTAssertEqual(built.snapshot.phase, .scored(.alreadyUnwell))
        XCTAssertEqual(built.snapshot.unwellDay, key(38))
    }

    func testOlderLogsOutsideTheWindowDoNotCount() {
        let days = history(count: 40, spiked: 2)
        let journal = [logged("Did you drink any alcohol?", on: key(30))]
        let built = HeadsUpBuilder.snapshot(days: days, journal: journal, enabled: true)
        XCTAssertEqual(built.snapshot.phase, .scored(.raised))
    }

    // MARK: Journal words

    func testJournalMatchingUsesWholeWords() {
        let day: Set<String> = [key(1)]
        func causes(_ question: String) -> HeadsUpBuilder.JournalContext {
            HeadsUpBuilder.context(days: day, journal: [logged(question, on: key(1))])
        }
        XCTAssertTrue(causes("Did you feel sick or ill?").alreadyUnwell)
        XCTAssertFalse(causes("Did you take any pills?").alreadyUnwell, "\"pills\" is not \"ill\"")
        XCTAssertFalse(causes("Did you chill out after work?").alreadyUnwell)
        XCTAssertEqual(causes("Did you drink any alcohol?").causes, [.alcohol])
        XCTAssertEqual(causes("Did you drink enough water?").causes, [], "Water is not alcohol")
        XCTAssertEqual(causes("Did you use a sauna?").causes, [.sauna])
        XCTAssertEqual(causes("Did you feel stressed?").causes, [.stress])
        XCTAssertEqual(causes("Trained late in the evening?").causes, [.hardWorkout])
        XCTAssertEqual(causes("Did you strain your back?").causes, [], "\"strain\" is not \"train\"")
    }

    func testOnlyYesAnswersCount() {
        let entry = JournalEntry(day: key(1), question: "Did you drink any alcohol?", answeredYes: false, notes: nil)
        XCTAssertEqual(HeadsUpBuilder.context(days: [key(1)], journal: [entry]).causes, [])
    }

    // MARK: Wording

    func testSignedNumbersUseARealMinus() {
        XCTAssertEqual(HeadsUpPresentation.signed(6.2, fractionDigits: 0), "+6")
        XCTAssertEqual(HeadsUpPresentation.signed(-21.6, fractionDigits: 0), "\u{2212}22")
        XCTAssertEqual(HeadsUpPresentation.signed(0.74, fractionDigits: 1), "+0.7")
        XCTAssertEqual(HeadsUpPresentation.signed(0.02, fractionDigits: 1), "0.0")
    }

    func testRaisedCardCountsSignalsAndShowsTheBanner() throws {
        let built = HeadsUpBuilder.snapshot(days: history(count: 40, spiked: 2), journal: [], enabled: true)
        let card = HeadsUpPresentation.card(built.snapshot)
        XCTAssertEqual(card.pill, "3 of 4 up")
        XCTAssertTrue(card.lineIsPrimary)
        guard case let .signals(cells) = card.content else { return XCTFail("A read shows its signals") }
        XCTAssertEqual(cells.count, 4)
        let restingHR = try XCTUnwrap(cells.first)
        XCTAssertTrue(restingHR.delta.hasPrefix("+"), "Resting HR reads as a rise: \(restingHR.delta)")
        XCTAssertEqual(restingHR.unit, "bpm")
        XCTAssertEqual(restingHR.state, "Up")
        XCTAssertNotNil(restingHR.emphasis)
        XCTAssertEqual(cells[1].state, "Down")
        XCTAssertNil(cells[3].emphasis, "Respiration stayed normal")
        XCTAssertEqual(HeadsUpPresentation.bannerLine(built.snapshot), "Heads-up: your body looks run down")
    }

    func testCalmReadsHaveNoBanner() {
        let clear = HeadsUpBuilder.snapshot(days: history(count: 40), journal: [], enabled: true).snapshot
        XCTAssertNil(HeadsUpPresentation.bannerLine(clear))
        XCTAssertEqual(HeadsUpPresentation.card(clear).pill, "All clear")
        XCTAssertNil(HeadsUpPresentation.bannerLine(HeadsUpSnapshot.off))
        XCTAssertEqual(HeadsUpPresentation.card(HeadsUpSnapshot.off).content, .turnOn)
    }

    func testExplainedCardNamesTheCause() throws {
        let journal = [logged("Did you drink any alcohol?", on: key(39))]
        let explained = HeadsUpBuilder.snapshot(days: history(count: 40, spiked: 2), journal: journal, enabled: true).snapshot
        let card = HeadsUpPresentation.card(explained)
        XCTAssertEqual(card.pill, "Explained")
        XCTAssertEqual(card.line, "Signals are up, but you logged alcohol. Likely that.")
        XCTAssertEqual(try XCTUnwrap(card.chip).text, "Alcohol logged · likely the cause")
        XCTAssertNotNil(HeadsUpPresentation.meterNote(explained))
    }

    func testLearningCardShowsProgress() {
        let learning = HeadsUpBuilder.snapshot(days: history(count: 9), journal: [], enabled: true).snapshot
        guard case let .progress(fraction, leading, _) = HeadsUpPresentation.card(learning).content else {
            return XCTFail("Learning shows progress")
        }
        XCTAssertEqual(fraction, 9.0 / Double(HeadsUpSnapshot.nightsNeeded), accuracy: 1e-9)
        XCTAssertEqual(leading, "9 of \(HeadsUpSnapshot.nightsNeeded) nights")
    }
}
