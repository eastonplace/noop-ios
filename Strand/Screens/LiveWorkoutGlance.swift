import Foundation
import StrandDesign
import StrandAnalytics

/// What the glance-first live screen puts where, worked out from plain values so the rules are tested without a view.
///
/// One big number for the session (the distance of a run, the time of a strength session), a row of two smaller ones, the
/// zone line, and a two-number footer. A metric already shown is never shown again, so the current heart rate that used to
/// appear three times on an indoor session appears once.
enum LiveWorkoutGlance {
    enum Metric: String, CaseIterable, Sendable {
        case time, distance, pace, speed, heartRate, strain, calories, averageHeartRate
    }

    /// How the sport is measured on this screen.
    enum SportClass: String, Sendable {
        /// A run, walk or hike with a route recording: distance, with pace.
        case routePace
        /// A ride with a route recording: distance, with speed.
        case routeSpeed
        /// Everything without a route (strength, HIIT, treadmill, yoga, a route sport with location off): time.
        case indoor
    }

    struct Layout: Equatable {
        let focus: Metric
        let secondaries: [Metric]
        let footer: [Metric]
        /// The zone line carries the current bpm beside its word. Not on an indoor session, whose heart rate is a secondary.
        let zoneLineShowsBPM: Bool
    }

    /// One metric ready to draw.
    struct Value: Equatable {
        let metric: Metric
        /// "Distance · km": the name and the unit (drawn in capitals).
        let eyebrow: String
        /// The number as shown, or `LiveWorkoutTiles.missing`.
        let text: String
        /// A line under the number ("scores in 4:38").
        let micro: String?
        /// What VoiceOver reads for the number.
        let spoken: String
        var isMissing: Bool { text == LiveWorkoutTiles.missing }
        /// The name alone ("Distance"), for VoiceOver.
        var name: String { eyebrow.components(separatedBy: " · ").first ?? eyebrow }
    }

    // MARK: Layout

    static func sportClass(sport: String, tracksRoute: Bool) -> SportClass {
        guard tracksRoute else { return .indoor }
        return LiveWorkoutTiles.usesSpeed(sport: sport) ? .routeSpeed : .routePace
    }

    /// The layout for a class. `chosenFocus` is the metric the wearer picked as the big number: when it is already shown
    /// as a secondary or in the footer, it and the default focus swap places. A metric that is not shown at all is ignored
    /// rather than dropping something the wearer can see.
    static func layout(for sportClass: SportClass, chosenFocus: Metric? = nil) -> Layout {
        var focus: Metric
        var secondaries: [Metric]
        let showsBPM: Bool
        switch sportClass {
        case .routePace: (focus, secondaries, showsBPM) = (.distance, [.time, .pace], true)
        case .routeSpeed: (focus, secondaries, showsBPM) = (.distance, [.time, .speed], true)
        case .indoor: (focus, secondaries, showsBPM) = (.time, [.heartRate, .strain], false)
        }
        var footer = footerMetrics(excluding: [focus] + secondaries)
        if let chosen = chosenFocus, chosen != focus {
            if let index = secondaries.firstIndex(of: chosen) {
                secondaries[index] = focus
                focus = chosen
            } else if let index = footer.firstIndex(of: chosen) {
                footer[index] = focus
                focus = chosen
            }
        }
        return Layout(focus: focus, secondaries: secondaries, footer: footer, zoneLineShowsBPM: showsBPM)
    }

    /// The first two of strain, calories and average heart rate that are not already on the screen.
    private static func footerMetrics(excluding shown: [Metric]) -> [Metric] {
        Array([Metric.strain, .calories, .averageHeartRate].filter { !shown.contains($0) }.prefix(2))
    }

    /// What a metric is called ("Avg pace"), for a menu that lists metrics without a value to read the name from.
    static func name(of metric: Metric) -> String {
        switch metric {
        case .time: String(localized: "Time")
        case .distance: String(localized: "Distance")
        case .pace: String(localized: "Avg pace")
        case .speed: String(localized: "Avg speed")
        case .heartRate: String(localized: "Heart rate")
        case .strain: String(localized: "Strain")
        case .calories: String(localized: "Calories")
        case .averageHeartRate: String(localized: "Avg HR")
        }
    }

    // MARK: Chosen focus

    /// The big number the wearer picked, kept per kind of sport so what they want from a run is not forced on a strength
    /// session. Stored as the metric's raw value; anything unrecognised is no choice.
    enum FocusPreference {
        static func key(for sportClass: SportClass) -> String { "workoutFocus.\(sportClass.rawValue)" }

        static func metric(from raw: String) -> Metric? { Metric(rawValue: raw) }

        /// What the wearer may pick: every number the class's own screen already shows, in the order it shows them, so a
        /// choice never brings a number onto the screen that was not there or takes one off it.
        static func choices(for sportClass: SportClass) -> [Metric] {
            let layout = LiveWorkoutGlance.layout(for: sportClass)
            return [layout.focus] + layout.secondaries + layout.footer
        }
    }

    // MARK: Values

    static func value(_ metric: Metric, input: LiveWorkoutTiles.Input, elapsed: TimeInterval, strain: LiveStrainState,
                      locale: Locale = .current) -> Value {
        let missing = LiveWorkoutTiles.missing
        // VoiceOver never reads a dash; a number that is not known is "No reading".
        let noReading = String(localized: "No reading")
        switch metric {
        case .time:
            let text = LiveWorkoutTiles.elapsedText(elapsed)
            return Value(metric: metric, eyebrow: String(localized: "Time"), text: text, micro: nil,
                         spoken: LiveWorkoutTiles.spokenElapsed(elapsed))
        case .distance:
            let text = LiveWorkoutTiles.distanceText(meters: input.distanceMeters, imperial: input.imperial, locale: locale)
            let unit = input.imperial ? "mi" : "km"
            return Value(metric: metric, eyebrow: "\(String(localized: "Distance")) · \(unit)", text: text, micro: nil,
                         spoken: text == missing ? noReading : LiveWorkoutTiles.spokenDistance(text, imperial: input.imperial))
        case .pace:
            let text = LiveWorkoutTiles.paceText(secPerKm: input.paceSecPerKm, imperial: input.imperial)
            let unit = input.imperial ? "/mi" : "/km"
            return Value(metric: metric, eyebrow: "\(String(localized: "Avg pace")) · \(unit)", text: text, micro: nil,
                         spoken: text == missing ? noReading
                            : WorkoutFormat.spokenPace(text, system: input.imperial ? .imperial : .metric))
        case .speed:
            let text = LiveWorkoutTiles.speedText(secPerKm: input.paceSecPerKm, imperial: input.imperial, locale: locale)
            let unit = input.imperial ? "mph" : "km/h"
            return Value(metric: metric, eyebrow: "\(String(localized: "Avg speed")) · \(unit)", text: text, micro: nil,
                         spoken: text == missing ? noReading : LiveWorkoutTiles.spokenSpeed(text, imperial: input.imperial))
        case .heartRate:
            let text = LiveWorkoutTiles.count(input.bpm, locale: locale)
            return Value(metric: metric, eyebrow: "\(String(localized: "Heart rate")) · bpm", text: text, micro: nil,
                         spoken: text == missing ? noReading : input.bpm.map(LiveWorkoutTiles.spokenHeartRate) ?? noReading)
        case .averageHeartRate:
            let text = LiveWorkoutTiles.count(input.averageHR > 0 ? input.averageHR : nil, locale: locale)
            return Value(metric: metric, eyebrow: "\(String(localized: "Avg HR")) · bpm", text: text, micro: nil,
                         spoken: text == missing ? noReading : LiveWorkoutTiles.spokenHeartRate(input.averageHR))
        case .calories:
            let text = LiveWorkoutTiles.count(input.calories, locale: locale)
            return Value(metric: metric, eyebrow: "\(String(localized: "Calories")) · kcal", text: text, micro: nil,
                         spoken: text == missing ? noReading : input.calories.map { WorkoutFormat.spokenEnergy(Double($0)) } ?? noReading)
        case .strain:
            switch strain {
            case .scored(let stored):
                let text = StrainScale.formatted(stored, locale: locale)
                return Value(metric: metric, eyebrow: String(localized: "Strain"), text: text, micro: nil, spoken: text)
            case .building(_, let coverage):
                let remaining = max(0, StrainScorerV2.minCoverageSeconds - coverage)
                let clock = String(format: "%d:%02d", remaining / 60, remaining % 60)
                return Value(metric: metric, eyebrow: String(localized: "Strain"), text: missing,
                             micro: String(localized: "scores in \(clock)"), spoken: String(localized: "Strain scores in \(clock)"))
            }
        }
    }
}
