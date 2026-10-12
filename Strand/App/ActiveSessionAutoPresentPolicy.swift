import Foundation

/// Decides when the app shell re-presents an in-flight run or lift on its own, so relaunching NOOP (or
/// unlocking a phone that was locked mid-workout) lands the user back in the workout instead of on Today
/// with a "Return to workout" card to find and tap. Pure value type: the shell feeds it a `Context` at each
/// edge and presents whatever `Target` comes back.
///
/// Rules, in order:
///  - One chance per foreground session. A session starts at launch and again each time the scene returns
///    from `.background` (a lock, an app switch). A brief `.inactive` blip (Control Center, a permission
///    prompt) is not a new session. If the user dismisses the workout, nothing re-presents it until the next
///    session, so a deliberate dismissal is never fought.
///  - Never stack: if any workout screen is already visible, do nothing. If another modal is up (a shell
///    sheet, "What's New", the onboarding or terms gate) wait for it instead: remember what was blocked and
///    present it once that modal is gone, unless the workout ended or was opened by hand in the meantime.
///  - A run wins over a lift. The two cannot normally coexist (starting one refuses while the other is
///    active), but a corrupt restore must not present both.
///  - A lift session that finishes restoring after the foreground edge already ran gets one late chance,
///    unless something was presented already this session.
struct ActiveSessionAutoPresentPolicy: Equatable {
    enum Target: Equatable {
        case run
        case lift
    }

    struct Context: Equatable {
        var hasActiveRun: Bool
        var hasActiveLift: Bool
        /// A live run or lift screen is on screen right now, whichever view presented it.
        var workoutSurfaceVisible: Bool
        /// Another modal is up (quick actions, Devices, a routed pillar sheet, "What's New", the onboarding or
        /// terms gate, or a screen's own sheet), so presenting would stack on top of it or have to dismiss it.
        var otherPresentationActive: Bool
    }

    /// True until the first foreground edge of the current session has been evaluated.
    private var awaitingForegroundEdge = true
    private var presentedThisForeground = false
    /// What a blocking modal kept us from presenting, to retry when that modal goes away.
    private var blockedTarget: Target?

    /// The scene fully left the foreground. The next `sceneBecameActive` starts a new session.
    mutating func sceneEnteredBackground() {
        awaitingForegroundEdge = true
        presentedThisForeground = false
        blockedTarget = nil
    }

    /// The scene is active (first appearance, or returning to the foreground). Only the first call of each
    /// foreground session decides anything; later calls, for example after an `.inactive` blip, return nil.
    mutating func sceneBecameActive(_ context: Context) -> Target? {
        guard awaitingForegroundEdge else { return nil }
        awaitingForegroundEdge = false
        return decide(context, allowRun: true)
    }

    /// The person (or a Live Activity tap) asked for a workout screen, and the shell is opening it itself, which is
    /// not a surface `decide` can see from outside: the shell closes whatever sheet was up first and presents the
    /// workout a moment later, and nothing evaluates the policy while that workout is on screen. Anything held back
    /// is dropped, and the session's one chance is spent, in either order against the foreground edge, so closing
    /// the workout never re-opens it. A new foreground session starts afresh.
    mutating func workoutOpenedByRequest() {
        awaitingForegroundEdge = false
        presentedThisForeground = true
        blockedTarget = nil
    }

    /// A persisted lift session finished loading after launch. Considers only the lift, so a run the user
    /// already dismissed this session is never brought back by it.
    mutating func liftSessionRestored(_ context: Context) -> Target? {
        guard !presentedThisForeground else { return nil }
        return decide(context, allowRun: false)
    }

    /// The modal that blocked an earlier attempt is gone. Re-evaluates only what that attempt was blocked on,
    /// so it does nothing if nothing was blocked, the workout already ended, or the user opened it by hand.
    mutating func otherPresentationEnded(_ context: Context) -> Target? {
        guard let blocked = blockedTarget else { return nil }
        return decide(context, allowRun: blocked == .run)
    }

    private mutating func decide(_ context: Context, allowRun: Bool) -> Target? {
        let target: Target?
        if context.hasActiveRun {
            target = allowRun ? .run : nil
        } else if context.hasActiveLift {
            target = .lift
        } else {
            target = nil
        }
        guard !context.workoutSurfaceVisible else {
            blockedTarget = nil
            return nil
        }
        guard !context.otherPresentationActive else {
            // Keep the oldest blocked target: a later, lower-priority attempt must not replace a run.
            if blockedTarget == nil || target == .run { blockedTarget = target }
            return nil
        }
        blockedTarget = nil
        if target != nil { presentedThisForeground = true }
        return target
    }
}

extension ActiveSessionAutoPresentPolicy.Context {
    /// The context the shell builds. `anyModalPresented` is any sheet or cover in the window, a screen's own included (a
    /// manual workout, a journal edit): an automatic presentation never closes one, so the policy waits for it like any
    /// other modal, and until it is gone the resume bar is the way back.
    init(hasActiveRun: Bool, hasActiveLift: Bool, workoutSurfaceVisible: Bool, shellPresentationActive: Bool,
         anyModalPresented: Bool) {
        self.init(hasActiveRun: hasActiveRun, hasActiveLift: hasActiveLift, workoutSurfaceVisible: workoutSurfaceVisible,
                  otherPresentationActive: shellPresentationActive || anyModalPresented)
    }
}

/// Modals that must finish before a workout is auto-presented, tracked by view identity like
/// `WorkoutSurfaceVisibility`. Unlike a sheet's own appearance, these register from the moment the modal is
/// requested (the state flips), so a presentation decision made while the modal is still animating in
/// already sees it.
struct AutoPresentBlockers: Equatable {
    private var blocking: Set<UUID> = []

    var isBlocked: Bool { !blocking.isEmpty }

    mutating func set(_ blocked: Bool, id: UUID) {
        if blocked { blocking.insert(id) } else { blocking.remove(id) }
    }
}

/// Which workout screens (live run, lift flow) are on screen, tracked by view identity so a repeated
/// `onAppear` without a matching `onDisappear` cannot drift a counter. The auto-present policy reads this
/// to avoid stacking a second presentation on a screen some other view already presented.
struct WorkoutSurfaceVisibility: Equatable {
    private var visible: Set<UUID> = []

    var isVisible: Bool { !visible.isEmpty }

    mutating func appeared(_ id: UUID) { visible.insert(id) }
    mutating func disappeared(_ id: UUID) { visible.remove(id) }
}
