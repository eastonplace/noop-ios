import WhoopStore

/// Field-wise history merge used by manual missed-sleep recovery.
///
/// Imported WHOOP values remain authoritative when they are present, but an imported row with a `nil`
/// recovery driver must not erase a real on-device value from the same day. Whole-row replacement starved
/// the HRV/RHR baseline and made a recovered night report that Charge was still calibrating even when the
/// computed history already contained enough real nights.
enum SleepRecoveryHistoryMerge {
    static func merge(computed: [DailyMetric], imported: [DailyMetric]) -> [DailyMetric] {
        var byDay = Dictionary(computed.map { ($0.day, $0) }, uniquingKeysWith: { _, newest in newest })
        for importedRow in imported {
            if let computedRow = byDay[importedRow.day] {
                byDay[importedRow.day] = merged(imported: importedRow, computed: computedRow)
            } else {
                byDay[importedRow.day] = importedRow
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    private static func merged(imported: DailyMetric, computed: DailyMetric) -> DailyMetric {
        DailyMetric(
            day: imported.day,
            totalSleepMin: imported.totalSleepMin ?? computed.totalSleepMin,
            efficiency: imported.efficiency ?? computed.efficiency,
            deepMin: imported.deepMin ?? computed.deepMin,
            remMin: imported.remMin ?? computed.remMin,
            lightMin: imported.lightMin ?? computed.lightMin,
            disturbances: imported.disturbances ?? computed.disturbances,
            restingHr: imported.restingHr ?? computed.restingHr,
            avgHrv: imported.avgHrv ?? computed.avgHrv,
            recovery: imported.recovery ?? computed.recovery,
            strain: imported.strain ?? computed.strain,
            exerciseCount: imported.exerciseCount ?? computed.exerciseCount,
            spo2Pct: imported.spo2Pct ?? computed.spo2Pct,
            skinTempDevC: imported.skinTempDevC ?? computed.skinTempDevC,
            respRateBpm: imported.respRateBpm ?? computed.respRateBpm,
            steps: imported.steps ?? computed.steps,
            activeKcalEst: imported.activeKcalEst ?? computed.activeKcalEst,
            spo2Red: imported.spo2Red ?? computed.spo2Red,
            spo2Ir: imported.spo2Ir ?? computed.spo2Ir,
            strainVersion: imported.strainVersion ?? computed.strainVersion)
    }
}
