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
