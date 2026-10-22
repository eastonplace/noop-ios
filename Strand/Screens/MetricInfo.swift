import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - ⓘ copy
//
// One place for what a metric's ⓘ says. Each entry leads with what the numbers mean for the person and what to do about
// them, and ends with a short "how it's worked out". Add a case to cover another metric; present it with
// `.metricInfoSheet($info)` and open it from a header's `infoAction`.

enum MetricInfo: String, Identifiable {
    case loadFocus
    case trainingLoad
    case hrv
    case restingHR
    case respiratory
    case readiness
    case recovery
    case strain
    case strainScore
    case trendScores
    case sleepScore
    case sleepStages
    case sleepNeed
    case nightDetail
    case vitality
    case recoveryForecast
    case weeklyReadout
    case stress
    case loadProjection
    case loadHistory
    case metricRelationships
    case doseResponse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .loadFocus: String(localized: "About Load focus")
        case .trainingLoad: String(localized: "About Training load")
        case .hrv: String(localized: "About HRV")
        case .restingHR: String(localized: "About Resting HR")
        case .respiratory: String(localized: "About Respiratory rate")
        case .readiness: String(localized: "About Readiness")
        case .recovery: String(localized: "About Recovery")
        case .strain: String(localized: "About Strain")
        case .strainScore: String(localized: "About your Strain score")
        case .trendScores: String(localized: "About Trends")
        case .sleepScore: String(localized: "About Sleep score")
        case .sleepStages: String(localized: "About Sleep stages")
        case .sleepNeed: String(localized: "About Sleep need")
        case .nightDetail: String(localized: "About Night detail")
        case .vitality: String(localized: "About Vitality and Body Age")
        case .recoveryForecast: String(localized: "About Tomorrow's Recovery")
        case .weeklyReadout: String(localized: "About the Weekly readout")
        case .stress: String(localized: "About Stress")
        case .loadProjection: String(localized: "About tomorrow's load")
        case .loadHistory: String(localized: "About Load over time")
        case .metricRelationships: String(localized: "About Metric relationships")
        case .doseResponse: String(localized: "About Dose-response")
        }
    }

    /// The ⓘ button's VoiceOver label.
    var accessibilityLabel: LocalizedStringKey {
        switch self {
        case .loadFocus: "About Load focus"
        case .trainingLoad: "About Training load"
        case .hrv: "About HRV"
        case .restingHR: "About Resting HR"
        case .respiratory: "About Respiratory rate"
        case .readiness: "About Readiness"
        case .recovery: "About Recovery"
        case .strain: "About Strain"
        case .strainScore: "About your Strain score"
        case .trendScores: "About Trends"
        case .sleepScore: "About Sleep score"
        case .sleepStages: "About Sleep stages"
        case .sleepNeed: "About Sleep need"
        case .nightDetail: "About Night detail"
        case .vitality: "About Vitality and Body Age"
        case .recoveryForecast: "About Tomorrow's Recovery"
        case .weeklyReadout: "About the Weekly readout"
        case .stress: "About Stress"
        case .loadProjection: "About tomorrow's load"
        case .loadHistory: "About Load over time"
        case .metricRelationships: "About Metric relationships"
        case .doseResponse: "About Dose-response"
        }
    }

    var sections: [MetricInfoSection] {
        switch self {
        case .loadFocus: Self.loadFocusSections
        case .trainingLoad: Self.trainingLoadSections
        case .hrv: Self.hrvSections
        case .restingHR: Self.restingHRSections
        case .respiratory: Self.respiratorySections
        case .readiness: Self.readinessSections
        case .recovery: Self.recoverySections
        case .strain: Self.strainSections
        case .strainScore: Self.strainScoreSections
        case .trendScores: Self.trendScoresSections
        case .sleepScore: Self.sleepScoreSections
        case .sleepStages: Self.sleepStagesSections
        case .sleepNeed: Self.sleepNeedSections
        case .nightDetail: Self.nightDetailSections
        case .vitality: Self.vitalitySections
        case .recoveryForecast: Self.recoveryForecastSections
        case .weeklyReadout: Self.weeklyReadoutSections
        case .stress: Self.stressSections
        case .loadProjection: Self.loadProjectionSections
        case .loadHistory: Self.loadHistorySections
        case .metricRelationships: Self.metricRelationshipsSections
        case .doseResponse: Self.doseResponseSections
        }
    }

    private static var loadFocusSections: [MetricInfoSection] {
        let override = ProfileStore.storedHrMaxOverride()
        let maxHR = ProfileStore.hrMax(age: ProfileStore.storedAge(), override: override)
        let source = override > 0 ? String(localized: "your own setting") : String(localized: "estimated from your age")
        return [
            .init(heading: String(localized: "What it means"), body:
                String(localized: "How your workout effort splits between easy aerobic work, tempo and threshold work, and all-out work.")),
            .init(heading: String(localized: "What good looks like"), paragraphs: [
                String(localized: "Most of your training easy, some of it tempo, and a little of it hard. Roughly 35–55% low aerobic, 25–45% high aerobic and 5–15% anaerobic."),
                String(localized: "Low aerobic is zones 1–2, steady easy effort. High aerobic is zones 3–4, tempo and threshold. Anaerobic is zone 5, intervals and sprints."),
                String(localized: "Most endurance fitness is built on easy volume, and a little hard work goes a long way.")
            ]),
            .init(heading: String(localized: "Reading yours"), paragraphs: [
                String(localized: "In range: your mix looks like a typical endurance build. Keep going."),
                String(localized: "Low aerobic a bit low: add more easy volume, like an extra easy session or longer easy days."),
                String(localized: "High aerobic a bit high: you are living in the middle. Make easy days easier and keep hard days purposeful."),
                String(localized: "Anaerobic a bit high: too much hard work against your base raises fatigue and injury risk. Add easy sessions or swap one hard day for an easy one."),
                String(localized: "Anaerobic a bit low: fine if you are building a base. A short interval session now and then is enough."),
                String(localized: "It is a guide, not a prescription. Your sport and your goals can sensibly sit outside these ranges.")
            ]),
            .init(heading: String(localized: "How it's worked out"), body:
                String(localized: "From workout heart rate only, over the last 4 weeks. Minutes in harder zones count more, weighted like Strain. It needs \(LoadFocus.minimumWorkouts)+ workouts with heart rate. Zones use a max HR of \(maxHR) (\(source)).")),
        ]
    }

    private static var trainingLoadSections: [MetricInfoSection] {
        [
            .init(heading: String(localized: "What the numbers mean"), paragraphs: [
                String(localized: "Recent load is how much you have been training over about the last week."),
                String(localized: "Fitness base is what your body is used to, over about six weeks."),
                String(localized: "Form is base minus recent. It says whether you are fresher or more tired than usual.")
            ]),
            .init(heading: String(localized: "What your load should be"), paragraphs: [
                String(localized: "Compare recent load to your base. At 0.8–1.3× you are building steadily."),
                String(localized: "Above about 1.3× is a spike. Injury and fatigue risk rises, so ease up for a few days."),
                String(localized: "Below 0.8× you are easing off. That is fine for recovery or a taper, but fitness slowly drops if it lasts for weeks.")
            ]),
            .init(heading: String(localized: "Reading form"), paragraphs: [
                String(localized: "Negative form means you are training above your base. That is normal in a build block, so watch your recovery."),
                String(localized: "Positive form means you are fresher.")
            ]),
            .init(heading: String(localized: "It is personal"), body:
                String(localized: "There is no right number. Compare with your own base, not with other people's load.")),
            .init(heading: String(localized: "How it's worked out"), body:
                String(localized: "Each day's Strain feeds two running averages, about 1 week and about 6 weeks. Recent days count more.")),
        ]
    }
}

extension View {
    /// Presents the chosen metric's explainer in the shared sheet. Attach once per screen, outside any tappable card.
    func metricInfoSheet(_ info: Binding<MetricInfo?>) -> some View {
        sheet(item: info) { MetricInfoSheet(title: $0.title, sections: $0.sections) }
    }
}
