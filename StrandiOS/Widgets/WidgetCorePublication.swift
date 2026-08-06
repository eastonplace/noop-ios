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
        let projection = bundle.projection
        let core = bundle.widgetCore
        return WidgetSnapshot.publishing(
            recovery: projection.visibleMetric(.recovery)?.value,
            storedStrain: projection.visibleMetric(.strain)?.value,
            sleepScore: projection.visibleMetric(.sleepScore)?.value,
            bpm: model.bpm ?? model.live.heartRate,
            batteryPct: model.live.batteryPct,
            bonded: model.live.bonded,
            hrv: nil,
            restingHr: core.restingHR,
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
