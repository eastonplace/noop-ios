import Foundation
import StrandDesign
import WhoopStore

// MARK: - The journey's summary: what it says, before anything is drawn
//
// The screen after End and a save, in the language of the live screen: the number the sport is about, large, and under it the
// others, each in its own colour with its unit beside it. The figures are the live screen's (`LiveWorkoutGlance.Value`), worked
// out from the saved row instead of the recorder, so a number reads the same on the way out as it did on the way through. A
// figure the workout has no value for is left out (never a dash), and the full screen with every number, curve and map is one
// tap away (Details). Plain values, tested without a view.

enum WorkoutSummary {
    /// One figure ready to draw.
    struct Figure: Equatable, Identifiable {
        let id: String
        let value: LiveWorkoutGlance.Value
        /// The zone of the reading, for the heart-rate figures: their colour.
        let zone: Int?
    }

    struct Figures: Equatable {
        /// The big number: the distance of a workout that covered ground, else how long it ran.
        let focus: Figure
        /// The others, in reading order, two to a row.
        let rest: [Figure]
    }

    /// - Parameters:
    ///   - row: The saved workout.
    ///   - strain: Whose strain the workout carries (`WorkoutHeroStrain`), for the strain figure and its band word.
    ///   - thresholds: The wearer's zones, for the colour of the heart-rate figures.
    static func figures(for row: WorkoutRow, strain: WorkoutHeroStrain, imperial: Bool, thresholds: HRZoneStyle.Thresholds,
                        locale: Locale = .current) -> Figures {
        typealias Glance = LiveWorkoutGlance
        let seconds = WorkoutFacts.activeSeconds(row) ?? 0
        let distance = max(0, row.distanceM ?? 0)
        let hasDistance = distance > 0
        let onFoot = WorkoutCatalog.isOnFoot(WorkoutSource.displaySport(row.sport))
        let secPerKm: Double? = hasDistance && seconds > 0 ? seconds / (distance / 1000) : nil
        let average = max(0, row.avgHr ?? 0)
        let peak = max(0, row.maxHr ?? 0)
        let kcal = row.energyKcal.map { Int($0.rounded()) }.flatMap { $0 > 0 ? $0 : nil }
        let input = LiveWorkoutTiles.Input(
            sport: row.sport, tracksRoute: hasDistance, distanceMeters: distance, paceSecPerKm: secPerKm, bpm: nil,
            calories: kcal, averageHR: average, peakHR: peak, imperial: imperial)
        func value(_ metric: Glance.Metric, strain: LiveStrainState = .building(readings: 0, coverageSeconds: 0)) -> Glance.Value {
            Glance.value(metric, input: input, elapsed: seconds, strain: strain, locale: locale)
        }
        func figure(_ metric: Glance.Metric, zone: Int? = nil) -> Figure {
            Figure(id: metric.rawValue, value: value(metric), zone: zone)
        }
        func zone(of bpm: Int) -> Int { thresholds.zone(for: Double(bpm)) }

        var rest: [Figure] = []
        if hasDistance {
            rest.append(figure(.time))
            let pace = figure(onFoot ? .pace : .speed)
            if !pace.value.isMissing { rest.append(pace) }
        }
        if average > 0 { rest.append(figure(.averageHeartRate, zone: zone(of: average))) }
        if let strainFigure = Self.strainFigure(for: row, strain: strain, input: input, elapsed: seconds, locale: locale) {
            rest.append(strainFigure)
        }
        if peak > 0 {
            rest.append(Figure(
                id: "maxHeartRate",
                value: Glance.Value(
                    metric: .heartRate, name: String(localized: "Max HR"), text: LiveWorkoutTiles.count(peak, locale: locale),
                    unit: [String(localized: "Max"), Glance.Units.heartRate], micro: nil,
                    spoken: LiveWorkoutTiles.spokenHeartRate(peak)),
                zone: zone(of: peak)))
        }
        if kcal != nil { rest.append(figure(.calories)) }
        return Figures(focus: hasDistance ? figure(.distance) : figure(.time), rest: rest)
    }

    /// The strain, with its band word ("Moderate") where the unit's small print goes, or "WHOOP" for a number WHOOP scored and
    /// the workout arrived with. nil when nobody scored the workout.
    private static func strainFigure(for row: WorkoutRow, strain: WorkoutHeroStrain, input: LiveWorkoutTiles.Input,
                                     elapsed: TimeInterval, locale: Locale) -> Figure? {
        guard strain != .unscored, let shown = StrainResolver.workoutStrainForDisplay(row) else { return nil }
        let base = LiveWorkoutGlance.value(.strain, input: input, elapsed: elapsed,
                                           strain: .scored(storedValue: shown.storedValue), locale: locale)
        let note: String?
        switch strain {
        case .noop: note = strain.bandTitle
        case .whoop: note = String(localized: "WHOOP")
        case .unscored: note = nil
        }
        return Figure(
            id: LiveWorkoutGlance.Metric.strain.rawValue,
            value: LiveWorkoutGlance.Value(
                metric: .strain, name: base.name, text: base.text, unit: base.unit, micro: note,
                spoken: note.map { "\(base.text), \($0)" } ?? base.text),
            zone: nil)
    }

    /// The zone the workout spent the most time in (the first, on a tie), or nil with no time in any: the bar the zone row lights.
    static func dominantZone(of seconds: [Int]) -> Int? {
        guard let most = seconds.max(), most > 0 else { return nil }
        return seconds.firstIndex(of: most)
    }

    /// "Saved", and when: the clock time the workout ended.
    static func savedClock(for row: WorkoutRow) -> String {
        AppClock.hourMinute(Date(timeIntervalSince1970: TimeInterval(max(row.endTs, row.startTs))))
    }
}
