#if os(iOS)
import Foundation
import NoopPhase34Core
import WhoopStore

/// O(1) durable Widget payload. History-series and stress enrichment are intentionally absent from this
/// helper and run only after the outbox caller has received its core acknowledgement.
@MainActor
enum WidgetCorePublication {
    /// What `publish` resolves, from the model and the store, before the durable commit. Plain values only, so
    /// everything after them (the snapshot, the carried enrichment, the envelope commit) is `commitCore`, which
    /// a test can drive against an isolated `UserDefaults`.
    struct CoreDelivery {
        var bpm: Int?
        var batteryPct: Double?
        var bonded: Bool
        /// The Steps figure Today shows for the day (`WidgetSnapshot.todaySteps`); nil keeps the core's own count.
        var steps: Int?
        /// The day of the generation the envelope being replaced holds, when that is an older generation.
        var olderGenerationDay: (generation: Int64, day: CivilDay)?
    }

    /// The durable core publication: build the core from the immutable bundle and the resolved delivery values,
    /// put the enrichment of the envelope being replaced back on it, and commit the envelope. It never reads
    /// history; HRV and stress enrichment run after the caller has its acknowledgement.
    static func commitCore(
        bundle: VerifiedExternalProjectionBundle,
        token: VerifiedSinkToken,
        defaults: UserDefaults,
        delivery: CoreDelivery,
        now: Date
    ) -> (snapshot: WidgetSnapshot, result: VerifiedProjectionGenerationWriteResult) {
        let generation = bundle.projection.generation
        let snapshot = carryingEnrichment(
            into: makeCoreSnapshot(
                bundle: bundle,
                bpm: delivery.bpm,
                batteryPct: delivery.batteryPct,
                bonded: delivery.bonded,
                now: now,
                steps: delivery.steps),
            from: VerifiedWidgetEnvelopeStore.rawActiveEnvelope(defaults: defaults),
            token: token,
            generation: generation,
            logicalDay: bundle.widgetCore.logicalDay,
            olderGenerationDay: delivery.olderGenerationDay)
        let result = VerifiedWidgetEnvelopeStore.commit(
            token: token,
            generation: generation,
            snapshot: snapshot,
            defaults: defaults)
        return (snapshot, result)
    }

    /// The live lane's two outputs for one tick: the in-memory snapshot the publish gate compares, and the
    /// overlay that is persisted over the verified core. `coreStrain` is the verified core's own Strain
    /// (display scale), `todayStrain` what Today resolves for the generation's day.
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
        todayStrain: ResolvedStrain?,
        now: Date
    ) -> (next: WidgetSnapshot, overlay: WidgetLiveOverlay) {
        let liveStrain = WidgetSnapshot.liveStoredStrain(todayStrain, day: verified.logicalDay)
        var next = previous ?? base
        next.bpm = bpm
        next.batteryPct = batteryPct.map { Int($0.rounded()) }
        next.bonded = bonded
        next.strain = coreStrain
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
    /// - an envelope of another epoch or context carries nothing.
    /// Enrichment for the new generation still runs and replaces what was carried with fresh values.
    static func carryingEnrichment(
        into core: WidgetSnapshot,
        from existing: VerifiedWidgetEnvelope?,
        token: VerifiedSinkToken,
        generation: Int64,
        logicalDay: CivilDay,
        olderGenerationDay: (generation: Int64, day: CivilDay)?
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
        if carried.hrv == nil { carried.hrv = existing.snapshot.hrv }
        if carried.hrvSparkline == nil { carried.hrvSparkline = existing.snapshot.hrvSparkline }
        if carried.hourlyStress == nil { carried.hourlyStress = existing.snapshot.hourlyStress }
        if carried.stressSummary == nil { carried.stressSummary = existing.snapshot.stressSummary }
        return carried
    }

    /// Pure regression seam for the immutable core-to-Widget mapping.
    ///
    /// `steps` is the figure Today shows for the day (`TodaySteps`). The core carries only the strap's count,
    /// so a day Today fills from Apple Health or the estimate would otherwise read as a dash on the widget;
    /// nil keeps the core's own count.
    static func makeCoreSnapshot(
        bundle: VerifiedExternalProjectionBundle,
        bpm: Int?,
        batteryPct: Double?,
        bonded: Bool,
        now: Date = Date(),
        steps: Int? = nil
    ) -> WidgetSnapshot {
        let projection = bundle.projection
        let core = bundle.widgetCore
        return WidgetSnapshot.publishing(
            recovery: projection.visibleMetric(.recovery)?.value,
            storedStrain: projection.visibleMetric(.strain)?.value,
            sleepScore: projection.visibleMetric(.sleepScore)?.value,
            bpm: bpm,
            batteryPct: batteryPct,
            bonded: bonded,
            hrv: nil,
            restingHr: core.restingHR,
            recoveryDelta: core.recoveryDelta,
            sleepMinutes: core.sleepMinutes,
            steps: steps ?? core.steps,
            calories: core.calories,
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
