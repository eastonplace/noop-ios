import Foundation
import StrandAnalytics

// Strength Strain on the day's cardio curve. Pure and tested; nothing here reads a repository or the clock.

enum StrainDayLiftTransform {
    /// The day's cardio curve with its logged lifts added.
    ///
    /// - No lifts, or a day load of 0, returns `analysis` unchanged, bit for bit.
    /// - A point at time `t` carries the load of every lift that had ended by `t`, so a lift raises the curve only
    ///   after it ended.
    /// - The last point always carries the whole day's load, so a lift that ended after the last reading still lands
    ///   in full and the curve's end agrees with the stored score.
    /// - `components` stay heart rate only: the parts add the load back through `StrainScoreParts`.
    static func apply(_ analysis: StrainDayAnalysis, loads: [StrainDayLiftLoad]) -> StrainDayAnalysis {
        let usable = loads.filter { $0.muscularLoad.isFinite && $0.muscularLoad > 0 }
        let dayLoad = StrengthStrain.dayMuscularLoad(usable.map(\.muscularLoad))
        guard dayLoad > 0 else { return analysis }
        var curve = analysis.curve
        let lastIndex = curve.indices.last
        for index in curve.indices {
            let load: Double
            if index == lastIndex {
                load = dayLoad
            } else {
                let at = curve[index].t.timeIntervalSince1970
                load = StrengthStrain.dayMuscularLoad(
                    usable.filter { Double($0.endTs) <= at }.map(\.muscularLoad))
            }
            guard load > 0 else { continue }
            curve[index] = StrainScorerV2.CumulativeCardioPoint(
                t: curve[index].t,
                value: StrengthStrain.combinedDisplay(hrDisplay: curve[index].value, muscularLoad: load))
        }
        return StrainDayAnalysis(components: analysis.components, curve: curve,
                                 gateOpenedAt: analysis.gateOpenedAt, liftMuscularLoad: dayLoad)
    }
}
