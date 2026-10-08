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
///  - Never stack: if any workout screen is already visible, or another shell-level sheet is up, do nothing.
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
        /// Quick actions, Devices, or a routed pillar sheet is up, so presenting would stack on top of it.
        var otherPresentationActive: Bool
    }

    /// True until the first foreground edge of the current session has been evaluated.
    private var awaitingForegroundEdge = true
    private var presentedThisForeground = false

    /// The scene fully left the foreground. The next `sceneBecameActive` starts a new session.
    mutating func sceneEnteredBackground() {
        awaitingForegroundEdge = true
        presentedThisForeground = false
    }

    /// The scene is active (first appearance, or returning to the foreground). Only the first call of each
    /// foreground session decides anything; later calls, for example after an `.inactive` blip, return nil.
    mutating func sceneBecameActive(_ context: Context) -> Target? {
        guard awaitingForegroundEdge else { return nil }
        awaitingForegroundEdge = false
        return decide(context, allowRun: true)
    }

    /// A persisted lift session finished loading after launch. Considers only the lift, so a run the user
    /// already dismissed this session is never brought back by it.
    mutating func liftSessionRestored(_ context: Context) -> Target? {
        guard !presentedThisForeground else { return nil }
        return decide(context, allowRun: false)
    }

    private mutating func decide(_ context: Context, allowRun: Bool) -> Target? {
        guard !context.workoutSurfaceVisible, !context.otherPresentationActive else { return nil }
        let target: Target?
        if context.hasActiveRun {
            target = allowRun ? .run : nil
        } else if context.hasActiveLift {
            target = .lift
        } else {
            target = nil
        }
        if target != nil { presentedThisForeground = true }
        return target
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
