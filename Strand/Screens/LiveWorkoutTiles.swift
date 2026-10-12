import Foundation

/// What the live workout screen puts in its tiles, worked out from plain values so the rules can be tested without a view.
///
/// A tile that does not apply to the sport is left out rather than shown empty (an indoor session has no distance), and a
/// tile whose number is not known yet reads "—", never "0": a pace of 0:00 or a distance of 0.00 would be a claim about
/// the run, not a gap in it.
enum LiveWorkoutTiles {
    enum Kind: String, Equatable, Sendable {
        case distance, pace, speed, heartRate, energy, averageHeartRate, peakHeartRate
    }

    struct Tile: Equatable, Identifiable, Sendable {
        let kind: Kind
        /// The number as shown, or `LiveWorkoutTiles.missing` while there is none.
        let value: String
        /// Shown muted beside the number; nil when the value is missing.
        let unit: String?
        var id: Kind { kind }
        var isMissing: Bool { value == LiveWorkoutTiles.missing }
    }

    struct Input: Equatable, Sendable {
        var sport: String
        /// A route is being recorded for this workout, so distance and pace mean something.
        var tracksRoute: Bool
        var distanceMeters: Double
        /// Average pace so far in seconds per kilometre, from the recorder.
        var paceSecPerKm: Double?
        var bpm: Int?
        var calories: Int?
        var averageHR: Int
        var peakHR: Int
        var imperial: Bool

        init(sport: String, tracksRoute: Bool, distanceMeters: Double = 0, paceSecPerKm: Double? = nil, bpm: Int? = nil,
             calories: Int? = nil, averageHR: Int = 0, peakHR: Int = 0, imperial: Bool = false) {
            self.sport = sport
            self.tracksRoute = tracksRoute
            self.distanceMeters = distanceMeters
            self.paceSecPerKm = paceSecPerKm
            self.bpm = bpm
            self.calories = calories
            self.averageHR = averageHR
            self.peakHR = peakHR
            self.imperial = imperial
        }
    }

    static let missing = "—"

    /// The timer's text: "34:12", or "1:34:12" once an hour has run.
    static func elapsedText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600, minutes = total % 3600 / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    /// Whether a tile's number is one the wearer should no longer read as live. A stale number keeps showing, quieter:
    /// the last reading is better than a gap, but it is never drawn at full strength as if it were current. Totals and
    /// averages are not live readings, so they are never stale.
    static func isStale(_ kind: Kind, signals: LiveWorkoutSignals.Snapshot) -> Bool {
        switch kind {
        case .heartRate: signals.heartRateIsStale
        case .pace, .speed: signals.paceIsStale
        case .distance, .energy, .averageHeartRate, .peakHeartRate: false
        }
    }

    /// What VoiceOver reads for the timer: "34 minutes, 12 seconds".
    static func spokenElapsed(_ seconds: TimeInterval) -> String {
        Duration.seconds(Int(seconds.rounded())).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }

    /// Four tiles, in reading order. A recorded route leads with distance and pace (speed for a ride); a session without
    /// one leads with heart rate and carries its average and peak instead.
    static func tiles(for input: Input, locale: Locale = .current) -> [Tile] {
        let heart = Tile(kind: .heartRate, value: count(input.bpm, locale: locale), unit: unit("bpm", input.bpm))
        let energy = Tile(kind: .energy, value: count(input.calories, locale: locale), unit: unit("kcal", input.calories))
        guard input.tracksRoute else {
            return [
                heart,
                energy,
                Tile(kind: .averageHeartRate, value: count(positive(input.averageHR), locale: locale),
                     unit: unit("bpm", positive(input.averageHR))),
                Tile(kind: .peakHeartRate, value: count(positive(input.peakHR), locale: locale),
                     unit: unit("bpm", positive(input.peakHR))),
            ]
        }
        let distance = distanceText(meters: input.distanceMeters, imperial: input.imperial, locale: locale)
        let distanceTile = Tile(kind: .distance, value: distance,
                                unit: distance == missing ? nil : (input.imperial ? "mi" : "km"))
        let second: Tile
        if usesSpeed(sport: input.sport) {
            let speed = speedText(secPerKm: input.paceSecPerKm, imperial: input.imperial, locale: locale)
            second = Tile(kind: .speed, value: speed, unit: speed == missing ? nil : (input.imperial ? "mph" : "km/h"))
        } else {
            let pace = paceText(secPerKm: input.paceSecPerKm, imperial: input.imperial)
            second = Tile(kind: .pace, value: pace, unit: pace == missing ? nil : (input.imperial ? "/mi" : "/km"))
        }
        return [distanceTile, second, heart, energy]
    }

    /// A ride is read as a speed, everything else a route can record as a pace.
    static func usesSpeed(sport: String) -> Bool {
        sport.localizedCaseInsensitiveContains("cycl")
    }

    static func distanceText(meters: Double, imperial: Bool, locale: Locale = .current) -> String {
        guard meters.isFinite, meters > 0 else { return missing }
        let amount = imperial ? meters / 1609.344 : meters / 1000
        return amount.formatted(.number.precision(.fractionLength(2)).locale(locale))
    }

    /// "6:13" for 373 seconds per kilometre. A pace slower than an hour per unit is a standstill, not a pace.
    static func paceText(secPerKm: Double?, imperial: Bool) -> String {
        guard let secPerKm, secPerKm.isFinite, secPerKm > 0 else { return missing }
        let seconds = Int((imperial ? secPerKm * 1.609344 : secPerKm).rounded())
        guard seconds > 0, seconds < 3600 else { return missing }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func speedText(secPerKm: Double?, imperial: Bool, locale: Locale = .current) -> String {
        guard let secPerKm, secPerKm.isFinite, secPerKm > 0 else { return missing }
        let perHour = 3600 / secPerKm
        let speed = imperial ? perHour / 1.609344 : perHour
        guard speed >= 0.1 else { return missing }
        return speed.formatted(.number.precision(.fractionLength(1)).locale(locale))
    }

    private static func positive(_ value: Int) -> Int? { value > 0 ? value : nil }

    private static func count(_ value: Int?, locale: Locale) -> String {
        guard let value, value > 0 else { return missing }
        return value.formatted(.number.locale(locale))
    }

    private static func unit(_ unit: String, _ value: Int?) -> String? {
        guard let value, value > 0 else { return nil }
        return unit
    }
}

/// When the screen tells the wearer a signal has gone quiet.
enum LiveWorkoutSignals {
    /// Both live signals at one moment, read once so the pills, the tiles and the zone rail never disagree about whether
    /// a number is live.
    struct Snapshot: Equatable {
        var heartRateIsStale = false
        /// nil when the workout records no route.
        var gps: GpsWorkoutRecorder.SignalState?

        /// The pace or speed is worked out from GPS fixes that have stopped arriving.
        var paceIsStale: Bool { gps == .lost }
    }

    /// A strap normally reports every second or two; this much silence is worth saying so.
    static let heartRatePatience: TimeInterval = 15

    enum Notice: Equatable, Sendable {
        case heartRate
        case gpsSearching
        case gpsWeak
        case gpsLost
    }

    /// Whether the heart-rate link has gone quiet. A paused workout is never stale: it is not waiting for anything,
    /// and the last reading is exactly what it should still be showing. Neither is one whose finish is pending
    /// (`isEnding`): it has stopped counting, no reading is being taken for it (the strap may be streaming fine), and
    /// "no signal" next to "Ending" would be a warning about something that is not wrong.
    static func heartRateIsStale(lastReadingAt: Date?, workoutStart: Date, isPaused: Bool, isEnding: Bool = false,
                                 now: Date, patience: TimeInterval = heartRatePatience) -> Bool {
        guard !isPaused, !isEnding else { return false }
        return now.timeIntervalSince(lastReadingAt ?? workoutStart) > patience
    }

    /// The notices to show, heart rate first. `gps` is nil when the workout records no route.
    static func notices(heartRateIsStale: Bool, gps: GpsWorkoutRecorder.SignalState?) -> [Notice] {
        var notices: [Notice] = []
        if heartRateIsStale { notices.append(.heartRate) }
        switch gps {
        case .searching: notices.append(.gpsSearching)
        case .weak: notices.append(.gpsWeak)
        case .lost: notices.append(.gpsLost)
        case .ok, .paused, .notRecording, nil: break
        }
        return notices
    }
}
