import XCTest
import StrandAnalytics
import StrandDesign
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

    /// A night the strap recorded nothing overnight.
    private func gap(_ index: Int) -> DailyMetric {
        DailyMetric(day: key(index), totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil,
                    spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil)
    }

    /// A steady history whose last 2 nights change only the given readings.
    private func history(count: Int, lastTwo change: (Int) -> DailyMetric) -> [DailyMetric] {
        Array(history(count: count).dropLast(2)) + [change(count - 2), change(count - 1)]
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
        XCTAssertEqual(built.snapshot.phase, .learning(nights: 7), "The newest 3 nights are not baseline nights")
        XCTAssertNil(built.latest, "The alert has never published anything below 14 days")
        XCTAssertTrue(built.snapshot.signals.allSatisfy { !$0.fired && $0.z == nil },
                      "Nothing is up or down before there is a normal to compare with")
    }

    func testLearningProgressOnlyRisesUntilTheFirstRead() {
        var previous = -1
        var firstRead: Int?
        for count in 10...18 {
            let phase = HeadsUpBuilder.snapshot(days: history(count: count), journal: [], enabled: true).snapshot.phase
            switch phase {
            case .learning(let nights):
                XCTAssertNil(firstRead, "\(count) nights: learning again after the first read")
                XCTAssertGreaterThanOrEqual(nights, previous, "\(count) nights: progress went backwards")
                previous = nights
            case .scored:
                if firstRead == nil { firstRead = count }
            case .off:
                XCTFail("Heads-Up is on")
            }
        }
        XCTAssertEqual(previous, HeadsUpSnapshot.nightsNeeded - 1, "Progress reaches the last step before the read")
        XCTAssertEqual(firstRead, HeadsUpSnapshot.nightsNeeded + 3, "14 baseline nights plus the 3 newest")
    }

    func testMissingRecentNightsKeepAnEstablishedBaselineScored() {
        let days = history(count: 40) + [gap(40), gap(41)]
        let snapshot = HeadsUpBuilder.snapshot(days: days, journal: [], enabled: true).snapshot
        XCTAssertEqual(snapshot.phase, .scored(.quiet), "Two nights off the wrist must not restart learning")
        XCTAssertEqual(snapshot.presentCount, 0)
        XCTAssertEqual(HeadsUpPresentation.card(snapshot).line, "No overnight signals in the last 2 nights.")
    }

    func testOneSignalAloneStaysClearAndSaysSo() throws {
        let days = history(count: 40) { self.night($0, rhr: 60, hrv: 62, resp: 15.1, skin: 0) }
        let snapshot = HeadsUpBuilder.snapshot(days: days, journal: [], enabled: true).snapshot
        XCTAssertEqual(snapshot.phase, .scored(.quiet), "One signal never raises")
        XCTAssertEqual(snapshot.signals.filter(\.fired).map(\.kind), [.restingHR])
        let card = HeadsUpPresentation.card(snapshot)
        XCTAssertEqual(card.pill, "All clear")
        XCTAssertEqual(card.line, "Resting HR is up on its own. One signal alone isn’t a pattern.")
        guard case let .signals(cells) = card.content else { return XCTFail("A read shows its signals") }
        let restingHR = try XCTUnwrap(cells.first)
        XCTAssertEqual(restingHR.state, "Up")
        XCTAssertEqual(restingHR.emphasis, StrandPalette.textPrimary, "A move on an all-clear read is not painted green")
    }

    func testAMoveTheOtherWayIsNotCalledNormal() throws {
        let days = history(count: 40) { self.night($0, rhr: 52, hrv: 90, resp: 15.1, skin: 0) }
        let snapshot = HeadsUpBuilder.snapshot(days: days, journal: [], enabled: true).snapshot
        XCTAssertEqual(snapshot.phase, .scored(.quiet))
        XCTAssertEqual(snapshot.firedCount, 0, "A higher HRV is not illness-ward")
        let hrv = try XCTUnwrap(snapshot.signals.first { $0.kind == .hrv })
        XCTAssertEqual(HeadsUpPresentation.stateWord(hrv), "Higher")
        XCTAssertEqual(HeadsUpPresentation.card(snapshot).line, "Nothing points to being run down.")
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
        XCTAssertEqual(fraction, 6.0 / Double(HeadsUpSnapshot.nightsNeeded), accuracy: 1e-9)
        XCTAssertEqual(leading, "6 of \(HeadsUpSnapshot.nightsNeeded) nights")
    }

    // MARK: Elsewhere today

    private func firstPaint(day: String, sleepMinutes: Double, strain: Double, recovery: Double) -> TodayHealthSnapshot {
        func value(_ number: Double, version: Int? = nil) -> TodayHealthMetricValue {
            TodayHealthMetricValue(value: number, metricDay: day, sourceId: "my-whoop-noop",
                                   strainVersion: version)
        }
        return TodayHealthSnapshot(
            scopeId: "dashboard:test", deviceId: "my-whoop", displayDay: day, logicalDay: day, localDay: day,
            generatedAt: 1, schemaVersion: 2,
            dailyMetric: DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                                     lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil,
                                     recovery: nil, strain: nil, exerciseCount: nil),
            recovery: value(recovery), strain: value(strain, version: 2),
            sleepDurationMinutes: value(sleepMinutes))
    }

    func testElsewhereTodayReadsTheSameValuesAsTodaysRings() {
        let today = key(40)
        // The raw daily row disagrees with what Today shows: a different sleep length and a different Strain.
        var days = history(count: 40)
        days.append(DailyMetric(day: today, totalSleepMin: 406.8, efficiency: 0.9, deepMin: 80, remMin: 100,
                                lightMin: 250, disturbances: 3, restingHr: 52, avgHrv: 62, recovery: 71,
                                strain: 60.5, exerciseCount: 1, spo2Pct: 97, skinTempDevC: 0, respRateBpm: 15.1))
        let canonical = 58.1

        // After first paint, off the canonical resolver: the row's raw Strain is not used.
        let resolved = HeadsUpDayContext.resolve(days: days, snapshot: nil, canonicalStrain: { _ in canonical },
                                                 logicalKey: today, localKey: today)
        XCTAssertEqual(resolved.day, today)
        XCTAssertEqual(resolved.strain, canonical)
        XCTAssertEqual(HeadsUpPresentation.contextStrain(resolved.strain),
                       String(format: "%.1f", StrainScale.displayValue(fromStored: canonical)))
        XCTAssertEqual(resolved.recovery, 71)

        // While Today is still painting from its saved snapshot, the page follows the snapshot, not the row.
        let snapshot = firstPaint(day: today, sleepMinutes: 406.8, strain: 58.1, recovery: 64)
        let painting = HeadsUpDayContext.resolve(days: days, snapshot: snapshot, canonicalStrain: { _ in 99 },
                                                 logicalKey: today, localKey: today)
        XCTAssertEqual(painting.strain, 58.1)
        XCTAssertEqual(painting.recovery, 64)
        XCTAssertEqual(painting.sleepMinutes, 406.8)
    }

    func testElsewhereTodaySleepUsesTodaysOwnFormatting() {
        // 406.8 minutes is 6h 46m on Today's tile (it drops the fraction); rounding up to 6h 47m disagreed with it.
        XCTAssertEqual(HeadsUpPresentation.contextSleep(406.8), TodayView.sleepDurationText(minutes: 406.8))
        XCTAssertEqual(HeadsUpPresentation.contextSleep(406.8), "6h 46m")
        XCTAssertEqual(HeadsUpPresentation.contextSleep(nil), "—")
        XCTAssertEqual(HeadsUpPresentation.contextStrain(nil), "—")
        XCTAssertEqual(HeadsUpPresentation.contextRecovery(70.6), "71%")
    }

    func testStrainRejectedByTodayStaysEmptyHere() {
        // Yesterday's snapshot Strain must not become today's: Today shows nothing, and so does this page.
        let yesterday = key(39), today = key(40)
        let old = firstPaint(day: yesterday, sleepMinutes: 400, strain: 64, recovery: 60)
        let context = HeadsUpDayContext.resolve(days: history(count: 41), snapshot: old,
                                                canonicalStrain: { _ in 64 }, logicalKey: today, localKey: today)
        XCTAssertNil(context.strain)
    }

    func testHistoryEndsOnTodayOnlyWhenItIs() {
        let now = Date()
        XCTAssertEqual(HeadsUpPresentation.dayLabel(Repository.localDayKey(now), now: now), "Today")
        let older = Repository.localDayKey(now.addingTimeInterval(-3 * 86_400))
        XCTAssertNotEqual(HeadsUpPresentation.dayLabel(older, now: now), "Today",
                          "A history that stops on an older night shows that night's date")
        XCTAssertFalse(HeadsUpPresentation.dayLabel(older, now: now).isEmpty)
    }
}
