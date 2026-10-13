#if os(iOS)
import Foundation
import NoopPhase34Core
import WhoopStore

/// Whether a verified core describes the day Today is showing.
///
/// A generation is only replaced when a strap pass mints a newer one, so after the 04:00 rollover the newest core
/// can still be yesterday's, and it is re-committed (activation, the day-boundary handler, a HealthKit drain)
/// with a fresh timestamp. Its day-scoped figures (Strain, Steps, Calories, the Stress strip) are then yesterday's, and
/// the widget must not present them as today's: each is either resolved for the current logical day, exactly as
/// Today resolves it, or left out. The per-night figures (Recovery, Sleep, Resting HR, HRV) are not day-scoped;
/// they carry the last scored night inside `CarriedVitalWindow`, as Today does.
@MainActor
enum WidgetCoreDay {
    /// `yyyy-MM-dd` of the logical day Today is on at `now`.
    static func currentKey(now: Date, calendar: Calendar = .current) -> String {
        Repository.logicalDayKey(now, calendar: calendar)
    }

    /// True when the core's own day is the logical day at `now`.
    static func isCurrent(_ coreDay: CivilDay, now: Date, calendar: Calendar = .current) -> Bool {
        coreDay.key == currentKey(now: now, calendar: calendar)
    }

    /// The day the delivery-time reads of the per-night figures (HRV, Resting HR) are anchored on: the day Today's
    /// row is for. For a current core that is the day the generation describes, which is its logical day except
    /// when Today prefers the calendar day that already holds the night just banked (#304: a night that ends
    /// before 04:00), and then the projection's own metrics are dated that next day. For a core that is behind it
    /// is the current logical day, so Apple Health's figure for today is read and a night older than
    /// `CarriedVitalWindow` allows is not carried as today's.
    static func nightlyAnchor(
        bundle: VerifiedExternalProjectionBundle,
        now: Date,
        calendar: Calendar = .current
    ) -> CivilDay {
        let logical = bundle.widgetCore.logicalDay
        guard isCurrent(logical, now: now, calendar: calendar) else {
            return (try? CivilDay(key: currentKey(now: now, calendar: calendar))) ?? logical
        }
        guard let latest = bundle.projection.metrics.values.map(\.metricDay).max(),
              latest > logical,
              CarriedVitalWindow.ageDays(of: logical.key, relativeTo: latest.key) == 1 else { return logical }
        return latest
    }
}

/// O(1) durable Widget payload. History-series and stress enrichment are intentionally absent from this
/// helper and run only after the outbox caller has received its core acknowledgement.
@MainActor
enum WidgetCorePublication {
    /// What `publish` resolves, from the model and the store, before the durable commit. Plain values only, so
    /// everything after them (the snapshot, the carried enrichment, the envelope commit) is `commitCore`, which
    /// a test can drive against an isolated `UserDefaults`. Every field is required, with no default, so a
    /// delivery that stops supplying one does not compile.
    struct CoreDelivery {
        let bpm: Int?
        let batteryPct: Double?
        let bonded: Bool
        /// The Steps figure Today shows for the current logical day (`WidgetSnapshot.todaySteps`).
        let steps: Int?
        /// The stored-scale Strain Today shows for the current logical day. It stands in for the core's own
        /// Strain only when the core is from an earlier day.
        let currentDayStrain: Double?
        /// Last night's HRV as Today shows it (`WidgetSnapshot.todayHRV`).
        let hrv: Int?
        /// The Resting HR Today shows, with Apple Health's nights in it (`WidgetSnapshot.todayRestingHR`); nil
        /// keeps the core's own, which is the strap's nights only, while the core is the current day's.
        let restingHR: Int?
        /// The day of the generation the envelope being replaced holds, when that is an older generation.
        let olderGenerationDay: (generation: Int64, day: CivilDay)?
    }

    /// The durable core publication: build the core from the immutable bundle and the resolved delivery values,
    /// put the enrichment of the envelope being replaced back on it, and commit the envelope. It never reads
    /// history; HRV and stress enrichment run after the caller has its acknowledgement.
    static func commitCore(
        bundle: VerifiedExternalProjectionBundle,
        token: VerifiedSinkToken,
        defaults: UserDefaults,
        delivery: CoreDelivery,
        now: Date,
        calendar: Calendar = .current
    ) -> (snapshot: WidgetSnapshot, result: VerifiedProjectionGenerationWriteResult) {
        let generation = bundle.projection.generation
        let snapshot = carryingEnrichment(
            into: makeCoreSnapshot(
                bundle: bundle,
                bpm: delivery.bpm,
                batteryPct: delivery.batteryPct,
                bonded: delivery.bonded,
                now: now,
                calendar: calendar,
                steps: delivery.steps,
                currentDayStrain: delivery.currentDayStrain,
                hrv: delivery.hrv,
                restingHR: delivery.restingHR),
            from: VerifiedWidgetEnvelopeStore.rawActiveEnvelope(defaults: defaults),
            token: token,
            generation: generation,
            logicalDay: bundle.widgetCore.logicalDay,
            olderGenerationDay: delivery.olderGenerationDay,
            dayIsCurrent: WidgetCoreDay.isCurrent(bundle.widgetCore.logicalDay, now: now, calendar: calendar))
        let result = VerifiedWidgetEnvelopeStore.commit(
            token: token,
            generation: generation,
            snapshot: snapshot,
            defaults: defaults)
        return (snapshot, result)
    }

    /// The live lane's two outputs for one tick: the in-memory snapshot the publish gate compares, and the
    /// overlay that is persisted over the verified core. `coreStrain` is the verified core's own Strain
    /// (display scale), shown only while the core is the current logical day's. `todayStrain` is asked for the
    /// Strain Today resolves for a day: the current logical day, which is the generation's own day unless the
    /// core is behind, and then the core's older Strain is not the figure to show. With no Strain for that day
    /// the overlay carries none, and a core that is behind shows none.
    static func assembleLive(
        previous: WidgetSnapshot?,
        base: WidgetSnapshot,
        coreStrain: Double?,
        token: VerifiedSinkToken,
        verified: VerifiedHealthProjection,
        bpm: Int?,
        batteryPct: Double?,
        bonded: Bool,
        workoutSparkline: [Int]?,
        todayStrain: (String) -> ResolvedStrain?,
        now: Date,
        calendar: Calendar = .current
    ) -> (next: WidgetSnapshot, overlay: WidgetLiveOverlay) {
        let currentKey = WidgetCoreDay.currentKey(now: now, calendar: calendar)
        let liveStrain = (try? CivilDay(key: currentKey)).flatMap {
            WidgetSnapshot.liveStoredStrain(todayStrain(currentKey), day: $0)
        }
        var next = previous ?? base
        next.bpm = bpm
        next.batteryPct = batteryPct.map { Int($0.rounded()) }
        next.bonded = bonded
        next.strain = WidgetCoreDay.isCurrent(verified.logicalDay, now: now, calendar: calendar) ? coreStrain : nil
        next.applyLiveStrain(stored: liveStrain)
        next.updated = now
        next.hrSparkline = workoutSparkline
        let overlay = WidgetLiveOverlay(
            epoch: token.epoch,
            contextId: verified.contextId,
            generation: verified.generation,
            bpm: bpm,
            batteryPct: batteryPct.map { Int($0.rounded()) },
            bonded: bonded,
            hrSparkline: workoutSparkline,
            storedStrain: liveStrain,
            updated: now)
        return (next, overlay)
    }

    /// CORE-10: the one widget "bonded" definition, shared with the live lane: the strap link is up. The
    /// core used `live.bonded` (set only after the bond handshake) while the live lane used `connected`, so
    /// the two lanes could write opposite values for the same moment. `connected` matches the Live
    /// Activity's connection flag and the live lane's connection-edge publishing.
    static func widgetBonded(_ live: LiveState) -> Bool { live.connected }

    /// A core snapshot is written with no enrichment (it is the O(1) durable acknowledgement) and the envelope
    /// commit replaces the whole snapshot, so every re-commit wiped the HRV and Stress an earlier enrichment had
    /// already added. The 15-minute enrichment TTL then kept the same generation from being enriched again.
    /// This puts the latest valid enrichment of the envelope being replaced onto the new core, so a core
    /// publish can never take it away:
    /// - the same generation (a foreground then a background publish, a HealthKit republish) always carries;
    /// - a newer generation carries only for the same logical day, because enrichment is that day's HRV and
    ///   hourly stress. `olderGenerationDay` is the day the replaced generation described, read from its
    ///   immutable bundle; without it nothing crosses a generation;
    /// - the HRV scalar is the night that generation was scored on, and a newer generation can have a different
    ///   night (it is scored after the older one was committed), so it is never carried across generations: the
    ///   core computes it itself (`CoreDelivery.hrv`). Only a re-commit of the same generation, whose core
    ///   could not compute it, keeps the one already there. The sparkline is history and carries as above;
    /// - the hourly stress and its summary are the core's day's, so they carry only while that day is the current
    ///   logical day (`dayIsCurrent`); a core that is behind has no strip, not yesterday's;
    /// - an envelope of another epoch or context carries nothing.
    /// Enrichment for the new generation still runs and replaces what was carried with fresh values.
    static func carryingEnrichment(
        into core: WidgetSnapshot,
        from existing: VerifiedWidgetEnvelope?,
        token: VerifiedSinkToken,
        generation: Int64,
        logicalDay: CivilDay,
        olderGenerationDay: (generation: Int64, day: CivilDay)?,
        dayIsCurrent: Bool = true
    ) -> WidgetSnapshot {
        guard let existing,
              existing.epoch == token.epoch,
              existing.contextId == token.contextId else { return core }
        if existing.generation != generation {
            guard existing.generation < generation,
                  let older = olderGenerationDay,
                  older.generation == existing.generation,
                  older.day == logicalDay else { return core }
        }
        var carried = core
        if carried.hrv == nil, existing.generation == generation { carried.hrv = existing.snapshot.hrv }
        if carried.hrvSparkline == nil { carried.hrvSparkline = existing.snapshot.hrvSparkline }
        if dayIsCurrent {
            if carried.hourlyStress == nil { carried.hourlyStress = existing.snapshot.hourlyStress }
            if carried.stressSummary == nil { carried.stressSummary = existing.snapshot.stressSummary }
        }
        return carried
    }

    /// Pure regression seam for the immutable core-to-Widget mapping.
    ///
    /// `steps` is the figure Today shows for the current logical day (`TodaySteps`). The core carries only the
    /// strap's count, so a day Today fills from Apple Health or the estimate would otherwise read as a dash on
    /// the widget. While the core is the current day's, nil keeps its own count.
    ///
    /// When the core is from an earlier day (`WidgetCoreDay`), its Strain, Steps and Calories are not today's:
    /// Strain and Steps are replaced by `currentDayStrain` and `steps`, which are Today's for the current logical
    /// day, or by nothing, and Calories (a running day total) are left out. Resting HR is then the delivery's
    /// alone: the core's own value is a night counted from the core's day, not from today.
    static func makeCoreSnapshot(
        bundle: VerifiedExternalProjectionBundle,
        bpm: Int?,
        batteryPct: Double?,
        bonded: Bool,
        now: Date = Date(),
        calendar: Calendar = .current,
        steps: Int? = nil,
        currentDayStrain: Double? = nil,
        hrv: Int? = nil,
        restingHR: Int? = nil
    ) -> WidgetSnapshot {
        let projection = bundle.projection
        let core = bundle.widgetCore
        let dayIsCurrent = WidgetCoreDay.isCurrent(core.logicalDay, now: now, calendar: calendar)
        return WidgetSnapshot.publishing(
            recovery: projection.visibleMetric(.recovery)?.value,
            storedStrain: dayIsCurrent ? projection.visibleMetric(.strain)?.value : currentDayStrain,
            sleepScore: projection.visibleMetric(.sleepScore)?.value,
            bpm: bpm,
            batteryPct: batteryPct,
            bonded: bonded,
            hrv: hrv.map(Double.init),
            restingHr: dayIsCurrent ? (restingHR ?? core.restingHR) : restingHR,
            recoveryDelta: core.recoveryDelta,
            sleepMinutes: core.sleepMinutes,
            steps: dayIsCurrent ? (steps ?? core.steps) : steps,
            calories: dayIsCurrent ? core.calories : nil,
            hourlyStress: nil,
            stressSummary: nil,
            hrSparkline: nil,
            hrvSparkline: nil,
            verifiedContextId: projection.contextId,
            verifiedProjectionGeneration: projection.generation,
            updated: now)
    }
}
#endif
