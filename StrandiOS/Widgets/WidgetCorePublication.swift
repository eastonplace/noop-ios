#if os(iOS)
import Foundation
import NoopPhase34Core

/// O(1) durable Widget payload. History-series and stress enrichment are intentionally absent from this
/// helper and run only after the outbox caller has received its core acknowledgement.
@MainActor
enum WidgetCorePublication {
    static func makeCoreSnapshot(
        model: AppModel,
        projection: VerifiedHealthProjection,
        now: Date = Date()
    ) -> WidgetSnapshot {
        let day = model.repo.days.first(where: { $0.day == projection.logicalDay.key })
        return WidgetSnapshot.publishing(
            recovery: projection.visibleMetric(.recovery)?.value,
            storedStrain: projection.visibleMetric(.strain)?.value,
            sleepScore: projection.visibleMetric(.sleepScore)?.value,
            bpm: model.bpm ?? model.live.heartRate,
            batteryPct: model.live.batteryPct,
            bonded: model.live.bonded,
            hrv: nil,
            restingHr: day?.restingHr,
            sleepMinutes: day?.totalSleepMin.map { Int($0.rounded()) },
            steps: day?.steps,
            calories: day?.activeKcalEst.map { Int($0.rounded()) },
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
