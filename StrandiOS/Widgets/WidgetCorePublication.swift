#if os(iOS)
import Foundation
import NoopPhase34Core

/// O(1) durable Widget payload. History-series and stress enrichment are intentionally absent from this
/// helper and run only after the outbox caller has received its core acknowledgement.
@MainActor
enum WidgetCorePublication {
    static func makeCoreSnapshot(
        model: AppModel,
        bundle: VerifiedExternalProjectionBundle,
        now: Date = Date()
    ) -> WidgetSnapshot {
        makeCoreSnapshot(
            bundle: bundle,
            bpm: model.bpm ?? model.live.heartRate,
            batteryPct: model.live.batteryPct,
            bonded: widgetBonded(model.live),
            now: now
        )
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
    static func makeCoreSnapshot(
        bundle: VerifiedExternalProjectionBundle,
        bpm: Int?,
        batteryPct: Double?,
        bonded: Bool,
        now: Date = Date()
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
            steps: core.steps,
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
