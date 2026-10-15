#if os(iOS)
import SwiftUI
import StrandDesign

/// Presentation only. The app shell remains the sole owner of starting, restoring and presenting a workout.
struct QuickActionSheet: View {
    let onPick: (QuickAction) -> Void
    let onWorkout: (_ active: Bool) -> Void
    let onQuickStart: (_ sport: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: NavRouter
    @State private var quickStartSport: String?
    @State private var actionSelected = false

    private var blockedByLift: Bool { model.activeWorkout == nil && model.workoutStartBlock == .liftActive }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text("Quick Actions").font(StrandFont.title2)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(StrandPalette.inset, in: Circle())
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Close Quick Actions")
                .accessibilityIdentifier("quickActions.close")
            }
            .padding(.horizontal, NoopMetrics.space5).padding(.top, NoopMetrics.space4)
            .padding(.bottom, NoopMetrics.space2)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    workoutAction
                    if model.activeWorkout == nil, !blockedByLift, let sport = quickStartSport {
                        Button { perform { onQuickStart(sport) } } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "bolt.fill").font(.system(size: 10)).accessibilityHidden(true)
                                Text("Start \(StartWorkoutChoices.displayTitle(for: sport))")
                                    .font(StrandFont.footnote.weight(.medium))
                                Spacer()
                                Text("Skips setup").font(StrandFont.micro)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                            // On the text column of the row above (38pt disc plus 16pt spacing).
                            .padding(.leading, 54)
                            .frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .accessibilityHint("Starts the countdown using the eligible recent sport")
                        .accessibilityIdentifier("quickActions.recentSport")
                        .padding(.bottom, NoopMetrics.space3)
                    }
                    Rectangle().fill(StrandPalette.hairline).frame(height: 1).accessibilityHidden(true)
                    action("Log journal", detail: "Record how you feel", symbol: "square.and.pencil",
                           tint: StrandPalette.journalAccent, id: "journal") { onPick(.journal) }
                    action("Live HR", detail: "See your heart rate now", symbol: "heart.fill",
                           tint: StrandPalette.liveRed, id: "live") { onPick(.live) }
                    action("Intervals", detail: "Open your interval timer", symbol: "timer",
                           tint: StrandPalette.strainAccent, id: "intervals") { onPick(.intervals) }
                    // UX-07 is P3 and excluded. Preserve the existing unconditional entry and preferences.
                    action("Breathe", detail: "Open guided breathing", symbol: "wind",
                           tint: StrandPalette.chargeAccent, id: "breathe") { onPick(.breathe) }
                }
                .padding(.horizontal, NoopMetrics.space5).padding(.bottom, NoopMetrics.space5)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .buttonStyle(.plain)
        .foregroundStyle(StrandPalette.textPrimary)
        .background(StrandPalette.card.ignoresSafeArea())
        // One pick per presentation: later taps land nowhere while the sheet closes, without dimming the rows.
        .allowsHitTesting(!actionSelected)
        .onAppear {
            actionSelected = false
            quickStartSport = WorkoutQuickStart.offer(recents: RecentSportsPrefs.recent(),
                gps: WorkoutQuickStart.currentGps(), blockedByLift: model.workoutStartBlock != nil)
        }
    }

    /// The primary row. It starts a workout, returns to the one in progress, or, while a lift is recording, returns to
    /// the lift (a workout cannot start under it).
    private var workoutAction: some View {
        let active = model.activeWorkout != nil
        return Button {
            perform {
                if blockedByLift { router.openActiveLift() } else { onWorkout(active) }
            }
        } label: {
            HStack(alignment: .center, spacing: NoopMetrics.space4) {
                Image(systemName: blockedByLift ? "dumbbell.fill" : "figure.run")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(StrandPalette.accent)
                    .frame(width: 38, height: 38)
                    .background(StrandPalette.accent.opacity(0.14), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text(workoutTitle)
                        .font(StrandFont.title2).fixedSize(horizontal: false, vertical: true)
                    workoutSubtitle.font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: active || blockedByLift ? "arrow.up.right" : "arrow.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.onInk)
                    .frame(width: 38, height: 38)
                    .background(StrandPalette.ink, in: Circle())
                    .accessibilityHidden(true)
            }
            .padding(.vertical, NoopMetrics.space4).contentShape(Rectangle())
        }
        .buttonStyle(QuickActionPressStyle(reduceMotion: reduceMotion))
        .accessibilityIdentifier(active ? "quickActions.resumeWorkout"
                                 : blockedByLift ? "quickActions.returnToLift" : "quickActions.startWorkout")
    }

    private var workoutTitle: LocalizedStringKey {
        if model.activeWorkout != nil { return "Return to workout" }
        if blockedByLift { return "Return to lift" }
        return "Start workout"
    }

    private var workoutSubtitle: Text {
        if let active = model.activeWorkout {
            return Text("\(WorkoutSource.displaySport(active.sport)) · In progress")
        }
        if blockedByLift { return Text("Your lift is recording. Finish it before starting a workout.") }
        return Text("Choose an activity and get started.")
    }

    private func action(_ title: LocalizedStringKey, detail: LocalizedStringKey, symbol: String, tint: Color,
                        id: String, action: @escaping () -> Void) -> some View {
        Button { perform(action) } label: {
            HStack(spacing: NoopMetrics.space4) {
                Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.14), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(StrandFont.subhead.weight(.semibold))
                    Text(detail).font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: NoopMetrics.space2)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary).accessibilityHidden(true)
            }
            .padding(.vertical, NoopMetrics.space3).frame(minHeight: 68).contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(StrandPalette.hairline).frame(height: 1).padding(.leading, 54).accessibilityHidden(true)
            }
        }
        .buttonStyle(QuickActionPressStyle(reduceMotion: reduceMotion))
        .accessibilityIdentifier("quickActions.\(id)")
    }

    private func perform(_ action: () -> Void) {
        guard !actionSelected else { return }
        actionSelected = true
        action()
    }
}

/// The flat-list press feedback #55 rows use: a slight scale and dim, dim only under Reduce Motion.
private struct QuickActionPressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(configuration.isPressed ? (reduceMotion ? 0.82 : 0.9) : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
#endif
