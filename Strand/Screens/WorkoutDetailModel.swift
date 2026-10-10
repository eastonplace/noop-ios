import Foundation
import StrandDesign
import WhoopStore

// MARK: - Workout detail: pure presentation rules
//
// What the workout summary decides before anything is drawn: whose strain the hero shows, which numbers the tiles
// carry, what the heart-rate curve spans and where a touch on it lands. Plain values, tested without a view.

// MARK: Hero strain

/// The summary's headline: the session's Strain in one of three honest states.
///
/// Display only. The comparison against the person's usual uses NOOP's own scores alone (`canonicalWorkout`), and an
/// imported WHOOP number is shown as WHOOP's, never as NOOP's.
enum WorkoutHeroStrain: Equatable {
    /// NOOP scored the session. `display` is on the 0...21 scale; `comparedToUsual` is the difference from the average
    /// of the person's other NOOP-scored sessions of the same sport, in display units, when there are any.
    case noop(display: Double, comparedToUsual: Double?)
    /// WHOOP scored the session and the number was imported with it. `display` is on the 0...21 scale.
    case whoop(display: Double)
    /// Nobody scored it: a manual entry, an Apple Health import, a session with no heart rate.
    case unscored

    /// `usualStored` is the average stored (0...100) strain of the person's other NOOP-scored sessions of this sport.
    static func make(for row: WorkoutRow, usualStored: Double?) -> WorkoutHeroStrain {
        guard let shown = StrainResolver.workoutStrainForDisplay(row) else { return .unscored }
        let display = StrainScale.displayValue(fromStored: shown.storedValue)
        switch shown.provenance {
        case .noop:
            let delta = usualStored.map { display - StrainScale.displayValue(fromStored: $0) }
            return .noop(display: display, comparedToUsual: delta)
        case .whoop:
            return .whoop(display: display)
        }
    }

    /// The Light / Moderate / High / All Out word for a scored session.
    var bandTitle: String? {
        switch self {
        // Banded on the number as it is shown (one decimal), so a "10.0" is never called Light.
        case .noop(let display, _), .whoop(let display): return StrainScale.band((display * 10).rounded() / 10).title
        case .unscored: return nil
        }
    }
}

// MARK: Tiles

/// One number on the summary's overview, ready to draw.
struct WorkoutDetailTile: Equatable, Identifiable {
    enum Kind: Equatable { case distance, time, pace, speed, averageHR, maxHR, calories }

    let kind: Kind
    /// The value as the tile reads it ("5.8 km", "34m", "5:49 /km", "157 bpm"), or "—" when the session has none.
    let value: String
    /// What VoiceOver reads for the value: durations and pace written out ("34 minutes"), "Not recorded" for "—".
    let spokenValue: String

    var id: Kind { kind }

    init(kind: Kind, value: String, spokenValue: String? = nil) {
        self.kind = kind
        self.value = value
        self.spokenValue = value == WidgetMetrics.missingValue ? String(localized: "Not recorded") : (spokenValue ?? value)
    }
}

enum WorkoutDetailTiles {
    /// The overview's tiles, in reading order: how far, how long and how fast when the session covered ground, then
    /// the heart and the energy. A tile the session has no value for still shows, as "—", so two sessions of one sport
    /// always lay out alike.
    static func make(for row: WorkoutRow, unitSystem: UnitSystem) -> [WorkoutDetailTile] {
        let missing = WidgetMetrics.missingValue
        var tiles: [WorkoutDetailTile] = []

        let hasDistance = (row.distanceM ?? 0) > 0
        if let distance = row.distanceM, distance > 0 {
            tiles.append(.init(kind: .distance, value: UnitFormatter.distanceFromMeters(distance, system: unitSystem)))
        }
        let seconds = WorkoutFacts.activeSeconds(row)
        tiles.append(.init(kind: .time, value: seconds.map(WorkoutFormat.duration) ?? missing,
                           spokenValue: seconds.map(WorkoutFormat.spokenDuration)))
        if hasDistance {
            // On-foot sessions are paced per kilometre or mile; a ride, a row or a swim is read in speed.
            if WorkoutCatalog.isOnFoot(WorkoutSource.displaySport(row.sport)) {
                if let pace = WorkoutPace.perUnit(row, system: unitSystem) {
                    tiles.append(.init(kind: .pace, value: WorkoutFormat.pace(pace, system: unitSystem),
                                       spokenValue: WorkoutFormat.spokenPace(pace, system: unitSystem)))
                }
            } else if let speed = WorkoutSpeed.perHour(row, system: unitSystem) {
                tiles.append(.init(kind: .speed, value: WorkoutSpeed.text(speed, system: unitSystem)))
            }
        }
        tiles.append(.init(kind: .averageHR, value: row.avgHr.map { String(localized: "\($0) bpm") } ?? missing,
                           spokenValue: row.avgHr.map { String(localized: "\($0) beats per minute") }))
        tiles.append(.init(kind: .maxHR, value: row.maxHr.map { String(localized: "\($0) bpm") } ?? missing,
                           spokenValue: row.maxHr.map { String(localized: "\($0) beats per minute") }))
        tiles.append(.init(kind: .calories, value: row.energyKcal.map(WorkoutFormat.energy) ?? missing,
                           spokenValue: row.energyKcal.map(WorkoutFormat.spokenEnergy)))
        return tiles
    }
}

enum WorkoutSpeed {
    /// Kilometres (or miles) per hour for a session with a distance and a duration, or nil when either is missing or
    /// the result is not a plausible speed for a person.
    static func perHour(_ row: WorkoutRow, system: UnitSystem) -> Double? {
        guard let distance = row.distanceM, distance > 0 else { return nil }
        let seconds = row.durationS ?? Double(row.endTs - row.startTs)
        guard seconds > 0 else { return nil }
        let unitMeters = system == .imperial ? 1609.344 : 1000
        let speed = (distance / unitMeters) / (seconds / 3_600)
        return speed > 0 && speed < 200 ? speed : nil
    }

    /// "25.4 km/h" or "15.8 mph", the number in the person's own number format.
    static func text(_ speed: Double, system: UnitSystem) -> String {
        let number = speed.formatted(.number.precision(.fractionLength(1)))
        return system == .imperial ? String(localized: "\(number) mph") : String(localized: "\(number) km/h")
    }
}

// MARK: Heart-rate curve

/// The session's heart rate as the curve draws it: bucketed readings against seconds into the session, the average,
/// peak and low the rails mark, and the span the axis covers.
struct WorkoutHeartRateSeries: Equatable {
    struct Sample: Equatable {
        /// Seconds from the start of the session.
        let seconds: Double
        let bpm: Double
    }

    let samples: [Sample]
    /// Length of the session window, in seconds.
    let duration: Double
    let average: Double
    let peak: Double
    let low: Double
    /// The y span of the plot: a little room under the low and over the peak.
    let axis: ClosedRange<Double>

    /// nil when there are fewer than two readings, which is not a curve. `recordedAverage` and `recordedPeak` are the
    /// session's own stored figures (a bucket mean can never reach the true peak); the series falls back to its own.
    init?(samples: [Sample], duration: Double, recordedAverage: Int?, recordedPeak: Int?) {
        let ordered = samples.filter { $0.bpm.isFinite && $0.seconds.isFinite }.sorted { $0.seconds < $1.seconds }
        guard ordered.count >= 2, duration > 0 else { return nil }
        let values = ordered.map(\.bpm)
        let low = values.min() ?? 0
        let high = values.max() ?? 0
        self.samples = ordered
        self.duration = duration
        self.average = recordedAverage.map(Double.init) ?? values.reduce(0, +) / Double(values.count)
        self.peak = recordedPeak.map { max(Double($0), high) } ?? high
        self.low = low
        self.axis = max(0, low - 8)...(max(self.peak, high) + 8)
    }

    /// The reading closest to a position across the plot, 0 (the start) to 1 (the end).
    func index(atFraction fraction: Double) -> Int {
        let target = min(max(fraction, 0), 1) * duration
        var best = 0
        var bestDistance = Double.infinity
        for (index, sample) in samples.enumerated() {
            let distance = abs(sample.seconds - target)
            if distance < bestDistance { best = index; bestDistance = distance }
        }
        return best
    }

    /// Seconds for each of the (at most four) time labels under the plot: the start, the end and evenly between.
    func labelTimes(count: Int = WidgetMetrics.maxXAxisLabels) -> [Double] {
        let steps = max(1, min(count, WidgetMetrics.maxXAxisLabels) - 1)
        return (0...steps).map { duration * Double($0) / Double(steps) }
    }

    /// 0...1 up the plot for a reading's value.
    func unit(forBPM bpm: Double) -> Double {
        let span = axis.upperBound - axis.lowerBound
        guard span > 0 else { return 0.5 }
        return min(max((bpm - axis.lowerBound) / span, 0), 1)
    }
}

enum WorkoutElapsed {
    /// "5:49" for under an hour, "1:05:00" from an hour on: time into a session, in the person's digits.
    static func text(_ seconds: Double) -> String {
        let whole = Int(max(0, seconds).rounded())
        if whole >= 3_600 {
            return Duration.seconds(whole).formatted(.time(pattern: .hourMinuteSecond))
        }
        return Duration.seconds(whole).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 1)))
    }
}

// MARK: Edited average

enum WorkoutDetailRules {
    /// Whether the average heart rate on a session was edited away from what its recording says: the row carries a
    /// captured strain or zone split (so the curve, the zones and the strain come from a real recording, not from the
    /// typed number) and its average differs from the trace's own mean by more than rounding and bucketing explain.
    static func averageWasEdited(_ row: WorkoutRow, traceMean: Double) -> Bool {
        guard let average = row.avgHr,
              StrainResolver.canonicalWorkout(row) != nil || row.zonesJSON != nil
        else { return false }
        return abs(Double(average) - traceMean) > 3
    }
}
