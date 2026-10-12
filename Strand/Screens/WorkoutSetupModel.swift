import Foundation
import StrandDesign
import WhoopStore

// MARK: - What the setup page decides
//
// Plain values and rules behind the setup page, so they are tested without a view: what Start says, what the Today row
// says about the day's strain target, and the "last time" line.

/// What the pinned Start button says and what is written under it.
struct WorkoutStartPresentation: Equatable {
    enum Label: Equatable {
        /// "Start Run".
        case start(title: String)
        /// "Start Run without route": a route sport whose location is refused.
        case withoutRoute(title: String)
        /// "Start without heart rate": nothing will be recorded that could be saved.
        case withoutHeartRate
    }

    enum Caption: Equatable {
        /// "Hold Start to skip the countdown."
        case holdToSkip
        /// "Without heart rate there is nothing to save for this sport. You can still discard it."
        case nothingToSave
        case none
    }

    let label: Label
    let caption: Caption

    /// - Parameters:
    ///   - isRouteSport: The sport records a route (a run, a ride, a hike).
    ///   - gps: What location allows right now; ignored for a sport with no route.
    ///   - strapConnected: A heart-rate strap is connected.
    ///   - countdownOn: The countdown is on, so holding Start skips it.
    static func make(sportTitle: String, isRouteSport: Bool, gps: GpsReadiness, strapConnected: Bool,
                     countdownOn: Bool) -> WorkoutStartPresentation {
        let routeAvailable = isRouteSport && gps.canRecordRoute
        let holdCaption: Caption = countdownOn ? .holdToSkip : .none
        if !routeAvailable && !strapConnected {
            // Neither heart rate nor a route: the workout would have nothing to save. Start is still allowed (it can be
            // discarded), but the button and the line under it say so.
            return WorkoutStartPresentation(label: .withoutHeartRate, caption: .nothingToSave)
        }
        if isRouteSport && !gps.canRecordRoute {
            return WorkoutStartPresentation(label: .withoutRoute(title: sportTitle), caption: holdCaption)
        }
        return WorkoutStartPresentation(label: .start(title: sportTitle), caption: holdCaption)
    }

    var labelText: String {
        switch label {
        case .start(let title): String(localized: "Start \(title)")
        case .withoutRoute(let title): String(localized: "Start \(title) without route")
        case .withoutHeartRate: String(localized: "Start without heart rate")
        }
    }

    var captionText: String? {
        switch caption {
        case .holdToSkip: String(localized: "Hold Start to skip the countdown.")
        case .nothingToSave:
            String(localized: "Without heart rate there is nothing to save for this sport. You can still discard it.")
        case .none: nil
        }
    }
}

/// The Today row: where the day's strain sits against the target recovery sets.
enum WorkoutReadinessToday: Equatable {
    /// "Recovery 72 · target 14–18 · so far 6.1" (no "so far" until the day has a strain).
    case target(recovery: Int, range: ClosedRange<Int>, soFar: Double?)
    /// "Already 15.1 · above today's 10–14": the day is past its target already; a warning.
    case above(soFar: Double, range: ClosedRange<Int>)
    /// "No target yet · recovery isn't scored".
    case unscored

    /// - Parameters:
    ///   - recovery: Today's recovery score, if scored.
    ///   - soFar: The day's strain so far, as displayed (0–21), if it has one.
    @MainActor static func make(recovery: Double?, soFar: Double?) -> WorkoutReadinessToday {
        guard let recovery, recovery.isFinite, let range = CoupledView.optimalStrainRange(recovery: recovery) else {
            return .unscored
        }
        if let soFar, soFar.isFinite,
           case .above = StrainTargetGuidance.make(value: soFar, target: Double(range.lowerBound)...Double(range.upperBound)) {
            return .above(soFar: soFar, range: range)
        }
        return .target(recovery: Int(recovery.rounded()), range: range, soFar: soFar.flatMap { $0.isFinite ? $0 : nil })
    }

    var isWarning: Bool {
        if case .above = self { return true }
        return false
    }

    /// The row's words, with the strain written to one decimal like the rest of the app's strain, as the separate facts the
    /// row stacks at the accessibility sizes: "Recovery 72", "target 14–18", "so far 6.1".
    func parts() -> [String] {
        func one(_ value: Double) -> String { DrillInFormat.number(value, fractionDigits: 1) }
        let separator = " · "
        switch self {
        case .target(let recovery, let range, let soFar):
            let base = String(localized: "Recovery \(recovery) · target \(range.lowerBound)–\(range.upperBound)")
                .components(separatedBy: separator)
            guard let soFar else { return base }
            return base + [String(localized: "so far \(one(soFar))")]
        case .above(let soFar, let range):
            return String(localized: "Already \(one(soFar)) · above today's \(range.lowerBound)–\(range.upperBound)")
                .components(separatedBy: separator)
        case .unscored:
            return String(localized: "No target yet · recovery isn't scored").components(separatedBy: separator)
        }
    }

    /// The same words on one line.
    func text() -> String { parts().joined(separator: " · ") }
}

/// "Last Run · 5.8 km · 5:49 /km · Yesterday": the newest workout in the chosen sport, in one line.
enum WorkoutSetupLastTime {
    /// The newest row of `sport`, if there is one. `rows` is newest first.
    static func newest(of sport: String, in rows: [WorkoutRow]) -> WorkoutRow? {
        rows.first { $0.sport.caseInsensitiveCompare(sport) == .orderedSame }
    }

    /// The facts of the line, in order: what it was, how far and how fast (or how long), and when.
    static func facts(for row: WorkoutRow, title: String, system: UnitSystem, now: Date = Date(),
                      calendar: Calendar = .current) -> [String] {
        var facts = [String(localized: "Last \(title)")]
        let seconds = row.durationS ?? Double(max(0, row.endTs - row.startTs))
        if let meters = row.distanceM, meters > 0 {
            facts.append(UnitFormatter.distanceFromMeters(meters, system: system))
            if seconds > 0 {
                let secPerKm = seconds / (meters / 1000)
                let text = LiveWorkoutTiles.paceText(secPerKm: secPerKm, imperial: system == .imperial)
                if text != LiveWorkoutTiles.missing { facts.append(WorkoutFormat.pace(text, system: system)) }
            }
        } else if seconds > 0 {
            facts.append(WorkoutFormat.duration(seconds))
        }
        facts.append(WorkoutFormat.day(Date(timeIntervalSince1970: TimeInterval(row.startTs)), now: now, calendar: calendar))
        return facts
    }

    /// The same facts as VoiceOver says them: units as words ("5.8 kilometers", "5:49 per kilometer"), never the drawn "km" or
    /// "/km" read out letter by letter.
    static func spokenFacts(for row: WorkoutRow, title: String, system: UnitSystem, now: Date = Date(),
                            calendar: Calendar = .current, locale: Locale = .current) -> [String] {
        var facts = [String(localized: "Last \(title)")]
        let seconds = row.durationS ?? Double(max(0, row.endTs - row.startTs))
        if let meters = row.distanceM, meters > 0 {
            let imperial = system == .imperial
            let measurement = Measurement(value: meters, unit: UnitLength.meters)
            facts.append((imperial ? measurement.converted(to: .miles) : measurement.converted(to: .kilometers))
                .formatted(.measurement(width: .wide, usage: .asProvided,
                                        numberFormatStyle: .number.precision(.fractionLength(1)).locale(locale))
                    .locale(locale)))
            if seconds > 0 {
                let secPerKm = seconds / (meters / 1000)
                let text = LiveWorkoutTiles.paceText(secPerKm: secPerKm, imperial: imperial)
                if text != LiveWorkoutTiles.missing { facts.append(WorkoutFormat.spokenPace(text, system: system)) }
            }
        } else if seconds > 0 {
            facts.append(WorkoutFormat.spokenDuration(seconds))
        }
        facts.append(WorkoutFormat.day(Date(timeIntervalSince1970: TimeInterval(row.startTs)), now: now, calendar: calendar))
        return facts
    }
}

extension WorkoutPrefs {
    /// "Countdown": a three-second count before a workout starts, on by default; holding Start skips it.
    static let countdownOnKey = "workoutCountdownOn"
    static let countdownOnDefault = true
}
