import Foundation
#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - Countdown
//
// Three seconds between pressing Start and the clock starting, so the wearer can put the phone away and be ready. The
// workout is started at zero, not before: the count is never part of its time. Tap anywhere to skip it, Cancel to go back to
// setup. A phone that leaves the foreground cancels it: nothing starts on a screen nobody is looking at.

struct WorkoutCountdownView: View {
    /// What is about to start, as the callout names it ("Run").
    let title: String
    /// For a route sport: whether the GPS has a lock, said under the number. nil for a sport with no route.
    let gpsLocked: Bool?
    /// Zero was reached, or the wearer tapped to skip: start the workout.
    let onFinished: () -> Void
    let onCancel: () -> Void

    @State private var digit = WorkoutCountdown.seconds
    @State private var finished = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: NoopMetrics.space4) {
            Spacer(minLength: 0)
            ZStack {
                Text(verbatim: "\(digit)")
                    .font(StrandFont.number(260, weight: .bold))
                    .foregroundStyle(StrandPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .id(digit)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 1.1)))
            }
            .animation(.easeOut(duration: 0.25), value: digit)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Starting in \(digit)"))
            VStack(spacing: NoopMetrics.space2) {
                Text(verbatim: callout)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Tap to skip")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 0)
            Button(action: onCancel) { Text("Cancel").frame(maxWidth: .infinity) }
                .buttonStyle(SecondaryPillButtonStyle())
        }
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.bottom, NoopMetrics.space4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.appCanvas.ignoresSafeArea())
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .accessibilityAction(named: Text("Skip the countdown")) { finish() }
        .task { await count() }
        .onChange(of: scenePhase) { _, phase in if phase != .active && !finished { onCancel() } }
    }

    /// "Run · GPS locked", or just "Run" for a sport with no route.
    private var callout: String {
        gpsLocked == true ? String(localized: "\(title) · GPS locked") : title
    }

    private func count() async {
        #if DEBUG
        // QA: hold the digit still for a screenshot.
        if let held = WorkoutCountdown.frozenDigit(arguments: ProcessInfo.processInfo.arguments) {
            digit = held
            return
        }
        #endif
        for value in stride(from: WorkoutCountdown.seconds, through: 1, by: -1) {
            digit = value
            StrandHaptic.selection.play()
            AccessibilityNotification.Announcement("\(value)").post()
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        StrandHaptic.commit.play()
        AccessibilityNotification.Announcement(String(localized: "Started")).post()
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinished()
    }
}
#endif

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
}
