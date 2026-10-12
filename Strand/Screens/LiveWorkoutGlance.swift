import Foundation
import SwiftUI
import StrandDesign
import StrandAnalytics

/// What the live workout screen puts where, worked out from plain values so the rules are tested without a view.
///
/// One focus figure for the session (the distance of a run, the time of a strength session) and three secondaries under it on
/// the Focus page; the Heart page carries the heart rate with the zones, and strain and calories. A metric already shown on a
/// page is never shown twice on it.
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
        /// The three figures under the focus on the Focus page, top to bottom.
        let stack: [Metric]
    }

    /// One metric ready to draw.
    struct Value: Equatable {
        let metric: Metric
        /// "Distance": what it is called, for VoiceOver and the Make focus menu.
        let name: String
        /// The figure as shown, or `LiveWorkoutTiles.missing`.
        let text: String
        /// The unit block's lines, in the person's language ("Avg", "/km"); drawn in capitals beside the figure.
        let unit: [String]
        /// A line in the unit block ("scores in 4:38").
        let micro: String?
        /// What VoiceOver reads for the figure.
        let spoken: String
        var isMissing: Bool { text == LiveWorkoutTiles.missing }
    }

    // MARK: Layout

    static func sportClass(sport: String, tracksRoute: Bool) -> SportClass {
        guard tracksRoute else { return .indoor }
        return LiveWorkoutTiles.usesSpeed(sport: sport) ? .routeSpeed : .routePace
    }

    /// What the Heart page shows besides the heart rate itself, so a choice from it is a metric the screen already has.
    static let heartPageMetrics: [Metric] = [.heartRate, .strain, .calories]

    private static func defaultLayout(for sportClass: SportClass) -> Layout {
        switch sportClass {
        case .routePace: Layout(focus: .distance, stack: [.time, .pace, .heartRate])
        case .routeSpeed: Layout(focus: .distance, stack: [.time, .speed, .heartRate])
        case .indoor: Layout(focus: .time, stack: [.heartRate, .strain, .averageHeartRate])
        }
    }

    /// The layout for a class. `chosenFocus` is the metric the wearer picked as the focus figure. When it is already in the
    /// stack it and the focus swap places. When it is only on the Heart page (strain, calories), it becomes the focus and the
    /// old focus takes the place of the figure the Heart page repeats (the last of the stack that it also shows). A metric the
    /// screen does not show at all is ignored rather than adding one.
    static func layout(for sportClass: SportClass, chosenFocus: Metric? = nil) -> Layout {
        var layout = defaultLayout(for: sportClass)
        guard let chosen = chosenFocus, chosen != layout.focus else { return layout }
        var focus = layout.focus
        var stack = layout.stack
        if let index = stack.firstIndex(of: chosen) {
            stack[index] = focus
            focus = chosen
        } else if FocusPreference.choices(for: sportClass).contains(chosen) {
            let index = stack.lastIndex(where: heartPageMetrics.contains) ?? stack.count - 1
            stack[index] = focus
            focus = chosen
        } else {
            return layout
        }
        layout = Layout(focus: focus, stack: stack)
        return layout
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
            let layout = LiveWorkoutGlance.defaultLayout(for: sportClass)
            var all = [layout.focus] + layout.stack
            for metric in LiveWorkoutGlance.heartPageMetrics where !all.contains(metric) { all.append(metric) }
            return all
        }
    }

    // MARK: Values

    /// The unit words, localized in this one place: the figure's unit block and the strip of facts both read from here.
    enum Units {
        static func distance(imperial: Bool) -> String { imperial ? String(localized: "mi") : String(localized: "km") }
        static func pace(imperial: Bool) -> String { imperial ? String(localized: "/mi") : String(localized: "/km") }
        static func speed(imperial: Bool) -> String { imperial ? String(localized: "mph") : String(localized: "km/h") }
        static var heartRate: String { String(localized: "bpm") }
        static var energy: String { String(localized: "kcal") }
        static var average: String { String(localized: "Avg") }
        static var strain: String { String(localized: "Strain") }
    }

    /// The colour of a metric: the same on every page.
    static func color(of metric: Metric, zone: Int?) -> Color {
        switch metric {
        case .time: LivePalette.time
        case .distance: LivePalette.distance
        case .pace, .speed: LivePalette.pace
        case .heartRate, .averageHeartRate: zone.map(LivePalette.zone) ?? LivePalette.missing
        case .strain: LivePalette.strain
        case .calories: LivePalette.calories
        }
    }

    /// The unit block's colour where it is not the figure's own: a white figure's unit is the quiet grey (KM, AVG /KM), so the
    /// unit never competes with the number; every other metric's unit is in the metric's colour.
    static func unitColor(of metric: Metric) -> Color? {
        switch metric {
        case .distance, .pace, .speed: LivePalette.secondaryText
        default: nil
        }
    }

    /// Pace as drawn on the live screens: 6:13 reads 6′13″.
    static func paceDisplay(_ text: String) -> String {
        guard text != LiveWorkoutTiles.missing, let colon = text.firstIndex(of: ":") else { return text }
        return "\(text[..<colon])′\(text[text.index(after: colon)...])″"
    }

    /// - Parameter zoneWord: The zone the current heart rate is in ("Push"), which leads the heart-rate unit block.
    static func value(_ metric: Metric, input: LiveWorkoutTiles.Input, elapsed: TimeInterval, strain: LiveStrainState,
                      zoneWord: String? = nil, locale: Locale = .current) -> Value {
        let missing = LiveWorkoutTiles.missing
        // VoiceOver never reads a dash; a number that is not known is "No reading".
        let noReading = String(localized: "No reading")
        let name = Self.name(of: metric)
        switch metric {
        case .time:
            let text = LiveWorkoutTiles.elapsedText(elapsed)
            return Value(metric: metric, name: name, text: text, unit: [], micro: nil,
                         spoken: LiveWorkoutTiles.spokenElapsed(elapsed))
        case .distance:
            let text = LiveWorkoutTiles.distanceText(meters: input.distanceMeters, imperial: input.imperial, locale: locale)
            return Value(metric: metric, name: name, text: text, unit: [Units.distance(imperial: input.imperial)], micro: nil,
                         spoken: text == missing ? noReading : LiveWorkoutTiles.spokenDistance(text, imperial: input.imperial))
        case .pace:
            let raw = LiveWorkoutTiles.paceText(secPerKm: input.paceSecPerKm, imperial: input.imperial)
            return Value(metric: metric, name: name, text: paceDisplay(raw),
                         unit: [Units.average, Units.pace(imperial: input.imperial)], micro: nil,
                         spoken: raw == missing ? noReading
                            : WorkoutFormat.spokenPace(raw, system: input.imperial ? .imperial : .metric))
        case .speed:
            let text = LiveWorkoutTiles.speedText(secPerKm: input.paceSecPerKm, imperial: input.imperial, locale: locale)
            return Value(metric: metric, name: name, text: text,
                         unit: [Units.average, Units.speed(imperial: input.imperial)], micro: nil,
                         spoken: text == missing ? noReading : LiveWorkoutTiles.spokenSpeed(text, imperial: input.imperial))
        case .heartRate:
            let text = LiveWorkoutTiles.count(input.bpm, locale: locale)
            return Value(metric: metric, name: name, text: text,
                         unit: [zoneWord, Units.heartRate].compactMap { $0 }, micro: nil,
                         spoken: text == missing ? noReading : input.bpm.map(LiveWorkoutTiles.spokenHeartRate) ?? noReading)
        case .averageHeartRate:
            let text = LiveWorkoutTiles.count(input.averageHR > 0 ? input.averageHR : nil, locale: locale)
            return Value(metric: metric, name: name, text: text, unit: [Units.average, Units.heartRate], micro: nil,
                         spoken: text == missing ? noReading : LiveWorkoutTiles.spokenHeartRate(input.averageHR))
        case .calories:
            let text = LiveWorkoutTiles.count(input.calories, locale: locale)
            return Value(metric: metric, name: name, text: text, unit: [Units.energy], micro: nil,
                         spoken: text == missing ? noReading : input.calories.map { WorkoutFormat.spokenEnergy(Double($0)) } ?? noReading)
        case .strain:
            switch strain {
            case .scored(let stored):
                let text = StrainScale.formatted(stored, locale: locale)
                return Value(metric: metric, name: name, text: text, unit: [Units.strain], micro: nil, spoken: text)
            case .building(_, let coverage):
                let remaining = max(0, StrainScorerV2.minCoverageSeconds - coverage)
                let clock = String(format: "%d:%02d", remaining / 60, remaining % 60)
                return Value(metric: metric, name: name, text: missing, unit: [Units.strain],
                             micro: String(localized: "scores in \(clock)"), spoken: String(localized: "Strain scores in \(clock)"))
            }
        }
    }
}
