import Foundation
import XCTest
import NoopPhase34Core
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
}
