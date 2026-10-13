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
    enum Verdict: Equatable { case allowed, dismissedByPerson, backoff, exhausted }

    static let firstBackoff: TimeInterval = 30
    static let maxRestartsPerWorkout = 4
    /// An activity that showed this long before it was removed had rendered, so a removal with no end before it is a
    /// person's swipe. Removed sooner, it is the system's (a render that never finished).
    static let renderedAfter: TimeInterval = 20

    private(set) var systemEnds = 0
    private(set) var nextRequestAt: Date?
    private(set) var dismissedByPerson = false
    private var lastWorkoutIsActive: Bool?

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
            let doublings = min(systemEnds - 1, 10)
            nextRequestAt = now.addingTimeInterval(Self.firstBackoff * Double(1 << doublings))
        }
    }

    /// Whether a new activity may be requested now.
    func verdict(now: Date) -> Verdict {
        if dismissedByPerson { return .dismissedByPerson }
        if systemEnds > Self.maxRestartsPerWorkout { return .exhausted }
        if let nextRequestAt, now < nextRequestAt { return .backoff }
        return .allowed
    }
}
#endif
