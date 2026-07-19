#if os(iOS)
import Foundation
import ActivityKit

struct WorkoutLiveActivityState {
    let sport: String
    let startedAt: Date
    let strain: Double?
    let strainBuilding: Bool
    let calories: Int?
    let hrTrace: [Int]
    let zoneSeconds: [Int]
}

/// Starts, updates, and ends the live-HR Live Activity. The activity appears on the Lock Screen and
/// in the Dynamic Island while the strap is bonded and streaming heart rate.
@MainActor
final class LiveActivityController {
    private var activity: Activity<NOOPActivityAttributes>?
    private var lastPush: Date = .distantPast
    /// Cached `ActivityAuthorizationInfo` — `update` runs at ~1 Hz off the live HR stream, and
    /// instantiating this system bridge per tick is needless allocation. ActivityKit's auth status
    /// only changes via Settings, so caching for the controller's lifetime is safe.
    private let authInfo = ActivityAuthorizationInfo()
    /// Synchronous gate against concurrent `Activity.request` calls. The `else` branch below is
    /// re-entered while the first request is still in flight (it hasn't assigned `self.activity`
    /// yet), so without this guard two close-together HR samples could both fire `Activity.request`
    /// and create duplicate Live Activities.
    private var isStarting = false
    private var isTransitioning = false
    private var lastModeWasWorkout: Bool?
    #if DEBUG
    private var component41QAMode = false
    #endif
    /// How long after the last push iOS may keep showing the activity as fresh. The activity is
    /// refreshed every ~2 s while streaming, so this never bites a live session; it auto-greys a
    /// frozen activity if the app is suspended/killed without an explicit end (a missed-tick safety net
    /// on top of the connected-driven end below).
    private static let staleAfter: TimeInterval = 120

    /// Drive the activity from the latest live values. Lazily starts when the strap is CONNECTED (the
    /// live link, not the sticky "paired" flag) and a heart rate is present; ends the moment the link
    /// drops. Throttled to ~once every 2 s so we stay well under the Live Activity update budget.
    func update(bpm: Int?, recovery: Int?, connected: Bool, effort: Double? = nil,
                workout: WorkoutLiveActivityState? = nil) {
        #if DEBUG
        guard !component41QAMode else { return }
        #endif
        guard authInfo.areActivitiesEnabled else { return }

        // Re-adopt an activity that outlived a previous app session. ActivityKit keeps Live Activities
        // alive across launches/relaunches, but a fresh controller starts with `activity == nil`, so
        // without recovering the handle here we can neither update nor END an already-showing activity
        // — which made the #336 opt-out a no-op (#341: toggle off, heart stays) and risked spawning a
        // duplicate on the start path below. Done on the HR tick rather than in `init` because
        // `Activity.activities` isn't reliably hydrated at the instant of process launch.
        if activity == nil { activity = Activity<NOOPActivityAttributes>.activities.first }

        // User opt-out (#336): if the in-app toggle is off, never start — and end any activity that's
        // already showing (the user just turned it off; this fires on the next ~1 Hz HR tick).
        guard UnitPrefs.liveActivityEnabled() else {
            if activity != nil { Task { await end() } }
            return
        }

        // End the moment the live link drops — `bonded` stays true across every disconnect (it means
        // "this strap is paired"), so keying off it left a frozen, fabricated "live" HR on the Lock
        // Screen / Dynamic Island indefinitely after the strap went out of range.
        if !connected {
            Task { await end() }
            return
        }
        guard bpm != nil else { return }

        let desiredMode = workout != nil
        if activity != nil, lastModeWasWorkout == nil { lastModeWasWorkout = desiredMode }
        if activity != nil, let lastModeWasWorkout, lastModeWasWorkout != desiredMode {
            guard !isTransitioning else { return }
            isTransitioning = true
            Task {
                await end()
                self.lastModeWasWorkout = desiredMode
                self.isTransitioning = false
                update(bpm: bpm, recovery: recovery, connected: connected,
                       effort: effort, workout: workout)
            }
            return
        }

        let state = NOOPActivityAttributes.ContentState(
            bpm: bpm, recovery: recovery, bonded: connected,
            effort: workout?.strain ?? effort,
            sport: workout?.sport, workoutStartedAt: workout?.startedAt,
            strainBuilding: workout?.strainBuilding, calories: workout?.calories,
            hrTrace: workout?.hrTrace, zoneSeconds: workout?.zoneSeconds)
        let staleDate = Date().addingTimeInterval(Self.staleAfter)

        if let activity {
            guard Date().timeIntervalSince(lastPush) > 2 else { return }
            lastPush = Date()
            Task { await activity.update(ActivityContent(state: state, staleDate: staleDate)) }
        } else {
            // Set the start gate SYNCHRONOUSLY before any await so a second `update` arriving on the
            // main actor while `Activity.request` is still in flight bails here instead of issuing a
            // second request. The 2-second throttle above only guards the update path.
            guard !isStarting else { return }
            isStarting = true
            do {
                activity = try Activity.request(
                    attributes: NOOPActivityAttributes(title: workout?.sport ?? String(localized: "Live HR")),
                    content: ActivityContent(state: state, staleDate: staleDate),
                    pushType: nil
                )
                lastPush = Date()
                lastModeWasWorkout = desiredMode
            } catch {
                activity = nil
            }
            isStarting = false
        }
    }

    func end() async {
        #if DEBUG
        // A disconnected-state end may already be queued when the simulator QA launch task starts.
        // Keep that stale task from immediately dismissing the proof activity; production builds do
        // not contain this mode or guard, so real disconnect/completion cleanup remains unchanged.
        guard !component41QAMode else { return }
        #endif
        // End every NOOP Live Activity, not just our cached handle — covers a straggler from a prior
        // session we never re-adopted (#341) and any rare duplicate. Iterating the live list is the
        // only way to reach activities this controller instance never started.
        for act in Activity<NOOPActivityAttributes>.activities {
            await act.end(nil, dismissalPolicy: .immediate)
        }
        self.activity = nil
        self.lastModeWasWorkout = nil
    }

    #if DEBUG
    /// Simulator-only ActivityKit proof. It exercises the real extension and OS presentation while
    /// remaining impossible to invoke in Release or on a user's normal launch path.
    func startComponent41QA() async {
        guard authInfo.areActivitiesEnabled else { return }
        component41QAMode = true
        for existing in Activity<NOOPActivityAttributes>.activities {
            await existing.end(nil, dismissalPolicy: .immediate)
        }
        let state = NOOPActivityAttributes.ContentState(
            bpm: 152, recovery: 78, bonded: true, effort: 6.8,
            sport: "Outdoor Run", workoutStartedAt: Date().addingTimeInterval(-2_734),
            strainBuilding: false, calories: 438,
            hrTrace: [88, 96, 108, 121, 115, 132, 146, 139, 152, 144, 158, 152],
            zoneSeconds: [180, 620, 1_180, 650, 104])
        do {
            activity = try Activity.request(
                attributes: NOOPActivityAttributes(title: "Outdoor Run"),
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(7_200)),
                pushType: nil)
            lastModeWasWorkout = true
        } catch {
            activity = nil
        }
    }
    #endif
}
#endif
