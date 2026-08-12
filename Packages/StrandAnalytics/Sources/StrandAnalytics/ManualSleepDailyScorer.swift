import Foundation
import WhoopStore

/// The baseline-normalized Charge terms that do not depend on Rest. Persisting this
/// small summary lets a later sleep-boundary edit recompute Charge from a freshly
/// re-staged Rest score without duplicating the personal-baseline fold in storage.
public struct ManualSleepChargeContext: Equatable, Sendable {
    public let weightedSumWithoutSleep: Double?
    public let weightWithoutSleep: Double?
    public let baselineUsable: Bool

    public init(
        weightedSumWithoutSleep: Double?,
        weightWithoutSleep: Double?,
        baselineUsable: Bool
    ) {
        self.weightedSumWithoutSleep = weightedSumWithoutSleep
        self.weightWithoutSleep = weightWithoutSleep
        self.baselineUsable = baselineUsable
    }
}

/// One recovered night's daily result, ready to persist beside the corrected session.
public struct ManualSleepDailyScore: Equatable, Sendable {
    public let daily: DailyMetric
    public let restScore: Double?
    public let chargeContext: ManualSleepChargeContext

    public init(
        daily: DailyMetric,
        restScore: Double?,
        chargeContext: ManualSleepChargeContext
    ) {
        self.daily = daily
        self.restScore = restScore
        self.chargeContext = chargeContext
    }
}

/// Builds the exact DailyMetric/Rest/Charge consequences of a bounded recovery.
/// Pure and independently testable: storage and UI never duplicate score math.
public enum ManualSleepDailyScorer {
    private struct StageSummary {
        let totalSleepMin: Double
        let efficiency: Double
        let deepMin: Double
        let remMin: Double
        let lightMin: Double
        let disturbances: Int
    }

    public static func score(
        day: String,
        analysis: SleepWindowRecoveryResult,
        existing: DailyMetric?,
        priorHistory: [DailyMetric],
        sleepNeedHours: Double = AnalyticsEngine.Rest.defaultNeedHours,
        sleepConsistency: Double? = nil,
        hrvBaselineEpoch: Double = Baselines.hrvBaselineEpoch(),
        recoveryBaselineEpoch: Double = Baselines.recoveryBaselineEpoch()
    ) -> ManualSleepDailyScore {
        let summary = analysis.hasDefensibleStages
            ? stageSummary(
                stages: analysis.stages,
                start: analysis.requestedStart,
                end: analysis.requestedEnd,
                statedEfficiency: analysis.efficiency)
            : nil

        let restingHr = analysis.restingHR ?? existing?.restingHr
        let avgHrv = analysis.avgHRV ?? existing?.avgHrv

        // The recovered window owns the sleep fields for this wake day. If motion was
        // too sparse to defend staging, those fields stay nil rather than inheriting a
        // stale detector total from the row being repaired. Non-sleep activity fields
        // remain owned by the existing daily row.
        let provisional = DailyMetric(
            day: day,
            totalSleepMin: summary?.totalSleepMin,
            efficiency: summary?.efficiency,
            deepMin: summary?.deepMin,
            remMin: summary?.remMin,
            lightMin: summary?.lightMin,
            disturbances: summary?.disturbances,
            restingHr: restingHr,
            avgHrv: avgHrv,
            recovery: nil,
            strain: existing?.strain,
            exerciseCount: existing?.exerciseCount,
            spo2Pct: existing?.spo2Pct,
            skinTempDevC: existing?.skinTempDevC,
            respRateBpm: existing?.respRateBpm,
            steps: existing?.steps,
            activeKcalEst: existing?.activeKcalEst,
            spo2Red: existing?.spo2Red,
            spo2Ir: existing?.spo2Ir,
            strainVersion: existing?.strainVersion)

        let restScore = summary == nil
            ? nil
            : AnalyticsEngine.Rest.composite(
                daily: provisional,
                needHours: sleepNeedHours,
                consistency: sleepConsistency)

        let history = priorHistory
            .filter { $0.day < day }
            .sorted { $0.day < $1.day }
        let dayKeys = history.map(\.day)
        let hrvBaseline = Baselines.foldHistory(
            history.map(\.avgHrv),
            dayKeys: dayKeys,
            cfg: Baselines.hrvCfg,
            baselineEpoch: hrvBaselineEpoch)
        let rhrBaseline = Baselines.foldHistory(
            history.map { $0.restingHr.map(Double.init) },
            dayKeys: dayKeys,
            cfg: Baselines.restingHRCfg,
            baselineEpoch: recoveryBaselineEpoch)
        let respFold = Baselines.foldHistory(
            history.map(\.respRateBpm),
            dayKeys: dayKeys,
            cfg: Baselines.respCfg,
            baselineEpoch: recoveryBaselineEpoch)

        let chargeContext: ManualSleepChargeContext = {
            guard hrvBaseline.usable, let hrv = avgHrv, let rhr = restingHr else {
                return ManualSleepChargeContext(
                    weightedSumWithoutSleep: nil,
                    weightWithoutSleep: nil,
                    baselineUsable: false)
            }

            var weightedSum = 0.0
            var weight = 0.0

            weightedSum += RecoveryScorer.zScore(
                hrv,
                mean: hrvBaseline.baseline,
                spread: hrvBaseline.spread) * RecoveryScorer.wHRV
            weight += RecoveryScorer.wHRV

            weightedSum += RecoveryScorer.zScore(
                rhrBaseline.baseline,
                mean: Double(rhr),
                spread: rhrBaseline.spread) * RecoveryScorer.wRHR
            weight += RecoveryScorer.wRHR

            if let resp = existing?.respRateBpm, respFold.usable {
                weightedSum += RecoveryScorer.zScore(
                    respFold.baseline,
                    mean: resp,
                    spread: respFold.spread) * RecoveryScorer.wResp
                weight += RecoveryScorer.wResp
            }

            if let skinTempDev = existing?.skinTempDevC {
                weightedSum += (-abs(skinTempDev) / RecoveryScorer.skinTempScaleC)
                    * RecoveryScorer.wSkinTemp
                weight += RecoveryScorer.wSkinTemp
            }

            return ManualSleepChargeContext(
                weightedSumWithoutSleep: weightedSum,
                weightWithoutSleep: weight,
                baselineUsable: true)
        }()

        let recovery: Double? = {
            guard let hrv = avgHrv, let rhr = restingHr else { return nil }
            return RecoveryScorer.recovery(
                hrv: hrv,
                rhr: Double(rhr),
                resp: existing?.respRateBpm,
                hrvBaseline: hrvBaseline,
                rhrBaseline: rhrBaseline,
                respBaseline: respFold.usable ? respFold : nil,
                sleepPerf: restScore.map { $0 / 100.0 },
                skinTempDev: existing?.skinTempDevC)
        }()

        let daily = DailyMetric(
            day: provisional.day,
            totalSleepMin: provisional.totalSleepMin,
            efficiency: provisional.efficiency,
            deepMin: provisional.deepMin,
            remMin: provisional.remMin,
            lightMin: provisional.lightMin,
            disturbances: provisional.disturbances,
            restingHr: provisional.restingHr,
            avgHrv: provisional.avgHrv,
            recovery: recovery,
            strain: provisional.strain,
            exerciseCount: provisional.exerciseCount,
            spo2Pct: provisional.spo2Pct,
            skinTempDevC: provisional.skinTempDevC,
            respRateBpm: provisional.respRateBpm,
            steps: provisional.steps,
            activeKcalEst: provisional.activeKcalEst,
            spo2Red: provisional.spo2Red,
            spo2Ir: provisional.spo2Ir,
            strainVersion: provisional.strainVersion)
        return ManualSleepDailyScore(
            daily: daily,
            restScore: restScore,
            chargeContext: chargeContext)
    }

    private static func stageSummary(
        stages: [StageSegment],
        start: Int,
        end: Int,
        statedEfficiency: Double?
    ) -> StageSummary? {
        guard let inBedSeconds = SleepTimestampMath.nonnegativeDuration(start: start, end: end),
              inBedSeconds > 0,
              !stages.isEmpty
        else { return nil }
        var deep = 0.0
        var rem = 0.0
        var light = 0.0
        var asleep = 0.0
        var disturbances = 0
        var hasSeenSleep = false
        var priorWasWake = true

        for segment in stages.sorted(by: { $0.start < $1.start }) {
            guard SleepTimestampMath.nonnegativeDuration(
                start: segment.start,
                end: segment.end
            ) != nil else {
                return nil
            }
            let lo = max(start, segment.start)
            let hi = min(end, segment.end)
            guard hi > lo else { continue }
            guard let segmentSeconds = SleepTimestampMath.nonnegativeDuration(start: lo, end: hi) else {
                return nil
            }
            let seconds = Double(segmentSeconds)
            let normalized = segment.stage.lowercased()
            let isWake = normalized == "wake" || normalized == "awake"
            if isWake {
                if hasSeenSleep && !priorWasWake { disturbances += 1 }
            } else {
                hasSeenSleep = true
                asleep += seconds
                switch normalized {
                case "deep": deep += seconds
                case "rem": rem += seconds
                default: light += seconds
                }
            }
            priorWasWake = isWake
        }

        guard asleep > 0 else { return nil }
        let inBed = Double(inBedSeconds)
        let efficiency = min(1, max(0, statedEfficiency ?? (asleep / inBed)))
        return StageSummary(
            totalSleepMin: asleep / 60.0,
            efficiency: efficiency,
            deepMin: deep / 60.0,
            remMin: rem / 60.0,
            lightMin: light / 60.0,
            disturbances: disturbances)
    }
}
