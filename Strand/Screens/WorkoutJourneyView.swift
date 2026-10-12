import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - The workout journey
//
// Start, record and finish are one full-screen mode, owned by the app shell and presented once, as a full-screen cover that
// cannot be swiped away: setup, the live screen, then the summary. Nothing in it is presented a second time, so a stacked
// sheet can never fail to appear. The phases and what moves between them are plain values (`WorkoutJourneyPhase`, the
// reducer) so the rules are tested without a view; the view applies what the reducer says and nothing else changes the phase.

/// Where the journey is.
enum WorkoutJourneyPhase: Equatable {
    /// Pick a sport and start. `initialSport` is the sport the picker opens on.
    case setup(initialSport: String?)
    /// The workout is recording.
    case live
    /// The workout was saved: the screen that says how it went (the workout's detail, with Done).
    case summary(WorkoutRow)
}

enum WorkoutJourneyEvent: Equatable {
    /// A workout is now recording.
    case workoutBecameActive
    /// Start did nothing (a lift is in progress): stay on setup.
    case startRefused
    /// The workout was saved.
    case saved(WorkoutRow)
    /// The workout is gone and nothing was saved: it was discarded.
    case workoutGoneWithoutSave
    /// Done.
    case done
}

enum WorkoutJourneyOutcome: Equatable {
    case phase(WorkoutJourneyPhase)
    /// Close the cover; `toast` is a line for the shell to show once it has.
    case close(toast: String?)
}

extension WorkoutJourneyPhase {
    /// The phase a request opens on. A workout already recording always opens the live screen (never a second setup), and a
    /// request for the live screen with nothing recording opens setup rather than an empty screen.
    static func initial(_ start: WorkoutJourneyStart, hasActiveWorkout: Bool) -> WorkoutJourneyPhase {
        switch start {
        case .setup(let sport): hasActiveWorkout ? .live : .setup(initialSport: sport)
        case .live: hasActiveWorkout ? .live : .setup(initialSport: nil)
        }
    }

    /// Pure. Every transition the journey makes; an event that does not apply to the phase leaves it where it is.
    static func reduce(_ phase: WorkoutJourneyPhase, _ event: WorkoutJourneyEvent) -> WorkoutJourneyOutcome {
        switch (phase, event) {
        case (.setup, .workoutBecameActive):
            return .phase(.live)
        case (.live, .saved(let row)):
            return .phase(.summary(row))
        case (.live, .workoutGoneWithoutSave):
            return .close(toast: String(localized: "Workout discarded"))
        case (.summary, .done), (.setup, .done):
            return .close(toast: nil)
        default:
            return .phase(phase)
        }
    }

    /// A key for the phase's kind, so a change of kind (not of its payload) is what animates.
    var kind: Int {
        switch self {
        case .setup: 0
        case .live: 1
        case .summary: 2
        }
    }
}

/// Raised by the summary's Done and read by `WorkoutDetailView`, whose bottom button then says "Done" and calls it.
struct WorkoutJourneyDoneAction {
    let perform: () -> Void
}

extension EnvironmentValues {
    @Entry var workoutJourneyDone: WorkoutJourneyDoneAction? = nil
}

#if os(iOS)
/// The journey as the app shell presents it. Resolves where to open (an active workout always opens the live screen), then
/// hosts the phases.
struct WorkoutJourneyView: View {
    let entry: WorkoutJourneyEntry
    /// Closes the cover.
    let onClose: () -> Void
    @EnvironmentObject private var model: AppModel

    var body: some View {
        WorkoutJourneyHost(
            initialPhase: .initial(entry.start, hasActiveWorkout: model.activeWorkout != nil),
            onClose: onClose)
    }
}

private struct WorkoutJourneyHost: View {
    let onClose: () -> Void
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: NavRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(WorkoutPrefs.keepScreenOnKey) private var keepScreenOn = WorkoutPrefs.keepScreenOnDefault
    @State private var phase: WorkoutJourneyPhase

    init(initialPhase: WorkoutJourneyPhase, onClose: @escaping () -> Void) {
        _phase = State(initialValue: initialPhase)
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack {
            phaseRoot
                .id(phase.kind)
                .transition(.opacity)
                .background(StrandPalette.appCanvas.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
        }
        .drillInDestinationEnvironment()
        .environment(\.appHeaderChromeVisibility, .hidden)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: phase.kind)
        .background(StrandPalette.appCanvas.ignoresSafeArea())
        // The live screen reports itself as a workout surface (so auto-present never stacks a second copy on it). Setup and the
        // summary do not: a lift whose auto-resume was blocked while setup was up must still be remembered and presented once
        // this cover closes, which the shell's "a cover is up" flag does.
        .onReceive(model.$workoutFinishState) { state in
            if case .saved(let row) = state, phase == .live {
                StrandHaptic.success.play()
                apply(.saved(row))
            }
        }
        // A workout that is gone and was not saved was discarded. The save sets `activeWorkout = nil` and the finish state
        // in one synchronous block, so this looks at the next turn, when `.saved` is already there.
        .onReceive(model.$activeWorkout.map { $0 == nil }.removeDuplicates()) { gone in
            guard gone, phase == .live else { return }
            DispatchQueue.main.async { workoutWentAway() }
        }
        .onChange(of: phase, initial: true) { _, _ in updateKeepAwake() }
        .onChange(of: keepScreenOn) { _, _ in updateKeepAwake() }
        // Posted on whatever thread noticed the change; the idle timer is UIKit's, so this hops to the main thread first.
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)) { _ in updateKeepAwake() }
        .onDisappear { ScreenIdle.keepAwake(false) }
    }

    @ViewBuilder private var phaseRoot: some View {
        switch phase {
        case .setup(let initialSport):
            StartWorkoutSheet(
                purpose: .start, initialSport: initialSport, dismissAfterStart: false,
                blockedByLift: model.workoutStartBlock == .liftActive,
                onOpenLift: { router.openActiveLift() }
            ) { sport in start(sport) }
        case .live:
            LiveWorkoutView(onClose: onClose)
        case .summary(let row):
            WorkoutDetailView(row: row)
                .sheetScreenScaffoldEnvironment(onClose: done)
                .environment(\.workoutJourneyDone, WorkoutJourneyDoneAction(perform: done))
        }
    }

    // MARK: Events

    private func apply(_ event: WorkoutJourneyEvent) {
        switch WorkoutJourneyPhase.reduce(phase, event) {
        case .phase(let next):
            if next != phase { phase = next }
        case .close(let toast):
            if let toast { router.shellToast = toast }
            onClose()
        }
    }

    private func start(_ sport: String) {
        // A lift in progress blocks Start; the page says so and offers the lift, so this is not reached from the button.
        guard model.workoutStartBlock == nil else {
            apply(.startRefused)
            return
        }
        model.startWorkout(sport: sport)
        apply(model.activeWorkout != nil ? .workoutBecameActive : .startRefused)
    }

    private func workoutWentAway() {
        if case .saved(let row) = model.workoutFinishState {
            apply(.saved(row))
        } else {
            apply(.workoutGoneWithoutSave)
        }
    }

    /// Done on the summary: the finish has been seen, so the state goes back to recording, and the cover closes.
    private func done() {
        model.acknowledgeFinishState()
        apply(.done)
    }

    // MARK: Screen

    /// The screen stays on while the workout is live (unless it was turned off, or Low Power Mode is on), and nowhere else.
    private func updateKeepAwake() {
        let live = phase == .live
        ScreenIdle.keepAwake(live && WorkoutPrefs.keepsScreenOn(
            preference: keepScreenOn, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled))
    }
}
#endif
