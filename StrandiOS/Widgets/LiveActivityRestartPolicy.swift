#if os(iOS)
import Foundation

/// What the controller may do after its activity went away without the app ending it.
///
/// The system ends an activity it cannot render, one left stale, or one past its time limit; a person swipes one away.
/// The controller used to keep the dead `Activity` and update it for the rest of the workout, so the Lock Screen stayed
/// empty. The reference is now dropped. After a system end the next drive may ask again, spaced by a doubling backoff and
/// capped per workout, so an activity the system keeps refusing is not requested every second. After a person's
/// dismissal nothing is requested until the next workout starts: they asked for it to go.
struct LiveActivityRestartPolicy: Equatable {
    /// How the activity went: `ended` (it no longer updates, and may still be on screen) or `dismissed` (removed).
    enum Disappearance: String, Equatable { case ended, dismissed }
    enum Cause: String, Equatable { case system, person }
    enum Verdict: Equatable { case allowed, dismissedByPerson, backoff, exhausted, waitingForForeground }

    static let firstBackoff: TimeInterval = 30
    /// System ends and refused requests together, per workout.
    static let maxRestartsPerWorkout = 4
    /// An activity that showed this long before it was removed had rendered, so a removal with no end before it is a
    /// person's swipe. Removed sooner, it is the system's (a render that never finished).
    static let renderedAfter: TimeInterval = 20

    private(set) var systemEnds = 0
    private(set) var failedRequests = 0
    private(set) var nextRequestAt: Date?
    private(set) var dismissedByPerson = false
    private var lastWorkoutIsActive: Bool?

    /// What counts toward the cap and the backoff.
    var setbacks: Int { systemEnds + failedRequests }

    /// `dismissed` can come from a person or the system. It is the system's when an `ended` came first (observed, or read
    /// on a drive), or when the activity was removed before it had shown for `renderedAfter`; otherwise a person's.
    static func cause(of disappearance: Disappearance, endObserved: Bool, liveFor: TimeInterval) -> Cause {
        if disappearance == .ended || endObserved { return .system }
        return liveFor >= renderedAfter ? .person : .system
    }

    /// How long the activity showed before it went: from when it started showing to when the state observer saw it
    /// dismissed, or, when the observer missed that, to the last drive that found it showing.
    static func liveFor(since: Date, dismissedSeenAt: Date?, lastSeenLive: Date?) -> TimeInterval {
        max(0, (dismissedSeenAt ?? lastSeenLive ?? since).timeIntervalSince(since))
    }

    /// Every drive says whether a workout is active. The first workout drive after one without a workout starts a new
    /// workout, and the dismissal and the restart budget go with the old one.
    mutating func noteDrive(workoutIsActive: Bool) {
        if workoutIsActive, lastWorkoutIsActive == false {
            systemEnds = 0
            failedRequests = 0
            nextRequestAt = nil
            dismissedByPerson = false
        }
        lastWorkoutIsActive = workoutIsActive
    }

    mutating func noteGone(_ cause: Cause, now: Date) {
        switch cause {
        case .person:
            dismissedByPerson = true
        case .system:
            systemEnds += 1
            backOff(now: now)
        }
    }

    /// The app ended the heart-rate card itself (the strap disconnected, the toggle went off, a workout replaced it). The
    /// next card is a new one, so its setbacks and backoff go: the cap limits a render that keeps failing, not how long
    /// the heart-rate card may live across a day without a workout. A person's dismissal still holds until a workout.
    mutating func notePassiveCardEndedByApp() {
        systemEnds = 0
        failedRequests = 0
        nextRequestAt = nil
    }

    /// ActivityKit refused the request. It counts toward the same cap as a system end, so it is not repeated on every
    /// drive. Refused with the app in front, it also waits the backoff. Refused while the app was not in front (the
    /// usual reason), only the foreground gate applies: the first drive with the app in front asks again at once.
    mutating func noteRequestFailed(now: Date, wasForeground: Bool) {
        failedRequests += 1
        if wasForeground { backOff(now: now) }
    }

    private mutating func backOff(now: Date) {
        let doublings = min(max(setbacks - 1, 0), 10)
        nextRequestAt = now.addingTimeInterval(Self.firstBackoff * Double(1 << doublings))
    }

    /// Whether a new activity may be requested now. After a setback only a drive with the app in front asks again:
    /// ActivityKit refuses a request from the background, so asking then would only repeat the refusal.
    func verdict(now: Date, isForeground: Bool) -> Verdict {
        if dismissedByPerson { return .dismissedByPerson }
        if setbacks > Self.maxRestartsPerWorkout { return .exhausted }
        if setbacks > 0, !isForeground { return .waitingForForeground }
        if let nextRequestAt, now < nextRequestAt { return .backoff }
        return .allowed
    }

    /// The activities the system still lists when this process holds none: the first one still showing is adopted, and
    /// every `ended` one (left frozen on the Lock Screen by an earlier process) is ended, so the one this process shows
    /// does not appear beside it. `dismissed` ones are already gone.
    static func leftovers(_ states: [Disappearance?]) -> (adopt: Int?, end: [Int]) {
        (states.firstIndex { $0 == nil }, states.indices.filter { states[$0] == .ended })
    }
}
#endif
