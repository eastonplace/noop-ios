import Foundation
import XCTest
import NoopPhase34Core
import StrandDesign
import WhoopProtocol
import WhoopStore
@testable import NOOP

/// Root-cause fixes for the Home Screen widgets that went stale while Recovery and Sleep stayed fresh
/// (HRV, Resting HR, Steps, Stress). Each section is the regression test of one fix.
@MainActor
final class WidgetStalenessTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "noop.widget-staleness.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func install(contextId: String) throws -> VerifiedSinkToken {
        let epoch = try XCTUnwrap(ActiveVerifiedSinkEpochStore.beginTransition(defaults: defaults))
        return try XCTUnwrap(ActiveVerifiedSinkEpochStore.activate(
            contextId: contextId, epoch: epoch, defaults: defaults))
    }

    // MARK: - M4: HRV is the nightly RMSSD Today shows (daily_metrics.avgHrv)

    private func night(_ day: String, hrv: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: hrv,
                    recovery: nil, strain: nil, exerciseCount: nil)
    }

    /// The strap pipeline writes HRV to `daily_metrics.avgHrv` and never to the `hrv` metric series, which only
    /// file importers fill. The widget read the series, so it froze on an old import (or showed a dash).
    func testHRVEnrichmentReadsTheDailyAvgHrvTodayShows() async throws {
        let store = try await WhoopStore.inMemory()
        let anchor = try CivilDay(key: "2026-08-08")
        // Today's strap night, computed under the strap's "-noop" namespace.
        try await store.upsertDailyMetrics([night("2026-08-08", hrv: 58)], deviceId: "strap-noop")
        // An old file import sits in the metric series, twenty days back.
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-07-19", key: "hrv", value: 44),
        ], deviceId: "strap")
        // Apple's HRV is SDNN, a different quantity (DL-11); it is not a source of the namespace.
        try await store.upsertDailyMetrics([night("2026-08-08", hrv: 33)], deviceId: "apple-health")

        let series = try await WidgetSnapshot.verifiedHRVSeries(
            store: store, sourceIds: ["strap", "strap-noop"], anchorDay: anchor)

        XCTAssertEqual(series.map(\.day), ["2026-08-08"])
        XCTAssertEqual(WidgetSnapshot.widgetHRVProjection(from: series).current, 58)
    }

    func testHRVEnrichmentIsEmptyWhenNoDailyHrvExists() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertMetricSeries([
            MetricPoint(day: "2026-08-07", key: "hrv", value: 44),
        ], deviceId: "strap")
        let series = try await WidgetSnapshot.verifiedHRVSeries(
            store: store, sourceIds: ["strap", "strap-noop"], anchorDay: CivilDay(key: "2026-08-08"))
        XCTAssertTrue(series.isEmpty)
        XCTAssertNil(WidgetSnapshot.widgetHRVProjection(from: series).current)
    }

    /// Imported WHOOP beats the strap's computed night field by field, exactly as `Repository.mergeDaily`
    /// resolves Today's row; a night the import lacks is filled from the computed row.
    func testHRVEnrichmentFollowsTheTodayMergePrecedencePerDay() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDailyMetrics([
            night("2026-08-07", hrv: 70), night("2026-08-08", hrv: nil),
        ], deviceId: "strap")
        try await store.upsertDailyMetrics([
            night("2026-08-07", hrv: 41), night("2026-08-08", hrv: 62),
        ], deviceId: "strap-noop")

        let series = try await WidgetSnapshot.verifiedHRVSeries(
            store: store, sourceIds: ["strap", "strap-noop"], anchorDay: CivilDay(key: "2026-08-08"))

        XCTAssertEqual(series.map(\.day), ["2026-08-07", "2026-08-08"])
        XCTAssertEqual(series.map(\.value), [70, 62])
    }

    /// Until tonight's sleep is scored the anchor day has no HRV. Today carries the last night for two days
    /// and then relabels it; the widget has no label, so it uses the same window as a hard limit.
    func testHRVScalarCarriesThePriorNightOnlyInsideTodaysWindow() throws {
        let anchor = try CivilDay(key: "2026-08-08")
        func current(_ days: [(String, Double)]) -> Int? {
            WidgetSnapshot.widgetHRVProjection(
                from: days.map { (day: $0.0, value: $0.1) }, anchorDay: anchor).current
        }
        XCTAssertEqual(current([("2026-08-07", 61), ("2026-08-08", 64)]), 64,
                       "today's own night wins")
        XCTAssertEqual(current([("2026-08-07", 61)]), 61, "last night stands in until today is scored")
        XCTAssertEqual(current([("2026-08-06", 60)]), 60, "two nights back is still inside Today's window")
        XCTAssertNil(current([("2026-08-05", 60)]), "three nights back is a stale value, never today's")
        XCTAssertNil(current([("2026-07-19", 44)]))
        // The sparkline keeps the history either way.
        let spark = WidgetSnapshot.widgetHRVProjection(
            from: [(day: "2026-07-19", value: 44), (day: "2026-08-07", value: 61)], anchorDay: anchor).sparkline
        XCTAssertEqual(spark, [44, 61])
    }

    func testCarryWindowMatchesTodaysFreshnessCap() {
        XCTAssertEqual(CarriedVitalWindow.maximumAgeDays, TodayView.carryFreshnessDays)
        XCTAssertTrue(CarriedVitalWindow.permits(day: "2026-08-08", anchorDay: "2026-08-08"))
        XCTAssertTrue(CarriedVitalWindow.permits(day: "2026-08-06", anchorDay: "2026-08-08"))
        XCTAssertFalse(CarriedVitalWindow.permits(day: "2026-08-05", anchorDay: "2026-08-08"))
        XCTAssertFalse(CarriedVitalWindow.permits(day: "2026-08-09", anchorDay: "2026-08-08"), "never a future day")
        XCTAssertFalse(CarriedVitalWindow.permits(day: "not-a-day", anchorDay: "2026-08-08"))
        // Across a month and a year boundary.
        XCTAssertTrue(CarriedVitalWindow.permits(day: "2025-12-31", anchorDay: "2026-01-02"))
        XCTAssertFalse(CarriedVitalWindow.permits(day: "2025-12-30", anchorDay: "2026-01-02"))
    }

    // MARK: - M3: a core re-commit must not wipe the HRV and Stress enrichment

    private func core(_ context: String, generation: Int64, bpm: Int? = nil) -> WidgetSnapshot {
        WidgetSnapshot(recovery: 71, bpm: bpm, batteryPct: 80, bonded: true,
                       updated: Date(timeIntervalSince1970: 1_800_000_000),
                       effort: 8.4, rest: 77, restingHr: 52, steps: 6_000,
                       verifiedContextId: context, verifiedProjectionGeneration: generation)
    }

    private func enriched(_ snapshot: WidgetSnapshot) -> WidgetSnapshot {
        var value = snapshot
        value.hrv = 61
        value.hrvSparkline = [58, 60, 61]
        value.hourlyStress = (0..<24).map { $0 < 12 ? Double($0 % 3) : nil }
        value.stressSummary = "Moderate"
        return value
    }

    private func envelope(_ token: VerifiedSinkToken, generation: Int64,
                          snapshot: WidgetSnapshot) throws -> VerifiedWidgetEnvelope {
        try VerifiedWidgetEnvelope(epoch: token.epoch, contextId: token.contextId,
                                   generation: generation, snapshot: snapshot)
    }

    /// The foreground publish, then the background publish of the same generation, is the usual order. The
    /// second one used to replace the enriched envelope with a bare core, and the enrichment TTL kept it bare.
    func testACoreRecommitOfTheSameGenerationKeepsTheEnrichment() throws {
        let token = try install(contextId: "ctx")
        let day = try CivilDay(key: "2026-08-08")
        XCTAssertEqual(VerifiedWidgetEnvelopeStore.commit(
            token: token, generation: 5, snapshot: core("ctx", generation: 5), defaults: defaults), .published)
        XCTAssertEqual(VerifiedWidgetEnvelopeStore.commit(
            token: token, generation: 5, snapshot: enriched(core("ctx", generation: 5)), defaults: defaults),
                       .published)

        // Without the carry, the recommit loses the enrichment.
        let bare = core("ctx", generation: 5, bpm: 64)
        XCTAssertNil(bare.hrv)
        XCTAssertNil(bare.hourlyStress)

        let carried = WidgetCorePublication.carryingEnrichment(
            into: bare,
            from: VerifiedWidgetEnvelopeStore.rawActiveEnvelope(defaults: defaults),
            token: token, generation: 5, logicalDay: day, olderGenerationDay: nil)
        XCTAssertEqual(VerifiedWidgetEnvelopeStore.commit(
            token: token, generation: 5, snapshot: carried, defaults: defaults), .published)

        let shown = try XCTUnwrap(VerifiedWidgetEnvelopeStore.rawActiveEnvelope(defaults: defaults)).snapshot
        XCTAssertEqual(shown.bpm, 64, "the new core's own fields still land")
        XCTAssertEqual(shown.hrv, 61)
        XCTAssertEqual(shown.hrvSparkline, [58, 60, 61])
        XCTAssertEqual(shown.hourlyStress?.count, 24)
        XCTAssertEqual(shown.stressSummary, "Moderate")
    }

    /// With the enrichment carried, a repeat of the same core is identical content, so it writes nothing.
    func testRepeatingTheSameCoreAfterEnrichmentIsAlreadyCurrent() throws {
        let token = try install(contextId: "ctx")
        let day = try CivilDay(key: "2026-08-08")
        XCTAssertEqual(VerifiedWidgetEnvelopeStore.commit(
            token: token, generation: 5, snapshot: enriched(core("ctx", generation: 5)), defaults: defaults),
                       .published)
        let carried = WidgetCorePublication.carryingEnrichment(
            into: core("ctx", generation: 5),
            from: VerifiedWidgetEnvelopeStore.rawActiveEnvelope(defaults: defaults),
            token: token, generation: 5, logicalDay: day, olderGenerationDay: nil)
        XCTAssertEqual(VerifiedWidgetEnvelopeStore.commit(
            token: token, generation: 5, snapshot: carried, defaults: defaults), .alreadyCurrent)
    }

    /// Background passes mint a new generation each time. The new core carries the same day's enrichment, so
    /// Stress and HRV do not blank in the gap before (or in place of) a background enrichment.
    func testANewerGenerationOfTheSameDayCarriesTheEnrichment() throws {
        let token = try install(contextId: "ctx")
        let day = try CivilDay(key: "2026-08-08")
        let existing = try envelope(token, generation: 5, snapshot: enriched(core("ctx", generation: 5)))

        let carried = WidgetCorePublication.carryingEnrichment(
            into: core("ctx", generation: 6), from: existing, token: token, generation: 6,
            logicalDay: day, olderGenerationDay: (generation: 5, day: day))
        XCTAssertEqual(carried.hrv, 61)
        XCTAssertEqual(carried.hrvSparkline, [58, 60, 61])
        XCTAssertEqual(carried.hourlyStress?.count, 24)
        XCTAssertEqual(carried.stressSummary, "Moderate")
        XCTAssertEqual(carried.verifiedProjectionGeneration, 6, "the headline is the new generation's")
    }

    func testANewerGenerationNeverCarriesAnotherDaysEnrichment() throws {
        let token = try install(contextId: "ctx")
        let yesterday = try CivilDay(key: "2026-08-07")
        let today = try CivilDay(key: "2026-08-08")
        let existing = try envelope(token, generation: 5, snapshot: enriched(core("ctx", generation: 5)))

        let crossDay = WidgetCorePublication.carryingEnrichment(
            into: core("ctx", generation: 6), from: existing, token: token, generation: 6,
            logicalDay: today, olderGenerationDay: (generation: 5, day: yesterday))
        XCTAssertNil(crossDay.hrv)
        XCTAssertNil(crossDay.hrvSparkline)
        XCTAssertNil(crossDay.hourlyStress)
        XCTAssertNil(crossDay.stressSummary)
        // The day of the replaced generation is unknown, or belongs to a different generation: carry nothing.
        for older in [nil, (generation: Int64(4), day: today)] as [(generation: Int64, day: CivilDay)?] {
            let carried = WidgetCorePublication.carryingEnrichment(
                into: core("ctx", generation: 6), from: existing, token: token, generation: 6,
                logicalDay: today, olderGenerationDay: older)
            XCTAssertNil(carried.hrv)
            XCTAssertNil(carried.hourlyStress)
        }
    }

    func testNothingCarriesAcrossEpochsContextsOrDownwardGenerations() throws {
        let token = try install(contextId: "ctx")
        let day = try CivilDay(key: "2026-08-08")
        let existing = try envelope(token, generation: 7, snapshot: enriched(core("ctx", generation: 7)))

        // A generation below the stored one is superseded by the commit anyway; it must not borrow from it.
        let downward = WidgetCorePublication.carryingEnrichment(
            into: core("ctx", generation: 6), from: existing, token: token, generation: 6,
            logicalDay: day, olderGenerationDay: (generation: 7, day: day))
        XCTAssertNil(downward.hrv)

        let otherEpoch = VerifiedSinkToken(epoch: token.epoch + 1, contextId: "ctx")
        let crossEpoch = WidgetCorePublication.carryingEnrichment(
            into: core("ctx", generation: 7), from: existing, token: otherEpoch, generation: 7,
            logicalDay: day, olderGenerationDay: nil)
        XCTAssertNil(crossEpoch.hrv)

        let otherContext = VerifiedSinkToken(epoch: token.epoch, contextId: "other")
        let crossContext = WidgetCorePublication.carryingEnrichment(
            into: core("other", generation: 7), from: existing, token: otherContext, generation: 7,
            logicalDay: day, olderGenerationDay: nil)
        XCTAssertNil(crossContext.hourlyStress)

        let none = WidgetCorePublication.carryingEnrichment(
            into: core("ctx", generation: 7), from: nil, token: token, generation: 7,
            logicalDay: day, olderGenerationDay: nil)
        XCTAssertNil(none.hrv)
    }

    /// The core is the source of truth for what it already has; the carry only fills what is missing.
    func testTheCarryNeverOverwritesAValueTheCoreHas() throws {
        let token = try install(contextId: "ctx")
        let day = try CivilDay(key: "2026-08-08")
        let existing = try envelope(token, generation: 5, snapshot: enriched(core("ctx", generation: 5)))
        var fresh = core("ctx", generation: 5)
        fresh.hrv = 70
        let carried = WidgetCorePublication.carryingEnrichment(
            into: fresh, from: existing, token: token, generation: 5, logicalDay: day, olderGenerationDay: nil)
        XCTAssertEqual(carried.hrv, 70)
        XCTAssertEqual(carried.hourlyStress?.count, 24)
    }

    // MARK: - M5: the widget shows the Steps figure Today shows

    private func bundle(
        day: String, steps: Int?, generation: Int64 = 4, strain: Double? = nil, recovery: Double? = nil
    ) throws -> VerifiedExternalProjectionBundle {
        let civil = try CivilDay(key: day)
        var metrics: [HealthMetricKind: VerifiedHealthMetric] = [:]
        for (kind, value) in [(HealthMetricKind.strain, strain), (.recovery, recovery)] {
            guard let value else { continue }
            metrics[kind] = try VerifiedHealthMetric(
                kind: kind, value: value, metricDay: civil, sourceId: "my-whoop-noop",
                algorithmVersion: "v1", generation: generation, freshness: .fresh)
        }
        let projection = try VerifiedHealthProjection(
            contextId: "ctx", deviceId: "my-whoop", generation: generation, logicalDay: civil, metrics: metrics)
        let core = try VerifiedWidgetCorePayload(
            contextId: "ctx", projectionGeneration: generation, logicalDay: civil, restingHR: 52,
            sleepMinutes: 420, steps: steps, calories: nil, recoveryDelta: nil,
            recordedTimeZoneIdentifier: "America/New_York", enrichmentSourceIds: ["my-whoop", "my-whoop-noop"])
        return try VerifiedExternalProjectionBundle(projection: projection, widgetCore: core)
    }

    private func appleDay(_ day: String, steps: Int?) -> AppleDaily {
        AppleDaily(day: day, steps: steps, activeKcal: nil, basalKcal: nil, vo2max: nil,
                   avgHr: nil, maxHr: nil, walkingHr: nil, weightKg: nil)
    }

    func testTodayStepsPrefersAMeasuredCountOverTheEstimate() {
        let strap = TodaySteps(daily: 5_000, apple: 8_000, estimate: 7_000)
        XCTAssertEqual(strap.value, 5_000, "the strap's own total wins, as on Today")
        XCTAssertEqual(strap.recorded, 5_000)
        XCTAssertFalse(strap.isEstimate)

        let phone = TodaySteps(daily: nil, apple: 8_421, estimate: 7_000)
        XCTAssertEqual(phone.value, 8_421)
        XCTAssertFalse(phone.isEstimate)

        let estimated = TodaySteps(daily: nil, apple: nil, estimate: 6_500)
        XCTAssertEqual(estimated.value, 6_500)
        XCTAssertTrue(estimated.isEstimate)
        XCTAssertNil(estimated.recorded)

        let none = TodaySteps(daily: nil, apple: nil, estimate: nil)
        XCTAssertNil(none.value)
        XCTAssertFalse(none.isEstimate)
    }

    func testTheCoreKeepsItsOwnStepsUnlessTodayResolvesAnother() throws {
        let ny = newYork()
        let now = at(ny, 8, 15)
        let strapOnly = try bundle(day: "2026-08-08", steps: 3_000)
        XCTAssertEqual(WidgetCorePublication.makeCoreSnapshot(
            bundle: strapOnly, bpm: nil, batteryPct: nil, bonded: false, now: now, calendar: ny).steps, 3_000)
        XCTAssertEqual(WidgetCorePublication.makeCoreSnapshot(
            bundle: strapOnly, bpm: nil, batteryPct: nil, bonded: false, now: now, calendar: ny,
            steps: 8_421).steps, 8_421)

        let noStrapSteps = try bundle(day: "2026-08-08", steps: nil)
        XCTAssertNil(WidgetCorePublication.makeCoreSnapshot(
            bundle: noStrapSteps, bpm: nil, batteryPct: nil, bonded: false, now: now, calendar: ny).steps)
    }

    /// A phone-only or WHOOP 4.0 day has no strap total. Today fills it from Apple Health (or the estimate);
    /// the widget read the strap only, and showed a dash.
    func testWidgetStepsFollowTodaysFallbackToAppleHealthAndTheEstimate() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        let ny = newYork()
        let now = at(ny, 8, 15)
        let today = "2026-08-08"
        let yesterday = "2026-08-07"

        // Nothing but an Apple row for another day: no number, never yesterday's.
        try await store.upsertAppleDaily([appleDay(yesterday, steps: 9_999)], deviceId: Repository.appleHealthSource)
        let noCount = await WidgetSnapshot.todaySteps(
            repository: repository, bundle: try bundle(day: today, steps: nil), now: now, calendar: ny)
        XCTAssertNil(noCount)

        // The day's phone count fills the missing strap total.
        try await store.upsertAppleDaily([appleDay(today, steps: 8_421)], deviceId: Repository.appleHealthSource)
        let phone = await WidgetSnapshot.todaySteps(
            repository: repository, bundle: try bundle(day: today, steps: nil), now: now, calendar: ny)
        XCTAssertEqual(phone, 8_421)

        // A strap total outranks the phone, exactly as the Today tile.
        let strap = await WidgetSnapshot.todaySteps(
            repository: repository, bundle: try bundle(day: today, steps: 3_000), now: now, calendar: ny)
        XCTAssertEqual(strap, 3_000)
    }

    func testWidgetStepsUseTheEstimateOnlyWhenNothingWasMeasured() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        let ny = newYork()
        let now = at(ny, 8, 15)
        let today = "2026-08-08"
        try await store.upsertMetricSeries(
            [MetricPoint(day: today, key: "steps_est", value: 6_499.6)],
            deviceId: Repository.whoopSource + "-noop")

        let estimated = await WidgetSnapshot.todaySteps(
            repository: repository, bundle: try bundle(day: today, steps: nil), now: now, calendar: ny)
        XCTAssertEqual(estimated, 6_500, "rounded the way Today rounds the estimate")

        try await store.upsertAppleDaily([appleDay(today, steps: 8_421)], deviceId: Repository.appleHealthSource)
        let measured = await WidgetSnapshot.todaySteps(
            repository: repository, bundle: try bundle(day: today, steps: nil), now: now, calendar: ny)
        XCTAssertEqual(measured, 8_421, "a measured phone count beats the estimate")
    }

    // MARK: - M6: the Stress widget's strip is gated on the day, not on the last sync

    private func newYork() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func at(_ calendar: Calendar, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute))!
    }

    /// An hour with no strap sync used to read "No recent data" although the strip's hours were still true.
    func testTheStripSurvivesHoursWithoutASyncWithinTheSameDay() {
        let calendar = newYork()
        let updated = at(calendar, 8, 9, 5)
        XCTAssertTrue(WidgetStressFreshness.isCurrent(updated: updated, now: at(calendar, 8, 9, 5), calendar: calendar))
        XCTAssertTrue(WidgetStressFreshness.isCurrent(updated: updated, now: at(calendar, 8, 10, 30), calendar: calendar),
                      "an hour and a half later")
        XCTAssertTrue(WidgetStressFreshness.isCurrent(updated: updated, now: at(calendar, 8, 21, 0), calendar: calendar),
                      "the evening of the same day")
    }

    /// The strip is one logical day's hours; yesterday's must never read as today's.
    func testTheStripIsHiddenOnceTheLogicalDayHasRolled() {
        let calendar = newYork()
        let updated = at(calendar, 8, 23, 30)
        XCTAssertFalse(WidgetStressFreshness.isCurrent(updated: updated, now: at(calendar, 9, 4, 0), calendar: calendar))
        XCTAssertFalse(WidgetStressFreshness.isCurrent(updated: updated, now: at(calendar, 9, 8, 0), calendar: calendar))
    }

    /// Between midnight and 04:00 Today is still the evening's day, so its strip stays: the gate compared
    /// calendar days and hid it from 00:00.
    func testTheStripStaysVisibleBetweenMidnightAndTheRollover() {
        let calendar = newYork()
        let updated = at(calendar, 8, 23, 30)
        XCTAssertTrue(WidgetStressFreshness.isCurrent(updated: updated, now: at(calendar, 9, 0, 15), calendar: calendar))
        XCTAssertTrue(WidgetStressFreshness.isCurrent(updated: updated, now: at(calendar, 9, 3, 59), calendar: calendar))
    }

    /// A pass at 02:30 describes the day before: at 10:00 its strip is yesterday's, though `updated` is on
    /// today's calendar date.
    func testAStripCommittedAfterMidnightBelongsToTheDayBefore() {
        let calendar = newYork()
        let updated = at(calendar, 9, 2, 30)
        XCTAssertTrue(WidgetStressFreshness.isCurrent(updated: updated, now: at(calendar, 9, 3, 0), calendar: calendar))
        XCTAssertFalse(WidgetStressFreshness.isCurrent(updated: updated, now: at(calendar, 9, 10, 0), calendar: calendar))
    }

    /// The rollover is the 04:00 wall clock on both sides of a DST change, not 04:00 of elapsed time.
    func testTheStripGateFollowsTheWallClockAcrossDaylightSaving() {
        let calendar = newYork()
        func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
        }
        // Spring forward, Mar 8: 02:00 does not exist, so 23:30 to 03:30 is only three elapsed hours.
        let springUpdated = date(3, 7, 23, 30)
        XCTAssertTrue(WidgetStressFreshness.isCurrent(updated: springUpdated, now: date(3, 8, 3, 59), calendar: calendar))
        XCTAssertFalse(WidgetStressFreshness.isCurrent(updated: springUpdated, now: date(3, 8, 4, 0), calendar: calendar))
        // Fall back, Nov 1: 01:00 to 02:00 happens twice, so 04:00 is five elapsed hours after 23:30.
        let fallUpdated = date(10, 31, 23, 30)
        XCTAssertTrue(WidgetStressFreshness.isCurrent(updated: fallUpdated, now: date(11, 1, 3, 59), calendar: calendar))
        XCTAssertFalse(WidgetStressFreshness.isCurrent(updated: fallUpdated, now: date(11, 1, 4, 0), calendar: calendar))
    }

    /// The extension cannot reach `Repository`, so it has its own copy of the day. Pin it to the app's across
    /// zones and across the DST changes of the zones that have them.
    func testTheSharedLogicalDayIsTheRepositorysEverywhere() {
        XCTAssertEqual(WidgetLogicalDay.rolloverHour, Repository.logicalDayRolloverHour)
        let starts: [(zone: String, start: TimeInterval)] = [
            ("America/New_York", 1_772_841_600),   // 2026-03-07 00:00Z, spring forward on the 8th
            ("America/New_York", 1_793_491_200),   // 2026-11-01 00:00Z, fall back that day
            ("Pacific/Auckland", 1_790_380_800),   // 2026-09-26 00:00Z, spring forward on the 27th
            ("Asia/Kolkata", 1_790_380_800),
            ("UTC", 1_790_380_800),
        ]
        for (zone, start) in starts {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            for step in 0..<(3 * 72) {
                let instant = Date(timeIntervalSince1970: start + TimeInterval(step) * 1_200)
                XCTAssertEqual(WidgetLogicalDay.key(of: instant, calendar: calendar),
                               Repository.logicalDayKey(instant, calendar: calendar),
                               "\(zone) at \(instant)")
            }
        }
    }

    // MARK: - M8: Resting HR carries the last valid night like Recovery and Sleep

    private func row(_ source: String, _ day: String, rhr: Int?, priority: Int = 0) -> StoredSourcedDailyMetric {
        StoredSourcedDailyMetric(
            sourceId: source, sourcePriority: priority,
            metric: DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                                lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: nil,
                                recovery: nil, strain: nil, exerciseCount: nil))
    }

    private func carriedRHR(stored: Int? = nil, _ rows: [StoredSourcedDailyMetric]) -> Int? {
        RepositoryPostAnalysisSnapshotBuilder.widgetRestingHR(
            stored: stored, displayDay: "2026-08-08", dailyRows: rows,
            importedSourceIds: ["strap"], computedSourceIds: ["strap-noop"], appleSourceId: "apple-health")
    }

    /// Today's Resting HR is missing until tonight's sleep is scored. Recovery and Sleep show last night's in
    /// the meantime; Resting HR showed a dash.
    func testRestingHRCarriesLastNightUntilTodayIsScored() {
        XCTAssertEqual(carriedRHR([
            row("strap-noop", "2026-08-07", rhr: 52),
            row("strap-noop", "2026-08-08", rhr: nil),
        ]), 52)
        XCTAssertEqual(carriedRHR([row("strap-noop", "2026-08-07", rhr: 52)]), 52,
                       "the display day need not have a row at all")
    }

    func testRestingHRPrefersTodaysOwnValueOverACarry() {
        XCTAssertEqual(carriedRHR(stored: 49, [row("strap-noop", "2026-08-07", rhr: 52)]), 49)
    }

    /// A value from another day is never presented as today's once Today itself would stop calling it "Last night".
    func testRestingHRNeverCarriesAStaleNight() {
        XCTAssertEqual(carriedRHR([row("strap-noop", "2026-08-06", rhr: 54)]), 54, "two nights back: still carried")
        XCTAssertNil(carriedRHR([row("strap-noop", "2026-08-05", rhr: 54)]), "three nights back: stale")
        XCTAssertNil(carriedRHR([
            row("strap-noop", "2026-08-07", rhr: nil),
            row("strap-noop", "2026-08-06", rhr: nil),
            row("strap-noop", "2026-08-05", rhr: 54),
        ]))
    }

    func testRestingHRNeverTakesAFutureDayOrAnImplausibleValue() {
        XCTAssertNil(carriedRHR([row("strap-noop", "2026-08-09", rhr: 55)]), "tomorrow's row is not a carry")
        XCTAssertNil(carriedRHR([row("strap-noop", "2026-08-07", rhr: 19)]))
        XCTAssertEqual(carriedRHR([
            row("strap-noop", "2026-08-07", rhr: 301),
            row("strap-noop", "2026-08-06", rhr: 53),
        ]), 53, "an implausible night is skipped for the next valid one inside the window")
    }

    /// The carried night resolves per field the way the day's row does: the import first, the computed night
    /// filling what the import lacks; Apple Health only when the read carried it.
    func testRestingHRCarryFollowsTheDailyMergePrecedence() {
        XCTAssertEqual(carriedRHR([
            row("strap", "2026-08-07", rhr: 50, priority: 2),
            row("strap-noop", "2026-08-07", rhr: 53, priority: 1),
        ]), 50)
        XCTAssertEqual(carriedRHR([
            row("strap", "2026-08-07", rhr: nil, priority: 2),
            row("strap-noop", "2026-08-07", rhr: 53, priority: 1),
        ]), 53)
        XCTAssertEqual(carriedRHR([row("apple-health", "2026-08-07", rhr: 58, priority: 0)]), 58)
        XCTAssertNil(carriedRHR([row("somebody-else", "2026-08-07", rhr: 60)]), "outside the namespace")
    }

    // MARK: - Strain: the figure Today shows reaches the widget between strap passes

    private func overlay(_ token: VerifiedSinkToken, generation: Int64, storedStrain: Double?) -> WidgetLiveOverlay {
        WidgetLiveOverlay(epoch: token.epoch, contextId: token.contextId, generation: generation,
                          bpm: 61, batteryPct: 80, bonded: true, hrSparkline: nil,
                          storedStrain: storedStrain, updated: Date(timeIntervalSince1970: 1_800_000_100))
    }

    func testLiveStrainIsTakenOnlyForTheGenerationsOwnDay() throws {
        let day = try CivilDay(key: "2026-08-08")
        func resolved(_ day: String?, _ stored: Double) -> ResolvedStrain {
            ResolvedStrain(day: day, storedValue: stored, version: 2, origin: .liveDayV2, sourceId: "strap")
        }
        XCTAssertEqual(WidgetSnapshot.liveStoredStrain(resolved("2026-08-08", 40), day: day), 40)
        XCTAssertNil(WidgetSnapshot.liveStoredStrain(resolved("2026-08-07", 40), day: day), "another day's Strain")
        XCTAssertNil(WidgetSnapshot.liveStoredStrain(resolved(nil, 40), day: day))
        XCTAssertNil(WidgetSnapshot.liveStoredStrain(resolved("2026-08-08", .nan), day: day))
        XCTAssertNil(WidgetSnapshot.liveStoredStrain(nil, day: day))
    }

    func testTheWidgetShowsTheLiveStrainOfItsOwnGenerationOnly() throws {
        let token = try install(contextId: "ctx")
        let coreStrain = StrainScale.displayValue(fromStored: 30)
        var snapshot = core("ctx", generation: 5)
        snapshot.strain = coreStrain
        XCTAssertEqual(VerifiedWidgetEnvelopeStore.commit(
            token: token, generation: 5, snapshot: snapshot, defaults: defaults), .published)
        XCTAssertEqual(VerifiedWidgetEnvelopeStore.loadForDisplay(defaults: defaults)?.strain, coreStrain)

        // Today moved to 40 (stored scale) after the last strap pass: the widget shows it.
        XCTAssertTrue(ActiveVerifiedSinkEpochStore.commitLiveOverlayIfCurrent(
            token: token, generation: 5, defaults: defaults, overlay: overlay(token, generation: 5, storedStrain: 40)))
        XCTAssertEqual(VerifiedWidgetEnvelopeStore.loadForDisplay(defaults: defaults)?.strain,
                       StrainScale.displayValue(fromStored: 40))
        XCTAssertEqual(try XCTUnwrap(VerifiedWidgetEnvelopeStore.rawActiveEnvelope(defaults: defaults)).snapshot.strain,
                       coreStrain, "the verified core itself is never rewritten")

        // An overlay with no Strain leaves the core's.
        XCTAssertTrue(ActiveVerifiedSinkEpochStore.commitLiveOverlayIfCurrent(
            token: token, generation: 5, defaults: defaults, overlay: overlay(token, generation: 5, storedStrain: nil)))
        XCTAssertEqual(VerifiedWidgetEnvelopeStore.loadForDisplay(defaults: defaults)?.strain, coreStrain)

        // A new generation lands: the old overlay (and its Strain) no longer applies.
        XCTAssertTrue(ActiveVerifiedSinkEpochStore.commitLiveOverlayIfCurrent(
            token: token, generation: 5, defaults: defaults, overlay: overlay(token, generation: 5, storedStrain: 40)))
        var next = core("ctx", generation: 6)
        next.strain = StrainScale.displayValue(fromStored: 45)
        XCTAssertEqual(VerifiedWidgetEnvelopeStore.commit(
            token: token, generation: 6, snapshot: next, defaults: defaults), .published)
        XCTAssertEqual(VerifiedWidgetEnvelopeStore.loadForDisplay(defaults: defaults)?.strain,
                       StrainScale.displayValue(fromStored: 45))
    }

    /// The overlay gained one optional key. A payload written before it must decode, and so must the envelope
    /// and token shapes, which this change does not touch.
    func testPayloadsWrittenBeforeTheStrainFieldStillDecode() throws {
        let oldOverlay = Data("""
        {"epoch":3,"contextId":"ctx","generation":5,"bpm":61,"batteryPct":80,"bonded":true,\
        "hrSparkline":[60,62],"updated":800000000.5}
        """.utf8)
        let decoded = try JSONDecoder().decode(WidgetLiveOverlay.self, from: oldOverlay)
        XCTAssertNil(decoded.storedStrain)
        XCTAssertEqual(decoded.generation, 5)
        XCTAssertEqual(decoded.hrSparkline, [60, 62])

        let oldEnvelope = Data("""
        {"version":1,"epoch":3,"contextId":"ctx","generation":5,"snapshot":{"recovery":71,"bpm":58,\
        "batteryPct":80,"bonded":true,"updated":800000000.5,"verifiedContextId":"ctx",\
        "verifiedProjectionGeneration":5,"effort":8.4,"rest":77,"hrv":61,"restingHr":52,"recoveryDelta":3,\
        "sleepMinutes":430,"steps":6000,"calories":2100,"hourlyStress":[0.5,null,1.5],\
        "stressSummary":"Moderate","hrSparkline":[60],"hrvSparkline":[58,61]}}
        """.utf8)
        let envelope = try JSONDecoder().decode(VerifiedWidgetEnvelope.self, from: oldEnvelope)
        XCTAssertEqual(envelope.epoch, 3)
        XCTAssertEqual(envelope.snapshot.hrv, 61)
        XCTAssertEqual(envelope.snapshot.hourlyStress?.count, 3)

        let oldToken = Data(#"{"epoch":3,"contextId":"ctx"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ActiveVerifiedSinkEpochRecord.self, from: oldToken).epoch, 3)
        XCTAssertEqual(VerifiedWidgetEnvelopeStore.storageKey, "noop.widget.verified-envelope.v1")
        XCTAssertEqual(ActiveVerifiedSinkEpochStore.activeKey, "noop.external-sink.active-epoch.v1")
    }

    // MARK: - Wiring: what publish and publishLive hand to the pipeline

    private func projection(day: String, generation: Int64) throws -> VerifiedHealthProjection {
        try VerifiedHealthProjection(
            contextId: "ctx", deviceId: "my-whoop", generation: generation,
            logicalDay: CivilDay(key: day), metrics: [:])
    }

    private func delivery(
        steps: Int? = nil,
        older: (generation: Int64, day: CivilDay)? = nil
    ) -> WidgetCorePublication.CoreDelivery {
        WidgetCorePublication.CoreDelivery(
            bpm: 64, batteryPct: 81, bonded: true, steps: steps, olderGenerationDay: older)
    }

    /// `publish` hands the durable commit exactly these inputs. The envelope that comes out has Today's Steps
    /// in it (the strap's own count would otherwise stand) and the enrichment of the envelope it replaced.
    func testTheCoreCommitPutsTodaysStepsAndTheEarlierEnrichmentInTheEnvelope() throws {
        let token = try install(contextId: "ctx")
        XCTAssertEqual(VerifiedWidgetEnvelopeStore.commit(
            token: token, generation: 5, snapshot: enriched(core("ctx", generation: 5)), defaults: defaults),
                       .published)

        let committed = WidgetCorePublication.commitCore(
            bundle: try bundle(day: "2026-08-08", steps: 3_000, generation: 5),
            token: token, defaults: defaults, delivery: delivery(steps: 8_421), now: at(newYork(), 8, 15), calendar: newYork())
        XCTAssertEqual(committed.result, .published)

        let shown = try XCTUnwrap(VerifiedWidgetEnvelopeStore.rawActiveEnvelope(defaults: defaults)).snapshot
        XCTAssertEqual(shown, committed.snapshot)
        XCTAssertEqual(shown.steps, 8_421, "Today's figure, not the strap's own 3,000")
        XCTAssertEqual(shown.bpm, 64)
        XCTAssertEqual(shown.restingHr, 52, "the core's own values still land")
        XCTAssertEqual(shown.verifiedProjectionGeneration, 5)
        XCTAssertEqual(shown.hourlyStress?.count, 24, "the enrichment of the replaced envelope is carried")
        XCTAssertEqual(shown.stressSummary, "Moderate")
        XCTAssertEqual(shown.hrvSparkline, [58, 60, 61])
    }

    func testTheCoreCommitCarriesAcrossGenerationsOnlyWithTheReplacedGenerationsDay() throws {
        let token = try install(contextId: "ctx")
        let day = try CivilDay(key: "2026-08-08")
        XCTAssertEqual(VerifiedWidgetEnvelopeStore.commit(
            token: token, generation: 5, snapshot: enriched(core("ctx", generation: 5)), defaults: defaults),
                       .published)

        let committed = WidgetCorePublication.commitCore(
            bundle: try bundle(day: "2026-08-08", steps: nil, generation: 6),
            token: token, defaults: defaults,
            delivery: delivery(older: (generation: 5, day: day)), now: at(newYork(), 8, 15), calendar: newYork())
        XCTAssertEqual(committed.result, .published)
        XCTAssertEqual(committed.snapshot.verifiedProjectionGeneration, 6)
        XCTAssertEqual(committed.snapshot.hourlyStress?.count, 24)
        XCTAssertEqual(committed.snapshot.hrvSparkline, [58, 60, 61])

        // Without the replaced generation's day, nothing crosses.
        let bare = WidgetCorePublication.commitCore(
            bundle: try bundle(day: "2026-08-08", steps: nil, generation: 7),
            token: token, defaults: defaults, delivery: delivery(), now: at(newYork(), 8, 15), calendar: newYork())
        XCTAssertNil(bare.snapshot.hourlyStress)
        XCTAssertNil(bare.snapshot.hrvSparkline)
    }

    func testTheCoreCommitIsSupersededByANewerGenerationAndNeverBorrowsFromIt() throws {
        let token = try install(contextId: "ctx")
        XCTAssertEqual(VerifiedWidgetEnvelopeStore.commit(
            token: token, generation: 9, snapshot: enriched(core("ctx", generation: 9)), defaults: defaults),
                       .published)
        let committed = WidgetCorePublication.commitCore(
            bundle: try bundle(day: "2026-08-08", steps: 3_000, generation: 8),
            token: token, defaults: defaults, delivery: delivery(steps: 8_421), now: at(newYork(), 8, 15), calendar: newYork())
        XCTAssertEqual(committed.result, .superseded)
        XCTAssertEqual(try XCTUnwrap(VerifiedWidgetEnvelopeStore.rawActiveEnvelope(defaults: defaults)).generation, 9)
    }

    private func resolved(_ day: String, stored: Double) -> ResolvedStrain {
        ResolvedStrain(day: day, storedValue: stored, version: 2, origin: .liveDayV2, sourceId: "strap")
    }

    /// `publishLive` hands the overlay Today's Strain for the generation's day, so the widget moves with Today
    /// between strap passes. The overlay it persists is what the display path lays over the verified core.
    func testTheLiveOverlayCarriesTodaysStrainAndTheDisplayPathShowsIt() throws {
        let token = try install(contextId: "ctx")
        var base = core("ctx", generation: 5)
        base.strain = StrainScale.displayValue(fromStored: 30)
        XCTAssertEqual(VerifiedWidgetEnvelopeStore.commit(
            token: token, generation: 5, snapshot: base, defaults: defaults), .published)
        var stale = base
        stale.strain = StrainScale.displayValue(fromStored: 35)

        let assembled = WidgetCorePublication.assembleLive(
            previous: stale, base: base, coreStrain: base.strain, token: token,
            verified: try projection(day: "2026-08-08", generation: 5),
            bpm: 61, batteryPct: 80.4, bonded: true, workoutSparkline: nil,
            todayStrain: { _ in self.resolved("2026-08-08", stored: 40) },
            now: at(newYork(), 8, 15), calendar: newYork())

        XCTAssertEqual(assembled.overlay.storedStrain, 40)
        XCTAssertEqual(assembled.overlay.epoch, token.epoch)
        XCTAssertEqual(assembled.overlay.contextId, "ctx")
        XCTAssertEqual(assembled.overlay.generation, 5)
        XCTAssertEqual(assembled.overlay.batteryPct, 80)
        XCTAssertEqual(assembled.next.strain, StrainScale.displayValue(fromStored: 40))
        XCTAssertEqual(assembled.next.bpm, 61)

        XCTAssertTrue(ActiveVerifiedSinkEpochStore.commitLiveOverlayIfCurrent(
            token: token, generation: 5, defaults: defaults, overlay: assembled.overlay))
        XCTAssertEqual(VerifiedWidgetEnvelopeStore.loadForDisplay(defaults: defaults)?.strain,
                       StrainScale.displayValue(fromStored: 40))
    }

    /// A Strain that is not the generation's day's leaves the core's own, and the gate snapshot is rebuilt from
    /// the core rather than from the previous tick.
    func testTheLiveOverlayTakesNoStrainFromAnotherDay() throws {
        let token = try install(contextId: "ctx")
        var base = core("ctx", generation: 5)
        base.strain = StrainScale.displayValue(fromStored: 30)
        var stale = base
        stale.strain = StrainScale.displayValue(fromStored: 35)

        for today in [resolved("2026-08-07", stored: 40), nil] as [ResolvedStrain?] {
            let assembled = WidgetCorePublication.assembleLive(
                previous: stale, base: base, coreStrain: base.strain, token: token,
                verified: try projection(day: "2026-08-08", generation: 5),
                bpm: 61, batteryPct: 80, bonded: true, workoutSparkline: [70, 72],
                todayStrain: { _ in today }, now: at(newYork(), 8, 15), calendar: newYork())
            XCTAssertNil(assembled.overlay.storedStrain)
            XCTAssertEqual(assembled.next.strain, base.strain)
            XCTAssertEqual(assembled.overlay.hrSparkline, [70, 72])
        }
    }

    // MARK: - The day-behind rule: yesterday's day-scoped figures are never presented as today's

    func testACoreIsCurrentOnlyOnTheLogicalDayTodayIsOn() throws {
        let ny = newYork()
        let day = try CivilDay(key: "2026-08-08")
        XCTAssertTrue(WidgetCoreDay.isCurrent(day, now: at(ny, 8, 15), calendar: ny))
        XCTAssertTrue(WidgetCoreDay.isCurrent(day, now: at(ny, 9, 2, 30), calendar: ny),
                      "02:30 is still the day before: the rollover is 04:00")
        XCTAssertFalse(WidgetCoreDay.isCurrent(day, now: at(ny, 9, 4, 0), calendar: ny))
        XCTAssertFalse(WidgetCoreDay.isCurrent(day, now: at(ny, 9, 10), calendar: ny))
        XCTAssertFalse(WidgetCoreDay.isCurrent(day, now: at(ny, 7, 15), calendar: ny), "a core from the future")

        // Across a DST change: the day still rolls at 04:00 on the wall clock.
        let march = try CivilDay(key: "2026-03-07")
        func date(_ month: Int, _ d: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            ny.date(from: DateComponents(year: 2026, month: month, day: d, hour: hour, minute: minute))!
        }
        XCTAssertTrue(WidgetCoreDay.isCurrent(march, now: date(3, 8, 3, 30), calendar: ny))
        XCTAssertFalse(WidgetCoreDay.isCurrent(march, now: date(3, 8, 4, 0), calendar: ny))
        let october = try CivilDay(key: "2026-10-31")
        XCTAssertTrue(WidgetCoreDay.isCurrent(october, now: date(11, 1, 3, 59), calendar: ny))
        XCTAssertFalse(WidgetCoreDay.isCurrent(october, now: date(11, 1, 4, 0), calendar: ny))
    }

    /// The scenario of the review: generation 5 is Aug 8's and no strap pass has run since. Every re-commit of it
    /// after the rollover (activation, the 04:00 handler, a HealthKit drain) used to restamp Aug 8's strip,
    /// Steps and Strain as today's.
    func testAReCommitOnTheNextDayPresentsNoneOfYesterdaysDayFigures() throws {
        let ny = newYork()
        let token = try install(contextId: "ctx")
        var evening = enriched(core("ctx", generation: 5))
        evening.strain = StrainScale.displayValue(fromStored: 30)
        XCTAssertEqual(VerifiedWidgetEnvelopeStore.commit(
            token: token, generation: 5, snapshot: evening, defaults: defaults), .published)
        let aug8 = try bundle(day: "2026-08-08", steps: 3_000, generation: 5, strain: 30, recovery: 71)

        // 02:30 on the 9th is still Aug 8: the figures stand and the strip is carried.
        let night = WidgetCorePublication.commitCore(
            bundle: aug8, token: token, defaults: defaults, delivery: delivery(),
            now: at(ny, 9, 2, 30), calendar: ny)
        XCTAssertEqual(night.snapshot.steps, 3_000)
        XCTAssertEqual(night.snapshot.strain, StrainScale.displayValue(fromStored: 30))
        XCTAssertEqual(night.snapshot.hourlyStress?.count, 24)
        XCTAssertTrue(WidgetStressFreshness.isCurrent(updated: night.snapshot.updated, now: at(ny, 9, 3, 0), calendar: ny))
        XCTAssertFalse(WidgetStressFreshness.isCurrent(updated: night.snapshot.updated, now: at(ny, 9, 10), calendar: ny),
                       "and by 10:00 the extension does not draw a strip stamped 02:30")

        // 10:00 on the 9th: the same generation is behind. Nothing of Aug 8's is today's.
        let morning = WidgetCorePublication.commitCore(
            bundle: aug8, token: token, defaults: defaults, delivery: delivery(),
            now: at(ny, 9, 10), calendar: ny)
        XCTAssertEqual(morning.result, .published)
        XCTAssertNil(morning.snapshot.hourlyStress, "the strip is not carried onto a core that is behind")
        XCTAssertNil(morning.snapshot.stressSummary)
        XCTAssertNil(morning.snapshot.steps, "not the strap's count for yesterday")
        XCTAssertNil(morning.snapshot.strain, "not yesterday's Strain")
        XCTAssertEqual(morning.snapshot.recovery, 71, "the per-night figures still carry")
        XCTAssertEqual(morning.snapshot.restingHr, 52)
        XCTAssertEqual(morning.snapshot.hrvSparkline, [58, 60, 61])
        let shown = try XCTUnwrap(VerifiedWidgetEnvelopeStore.rawActiveEnvelope(defaults: defaults)).snapshot
        XCTAssertNil(shown.hourlyStress)

        // With Today's figures for the 9th resolved, those are what the core shows.
        let resolved = WidgetCorePublication.commitCore(
            bundle: aug8, token: token, defaults: defaults,
            delivery: WidgetCorePublication.CoreDelivery(
                bpm: 64, batteryPct: 81, bonded: true, steps: 640, currentDayStrain: 12, olderGenerationDay: nil),
            now: at(ny, 9, 10), calendar: ny)
        XCTAssertEqual(resolved.snapshot.steps, 640)
        XCTAssertEqual(resolved.snapshot.strain, StrainScale.displayValue(fromStored: 12))
        XCTAssertNil(resolved.snapshot.hourlyStress)
    }

    /// A newer generation of the day before is behind as well; the same-day carry rule cannot bring a strip over.
    func testANewerGenerationThatIsBehindCarriesNoStrip() throws {
        let ny = newYork()
        let token = try install(contextId: "ctx")
        let day = try CivilDay(key: "2026-08-08")
        XCTAssertEqual(VerifiedWidgetEnvelopeStore.commit(
            token: token, generation: 5, snapshot: enriched(core("ctx", generation: 5)), defaults: defaults),
                       .published)
        let committed = WidgetCorePublication.commitCore(
            bundle: try bundle(day: "2026-08-08", steps: nil, generation: 6),
            token: token, defaults: defaults, delivery: delivery(older: (generation: 5, day: day)),
            now: at(ny, 9, 10), calendar: ny)
        XCTAssertNil(committed.snapshot.hourlyStress)
        XCTAssertNil(committed.snapshot.stressSummary)
    }

    func testStressIsComputedOnlyForTheCurrentLogicalDay() async throws {
        let ny = newYork()
        let store = try await WhoopStore.inMemory()
        let start = Int(ny.startOfDay(for: at(ny, 8, 12)).timeIntervalSince1970)
        _ = try await store.insert(Streams(
            hr: (0..<400).map { HRSample(ts: start + 10 * 3_600 + $0, bpm: 70 + $0 % 5) }, rr: []),
                                   deviceId: "my-whoop")
        let aug8 = try bundle(day: "2026-08-08", steps: nil)

        let current = await WidgetSnapshot.enrichmentStress(
            store: store, bundle: aug8, now: at(ny, 8, 15), calendar: ny)
        XCTAssertEqual(current.hours?.count, 24, "today's own strip")
        let afterMidnight = await WidgetSnapshot.enrichmentStress(
            store: store, bundle: aug8, now: at(ny, 9, 2, 30), calendar: ny)
        XCTAssertEqual(afterMidnight.hours?.count, 24, "02:30 is still Aug 8")
        let behind = await WidgetSnapshot.enrichmentStress(
            store: store, bundle: aug8, now: at(ny, 9, 10), calendar: ny)
        XCTAssertNil(behind.hours, "yesterday's strip is not recomputed as today's")
        XCTAssertNil(behind.summary)
    }

    /// Today's Steps are the current logical day's. A core from yesterday adds neither its strap count nor
    /// Apple Health's total for yesterday.
    func testWidgetStepsAreAlwaysTheCurrentLogicalDaysCount() async throws {
        let ny = newYork()
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        try await store.upsertAppleDaily(
            [appleDay("2026-08-08", steps: 11_204)], deviceId: Repository.appleHealthSource)
        let aug8 = try bundle(day: "2026-08-08", steps: 3_000)

        // Behind, with nothing counted yet today: no number at all.
        let none = await WidgetSnapshot.todaySteps(
            repository: repository, bundle: aug8, now: at(ny, 9, 10), calendar: ny)
        XCTAssertNil(none)

        // Today's count from Apple Health, then the strap-less estimate.
        try await store.upsertAppleDaily(
            [appleDay("2026-08-09", steps: 640)], deviceId: Repository.appleHealthSource)
        let phone = await WidgetSnapshot.todaySteps(
            repository: repository, bundle: aug8, now: at(ny, 9, 10), calendar: ny)
        XCTAssertEqual(phone, 640)

        // At 02:30 the core is still the current logical day's, so its strap count stands.
        let night = await WidgetSnapshot.todaySteps(
            repository: repository, bundle: aug8, now: at(ny, 9, 2, 30), calendar: ny)
        XCTAssertEqual(night, 3_000)

        let estimateOnly = try await WhoopStore.inMemory()
        let estimating = Repository(deviceId: Repository.whoopSource)
        estimating.setStoreForTesting(estimateOnly)
        try await estimateOnly.upsertMetricSeries(
            [MetricPoint(day: "2026-08-08", key: "steps_est", value: 9_000),
             MetricPoint(day: "2026-08-09", key: "steps_est", value: 499.6)],
            deviceId: Repository.whoopSource + "-noop")
        let estimated = await WidgetSnapshot.todaySteps(
            repository: estimating, bundle: aug8, now: at(ny, 9, 10), calendar: ny)
        XCTAssertEqual(estimated, 500)
    }

    /// The overlay asks Today for the current logical day's Strain. A core that is behind has none of its own to
    /// show, so with no Strain for the new day the overlay carries none.
    func testTheLiveOverlayUsesTheCurrentLogicalDaysStrain() throws {
        let ny = newYork()
        let token = try install(contextId: "ctx")
        var base = core("ctx", generation: 5)
        base.strain = StrainScale.displayValue(fromStored: 30)
        var asked: [String] = []

        let today = WidgetCorePublication.assembleLive(
            previous: nil, base: base, coreStrain: base.strain, token: token,
            verified: try projection(day: "2026-08-08", generation: 5),
            bpm: 61, batteryPct: 80, bonded: true, workoutSparkline: nil,
            todayStrain: { asked.append($0); return self.resolved($0, stored: 22) },
            now: at(ny, 9, 10), calendar: ny)
        XCTAssertEqual(asked, ["2026-08-09"], "the generation is Aug 8's but Today is on the 9th")
        XCTAssertEqual(today.overlay.storedStrain, 22)
        XCTAssertEqual(today.next.strain, StrainScale.displayValue(fromStored: 22))

        let tomorrowOnly = WidgetCorePublication.assembleLive(
            previous: nil, base: base, coreStrain: base.strain, token: token,
            verified: try projection(day: "2026-08-08", generation: 5),
            bpm: 61, batteryPct: 80, bonded: true, workoutSparkline: nil,
            todayStrain: { _ in self.resolved("2026-08-08", stored: 40) },
            now: at(ny, 9, 10), calendar: ny)
        XCTAssertNil(tomorrowOnly.overlay.storedStrain, "yesterday's Strain is not the figure for today")
    }
}
