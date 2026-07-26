import Foundation
import WhoopStore

/// One recovered night's daily result, ready to persist beside the corrected session.
public struct ManualSleepDailyScore: Equatable, Sendable {
    public let daily: DailyMetric
    public let restScore: Double?

    public init(daily: DailyMetric, restScore: Double?) {
        self.daily = daily
        self.restScore = restScore
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

        let provisional = DailyMetric(
            day: day,
            totalSleepMin: summary?.totalSleepMin ?? existing?.totalSleepMin,
            efficiency: summary?.efficiency ?? existing?.efficiency,
            deepMin: summary?.deepMin ?? existing?.deepMin,
            remMin: summary?.remMin ?? existing?.remMin,
            lightMin: summary?.lightMin ?? existing?.lightMin,
            disturbances: summary?.disturbances ?? existing?.disturbances,
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
        let respBaseline = Baselines.foldHistory(
            history.map(\.respRateBpm),
            dayKeys: dayKeys,
            cfg: Baselines.respCfg,
            baselineEpoch: recoveryBaselineEpoch)

        let recovery: Double? = {
            guard let hrv = avgHrv, let rhr = restingHr else { return nil }
            return RecoveryScorer.recovery(
                hrv: hrv,
                rhr: Double(rhr),
                resp: existing?.respRateBpm,
                hrvBaseline: hrvBaseline,
                rhrBaseline: rhrBaseline,
                respBaseline: respBaseline,
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
        return ManualSleepDailyScore(daily: daily, restScore: restScore)
    }

    private static func stageSummary(
        stages: [StageSegment],
        start: Int,
        end: Int,
        statedEfficiency: Double?
    ) -> StageSummary? {
        guard end > start, !stages.isEmpty else { return nil }
        var deep = 0.0
        var rem = 0.0
        var light = 0.0
        var asleep = 0.0
        var disturbances = 0
        var hasSeenSleep = false
        var priorWasWake = true

        for segment in stages.sorted(by: { $0.start < $1.start }) {
            let lo = max(start, segment.start)
            let hi = min(end, segment.end)
            guard hi > lo else { continue }
            let seconds = Double(hi - lo)
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
        let inBed = Double(end - start)
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
