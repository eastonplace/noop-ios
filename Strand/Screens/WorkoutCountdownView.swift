import Foundation
import SwiftUI
#if os(iOS)
import StrandDesign

// MARK: - Countdown
//
// Three seconds between pressing Start and the clock starting, so the wearer can put the phone away and be ready. The
// workout is started at zero, not before: the count is never part of its time. Tap anywhere to skip it, Cancel to go back to
// setup. A phone that goes to the background cancels it: nothing starts on a screen nobody is looking at. (A blip to
// .inactive, a Control Center pull or a banner, does not.) Once cancelled or finished the count can never start the workout.
//
// A huge rounded mint numeral inside a thin ring that runs down over the three seconds, on black.

struct WorkoutCountdownView: View {
    /// What is about to start, as the callout names it ("Run").
    let title: String
    /// For a route sport: whether the GPS has a lock, said under the number. nil for a sport with no route.
    let gpsLocked: Bool?
    /// Zero was reached, or the wearer tapped to skip: start the workout.
    let onFinished: () -> Void
    let onCancel: () -> Void

    @State private var state = WorkoutCountdownState()
    @State private var ring: Double = 1
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: NoopMetrics.space4) {
            Spacer(minLength: 0)
            ZStack {
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 4)
                Circle().trim(from: 0, to: ring)
                    .stroke(LivePalette.mint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(verbatim: "\(state.digit)")
                    .font(LiveNumeralMetrics.numeralFont(210))
                    .foregroundStyle(LivePalette.mint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                    .padding(36)
                    .id(state.digit)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 1.08)))
            }
            .frame(maxWidth: 320)
            .aspectRatio(1, contentMode: .fit)
            .animation(.easeOut(duration: 0.25), value: state.digit)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Starting in \(state.digit)"))
            VStack(spacing: NoopMetrics.space2) {
                Text(verbatim: callout)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .liveText(17, weight: .semibold, maxSize: 24, lines: 3)
                    .multilineTextAlignment(.center)
                Text("Tap to skip")
                    .foregroundStyle(LivePalette.secondaryText)
                    .liveText(14, weight: .medium, maxSize: 20, lines: 2)
            }
            Spacer(minLength: 0)
            LiveCapsuleButton(String(localized: "Cancel"), isGrey: true) { cancel() }
        }
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.bottom, NoopMetrics.space4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LivePalette.canvas.ignoresSafeArea())
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .accessibilityAction(named: Text("Skip the countdown")) { finish() }
        .task { await count() }
        .onChange(of: scenePhase) { _, phase in
            if WorkoutCountdownState.cancels(on: phase) { cancel() }
        }
    }

    /// "Run · GPS locked", or just "Run" for a sport with no route.
    private var callout: String {
        gpsLocked == true ? String(localized: "\(title) · GPS locked") : title
    }

    private func count() async {
        #if DEBUG
        // QA: hold the digit still for a screenshot.
        if let held = WorkoutCountdown.frozenDigit(arguments: ProcessInfo.processInfo.arguments) {
            state.show(held)
            ring = Double(held) / Double(WorkoutCountdown.seconds)
            return
        }
        #endif
        ring = 1
        if !reduceMotion { withAnimation(.linear(duration: Double(WorkoutCountdown.seconds))) { ring = 0 } }
        for value in stride(from: WorkoutCountdown.seconds, through: 1, by: -1) {
            guard state.canStart else { return }
            state.show(value)
            if reduceMotion { ring = Double(value) / Double(WorkoutCountdown.seconds) }
            StrandHaptic.selection.play()
            AccessibilityNotification.Announcement("\(value)").post()
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
        guard !Task.isCancelled, state.canStart else { return }
        StrandHaptic.commit.play()
        AccessibilityNotification.Announcement(String(localized: "Started")).post()
        finish()
    }

    /// Start the workout now (the count reached zero, or a tap skipped it). Does nothing once the count was cancelled.
    private func finish() {
        guard state.finish() else { return }
        onFinished()
    }

    /// Back to setup (Cancel, or the phone went to the background). The count stops here: the workout cannot start after this.
    private func cancel() {
        guard state.cancel() else { return }
        onCancel()
    }
}
#endif

/// Where the countdown is, as a plain value: counting until it is finished or cancelled, and then never again. The view asks
/// before it starts the workout and before it goes back, so a Cancel that races the last second cannot also start it.
struct WorkoutCountdownState: Equatable {
    enum Phase: Equatable { case counting, finished, cancelled }

    private(set) var digit = WorkoutCountdown.seconds
    private(set) var phase: Phase = .counting

    /// The count can still start the workout.
    var canStart: Bool { phase == .counting }

    mutating func show(_ digit: Int) {
        guard canStart else { return }
        self.digit = digit
    }

    /// Ends the count with a start. True only the first time, and never after a cancel.
    mutating func finish() -> Bool {
        guard phase == .counting else { return false }
        phase = .finished
        return true
    }

    /// Ends the count with a cancel. True only the first time, and never after a start.
    mutating func cancel() -> Bool {
        guard phase == .counting else { return false }
        phase = .cancelled
        return true
    }

    /// Only a real background transition cancels: .inactive is a pull of Control Center or a banner, and the count goes on.
    static func cancels(on scenePhase: ScenePhase) -> Bool { scenePhase == .background }
}

/// The countdown's constants and its QA flag, outside the view so they are tested.
enum WorkoutCountdown {
    /// Where the count starts.
    static let seconds = 3

    /// `--demo-countdown-frozen 3` (QA): the digit to hold still instead of counting. nil counts normally.
    static func frozenDigit(arguments: [String]) -> Int? {
        guard let flag = arguments.firstIndex(of: "--demo-countdown-frozen"), arguments.indices.contains(flag + 1),
              let digit = Int(arguments[flag + 1]), (1...seconds).contains(digit) else { return nil }
        return digit
    }

    /// Whether the countdown view is mounted at all: with the countdown off a quick start goes straight to the workout, so
    /// there is no count to see, hear or feel (no "3", no haptic).
    static func mountsView(countdownOn: Bool) -> Bool { countdownOn }
}
