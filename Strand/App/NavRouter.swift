import SwiftUI
import Combine

// MARK: - NavRouter
//
// A tiny shared navigation hook so a screen can ask the app shell to switch to another top-level
// destination without knowing how that shell is built. The two shells navigate very differently —
// macOS drives a `NavigationSplitView` sidebar selection (`RootView`), iOS uses a `TabView` whose
// "everything else" screens live behind the More tab (`RootTabView`) — so neither exposes a shared
// `selection` binding LiveView could reach. This object is the small, shared bridge between them.
//
// Usage: a screen calls `router.openDevices()`; the shell observes `requestedDestination` and routes
// itself (macOS sets the sidebar selection to `.devices`; iOS presents `DevicesView`). Each consumer
// clears the request once it's handled so the same tap can fire again later. Injected at both app
// roots (`StrandApp`, `StrandiOSApp`) as an `@EnvironmentObject`.
/// Where the workout journey opens.
enum WorkoutJourneyStart: Equatable {
    /// Pick a sport and start. `initialSport` is the sport the picker opens on; nil opens on the most recent one.
    case setup(initialSport: String?)
    /// The workout already recording.
    case live
    /// Start this sport straight away, skipping setup: the countdown (when it is on), then the live screen.
    case quickStart(sport: String)
}

/// One presentation of the journey: a fresh identity per request, so the cover rebuilds even for an equal start.
struct WorkoutJourneyEntry: Identifiable, Equatable {
    let id = UUID()
    let start: WorkoutJourneyStart
}

@MainActor
final class NavRouter: ObservableObject {
    /// A top-level destination a screen can ask the shell to open. Deliberately minimal — the Devices
    /// manager, the v5 pillar screens the new in-hub rows deep-link to (Insights hub, Lab Book, the
    /// fused record, the experimental Rhythm visualization), Trends, and the active-workout deep-link key (the shell
    /// answers it with `openActiveWorkout()`).
    enum Destination: String, Equatable, Identifiable {
        case devices
        case insightsHub
        case labBook
        case fusedRecord
        case rhythm
        case trends
        case activeWorkout
        case liveSession
        /// A deep-link key for Updates items (and callers that predate `openSettings`). The shell answers it by
        /// presenting the Settings sheet, the same as `openSettings()`.
        case settings
        case updates

        var id: String { rawValue }

        /// Map a stored `UpdateItem.deepLink` route key to a Destination, if it names one. Lets the
        /// Updates inbox route a tapped item generically (e.g. a `.reading` item's "trends") without the
        /// inbox knowing every shell. Unknown keys return nil → the inbox just dismisses.
        init?(deepLinkKey: String) {
            self.init(rawValue: deepLinkKey)
        }
    }

    /// The destination a screen has asked the shell to open, or nil once handled. Published so the
    /// active shell (macOS sidebar / iOS tab) reacts and routes itself, then resets this to nil.
    @Published var requestedDestination: Destination?

    /// Set when a screen's top-bar "+" asks the shell to open the quick-action sheet (the sheet lives
    /// in the iOS shell). The shell presents it, then resets this to false.
    @Published var quickActionsRequested = false

    /// The Settings sheet a screen has asked the shell to open, or nil once handled. A route deep-links to one
    /// Settings page; nil opens the Settings root. Each request is its own identity, so asking twice for the same page
    /// is two requests. The iOS shell presents the sheet, then resets this to nil.
    @Published var settingsRequest: SettingsSheetRequest?

    /// Raised by any screen that wants the workout journey (setup, live, summary); consumed (and cleared) by the iOS shell,
    /// which presents the one full-screen cover. A request for a journey that is already open is dropped.
    @Published var workoutJourneyRequest: WorkoutJourneyStart?

    /// A line the shell shows as a toast at its root ("Workout discarded"), for an action whose screen has already gone away.
    /// The shell clears it once shown.
    @Published var shellToast: String?

    /// Bumped by the shell when it needs every presenter below it to let go of whatever it is presenting, so one full-screen
    /// cover can present at the root. A presenter applies `collapsesForWorkoutJourney(_:)` to its binding to follow it.
    @Published private(set) var modalCollapseGeneration = 0

    /// The live screen's page each workout was last on, by session. Not published: nothing is drawn from it.
    let workoutPageMemory = WorkoutPageMemory()

    /// Set by the lift Live Activity deep link (`noop://lift/active`). The iOS shell presents the Lift flow
    /// (which resumes an active session on its own), then resets this to false.
    @Published var activeLiftRequested = false

    /// Counts the times a screen asked for the live workout or the Lift flow by hand (the Today indicator, a Live
    /// Activity tap). The auto-present policy reads it to learn that the surface it was holding back was opened on
    /// request, so closing it does not bring it back.
    @Published private(set) var workoutRequestCount = 0

    /// Which workout screens (the live run, the Lift flow) are on screen right now, wherever they were
    /// presented from. Deliberately not `@Published`: it is only read at the moments the shell decides
    /// whether to auto-present, and publishing it would re-render the shell on every appear/disappear.
    private(set) var workoutSurfaces = WorkoutSurfaceVisibility()

    /// True while a launch-time modal ("What's New", the onboarding or terms gate) is up. Published, unlike
    /// `workoutSurfaces`, because the shell must notice the moment it clears to present what it was holding
    /// back; it only changes when the aggregate flips.
    @Published private(set) var isAutoPresentBlocked = false
    private var autoPresentBlockers = AutoPresentBlockers()

    /// Ask the shell to open the quick-action sheet (Live HR · workout · journal · breathe).
    func requestQuickActions() { quickActionsRequested = true }

    /// Ask the shell to open the Devices manager (pair / switch bands). The shell decides how.
    func openDevices() { requestedDestination = .devices }
    /// Open the v5 Insights hub (the n-of-1 "what moves your Charge" surface).
    func openInsightsHub() { requestedDestination = .insightsHub }
    /// Open the Lab Book (private health-records logbook).
    func openLabBook() { requestedDestination = .labBook }
    /// Open the "Your Data, Fused" multi-device record.
    func openFusedRecord() { requestedDestination = .fusedRecord }
    /// Open the experimental Rhythm visualization (self-gates on its own consent).
    func openRhythm() { requestedDestination = .rhythm }
    /// Open the Trends screen (where a "new data" reading deep-links).
    func openTrends() { requestedDestination = .trends }
    /// Start a workout: the journey opens on setup. When a workout is already recording the shell opens that one instead (never
    /// a second setup).
    func beginWorkout(sport: String? = nil) { workoutJourneyRequest = .setup(initialSport: sport) }
    /// Start a workout in `sport` without the setup page (the Quick Actions row). A workout already recording opens instead.
    func quickStartWorkout(sport: String) { workoutJourneyRequest = .quickStart(sport: sport) }
    /// Return to the recording workout (the Today hero, the resume bar, the Live Activity, auto-present, a deep link). Counts
    /// as a request (`workoutRequestCount`), so the auto-present policy will not bring the workout back after it is minimized.
    func openActiveWorkout() {
        workoutRequestCount += 1
        workoutJourneyRequest = .live
    }
    /// Ask every presenter below the shell to let go of what it is presenting.
    func collapseModals() { modalCollapseGeneration &+= 1 }
    /// Open the in-flight Lift session (the lift Live Activity's deep link).
    func openActiveLift() {
        workoutRequestCount += 1
        activeLiftRequested = true
    }

    func workoutSurfaceDidAppear(_ id: UUID) { workoutSurfaces.appeared(id) }
    func workoutSurfaceDidDisappear(_ id: UUID) { workoutSurfaces.disappeared(id) }

    func setAutoPresentBlocked(_ blocked: Bool, id: UUID) {
        autoPresentBlockers.set(blocked, id: id)
        if isAutoPresentBlocked != autoPresentBlockers.isBlocked {
            isAutoPresentBlocked = autoPresentBlockers.isBlocked
        }
    }

    /// Open a Live Session (silent guardian, beta). The Liquid Today entry presents the session screen
    /// directly today; this route exists for deep-link parity so a future shell/inbox item can raise it
    /// the same way as every other destination.
    func openLiveSession() { requestedDestination = .liveSession }
    /// Open Settings, a sheet over whatever the person is looking at. `route` lands on one page (the profile page, say)
    /// instead of the Settings root.
    func openSettings(_ route: SettingsRouteID? = nil) { settingsRequest = SettingsSheetRequest(route: route) }
    func openUpdates() { requestedDestination = .updates }
}

// MARK: - Workout surface tracking

private struct WorkoutSurfaceTracker: ViewModifier {
    @EnvironmentObject private var router: NavRouter
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { router.workoutSurfaceDidAppear(id) }
            .onDisappear { router.workoutSurfaceDidDisappear(id) }
    }
}

private struct AutoPresentBlockerModifier: ViewModifier {
    @EnvironmentObject private var router: NavRouter
    @State private var id = UUID()
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            // `initial: true` registers a modal that is already requested when this view first appears, and
            // the flag flips before the modal's own appearance, so a decision made mid-animation sees it.
            .onChange(of: isActive, initial: true) { _, active in
                router.setAutoPresentBlocked(active, id: id)
            }
            .onDisappear { router.setAutoPresentBlocked(false, id: id) }
    }
}

extension View {
    /// While `active`, the shell will not auto-present an in-flight workout over this modal. It presents
    /// once the modal is gone instead.
    func blocksAutoPresent(while active: Bool) -> some View {
        modifier(AutoPresentBlockerModifier(isActive: active))
    }

    /// Report this view's time on screen to the router, so the shell never stacks an auto-presented workout
    /// on top of a workout screen some other view already presented.
    func tracksWorkoutSurface() -> some View { modifier(WorkoutSurfaceTracker()) }
}
