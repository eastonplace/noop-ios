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

    /// ActivityKit refused the request (from the background, among other reasons). It waits like a system end and counts
    /// toward the same cap, so a refused request is not repeated on every drive.
    mutating func noteRequestFailed(now: Date) {
        failedRequests += 1
        backOff(now: now)
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
