import Foundation

// MARK: - Strain wording that lifting changes
//
// Strain counts the working sets a person logs on top of heart rate (Strength Strain). These are the sentences that
// say so, as plain computed `String(localized:)` values so the views and `StrainCopyTests` read the same text. Nothing
// here claims WHOOP parity: the score is NOOP's own formula, grounded in published sports science.

enum StrainCopy {

    // MARK: Workout detail (a Strength Training session)

    /// "Heart rate only 10.0 → With your sets 15.1". Both numbers are already formatted for the person's locale.
    static func liftSplit(heartRate: String, combined: String) -> String {
        String(localized: "Heart rate only \(heartRate) → With your sets \(combined)")
    }

    static var liftIncluded: String { String(localized: "Includes your logged sets") }
    static var liftNoSets: String { String(localized: "Log sets to count lifting") }
    static var liftNotScored: String { String(localized: "Not scored yet · wear your strap during lifts") }
    static var liftScoring: String { String(localized: "Scoring…") }
    static var liftImported: String { String(localized: "Imported lifts only have totals, so this is heart rate only.") }

    /// What VoiceOver reads for the split.
    static func liftSpoken(combined: String, heartRate: String, add: String) -> String {
        String(localized: "Strain \(combined) of 21. Heart rate only \(heartRate). Your sets add \(add).")
    }

    // MARK: Strain day detail

    /// The readout's caption on the day curve when no time is touched.
    static func curveReadoutCaption(isToday: Bool, lifting: Bool) -> String {
        switch (lifting, isToday) {
        case (true, true): return String(localized: "Heart rate + lifting so far")
        case (true, false): return String(localized: "Heart rate + lifting that day")
        case (false, true): return String(localized: "Cardio load so far")
        case (false, false): return String(localized: "Cardio load that day")
        }
    }

    /// The curve's spoken summary, first sentence. `start`, `end` and `time` are already formatted.
    static func curveSummary(start: String, end: String, time: String, lifting: Bool) -> String {
        lifting
            ? String(localized: "Heart rate and lifting load through the day, from \(start) to \(end) by \(time).")
            : String(localized: "Cardio load through the day, from \(start) to \(end) by \(time).")
    }

    /// The "What set today's score" row for the day's logged lifting: its label, the line under it and what VoiceOver reads.
    /// `add` is what the sets add to the score, already formatted.
    static var liftingRowLabel: String { String(localized: "Lifting") }

    static func liftingRowDetail(add: String) -> String { String(localized: "Logged working sets add \(add)") }

    static func liftingRowSpoken(label: String, add: String) -> String { String(localized: "\(label), adds \(add)") }

    /// The pill on the row that sets the day's score. (Not "Sets score": a set is also a lifting set.)
    static var decidesScore: String { String(localized: "Decides score") }

    // MARK: How NOOP works / Scoring guide / Intelligence

    /// How NOOP works: the method behind Strain.
    static var strainMethod: String {
        String(localized: "Heart-rate load in the Banister TRIMP family (time in each heart-rate zone, harder zones weighted more), plus a muscular load from the working sets you log: reps × weight, how hard each set was and how much muscle the lift uses. Both are added before the 0–21 curve.")
    }

    /// How NOOP works: the method-family tag above the Strain method.
    static var strainFamily: String { String(localized: "HR ZONES + LOGGED SETS") }

    /// Scoring guide: the Strain card's question.
    static var scoringGuideStrainHeadline: String {
        String(localized: "Strain: how hard did your heart and muscles work?")
    }

    /// Scoring guide: the Strain card's body.
    static var scoringGuideStrainBody: String {
        String(localized: "Your cardiovascular and movement load across your sleep-to-sleep day. NOOP continuously weights each valid heart-rate interval by heart-rate reserve, credits worn sleep and real movement without double counting, and displays the result on the canonical 0–21 Strain scale. Ordinary days register; sustained maximum effort approaches 21. Logged lifting sets add a muscular load: reps × weight, how hard each set was (your RPE, 8 if you didn't pick one) and how much muscle the lift uses, measured against your body weight. Bodyweight moves count the share of your body you lift. Warm-ups don't count, a lift with no sets stays heart rate only, and imported lifts only have totals, so they stay heart rate only. Fitness Age and VO2max still use heart rate only. This is NOOP's own transparent score, not WHOOP's proprietary formula.")
    }

    /// Intelligence: the "How this works" paragraph. `scaleMax` is the Strain scale's top as the screen prints it.
    static func intelligenceExplainer(scaleMax: String) -> String {
        String(localized: "Recovery weighs your HRV against your personal baseline (~55%), resting heart rate (~20%), rest quality (~15%), respiration (~5%) and skin-temperature deviation (~5%). Strain is a 0-\(scaleMax) load from time in heart-rate zones, plus the working sets you log on lifting days. Sleep is staged from movement and heart rate. Everything is computed here from the strap's raw data. It works for any day NOOP collected raw streams.")
    }

    // MARK: Metric catalog / Trends report

    /// The Strain metric's one-line description (Metric Explorer, Compare, Trends).
    static var metricStrainDescription: String {
        String(localized: "Load for the day from heart rate plus the working sets you log, on a 0-21 scale.")
    }

    /// The Dynamic Sleep Need description. Sleep Need reads heart-rate Strain only, and the line says so.
    static var metricSleepNeedDescription: String {
        String(localized: "Tonight's computed need: baseline, plus yesterday's heart-rate Strain and sleep-debt repayment, minus nap credit.")
    }

    /// The Trends report footer's provenance legend.
    static var trendsReportLegend: String {
        String(localized: "How to read this: HRV, Resting HR, Sleep duration, Respiratory rate and Skin temperature are measured from the strap (skin temp is shown as the deviation from your own baseline). Workouts is the count of activities you logged or that were detected. Recovery, Strain and Stress are NOOP's own on-device scores, not clinical measures: Recovery is a daily readiness composite (HRV, resting HR, sleep and skin-temp trend), Strain is a load from heart rate plus the working sets you log, and Stress is a 0-3 autonomic-load index from resting HR and HRV.")
    }
}
