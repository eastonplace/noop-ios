#if os(iOS)
import SwiftUI
import StrandDesign

/// Presentation only. The app shell remains the sole owner of starting, restoring and presenting a workout.
struct QuickActionSheet: View {
    let onPick: (QuickAction) -> Void
    let onWorkout: (_ active: Bool) -> Void
    let onQuickStart: (_ sport: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var quickStartSport: String?
    @State private var actionSelected = false

    private var blockedByLift: Bool { model.activeWorkout == nil && model.workoutStartBlock != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quick Actions").font(StrandFont.title2)
                    Text("Keep your day moving.").font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
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
            .padding(.bottom, NoopMetrics.space3)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    workoutAction
                    if model.activeWorkout == nil, !blockedByLift, let sport = quickStartSport {
                        Button { perform { onQuickStart(sport) } } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "bolt.fill").font(.system(size: 10))
                                Text("Start \(StartWorkoutChoices.displayTitle(for: sport))")
                                    .font(StrandFont.footnote.weight(.medium))
                                Spacer()
                                Text("Skip setup").font(StrandFont.micro)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                            .frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .accessibilityHint("Starts the countdown using the eligible recent sport")
                        .accessibilityIdentifier("quickActions.recentSport")
                        .padding(.bottom, NoopMetrics.space3)
                    }
                    Rectangle().fill(StrandPalette.hairline).frame(height: 1).accessibilityHidden(true)
                    action("Log journal", detail: "Record how you feel", symbol: "square.and.pencil",
                           tint: StrandPalette.journalAccent, id: "journal") { onPick(.journal) }
                    action("Live HR", detail: "See your heart rate now", symbol: "heart",
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
        }
        .buttonStyle(.plain)
        .foregroundStyle(StrandPalette.textPrimary)
        .background(StrandPalette.card.ignoresSafeArea())
        .onAppear {
            actionSelected = false
            quickStartSport = WorkoutQuickStart.offer(recents: RecentSportsPrefs.recent(),
                gps: WorkoutQuickStart.currentGps(), blockedByLift: model.workoutStartBlock != nil)
        }
    }

    private var workoutAction: some View {
        let active = model.activeWorkout != nil
        return Button { perform { onWorkout(active) } } label: {
            HStack(alignment: .center, spacing: NoopMetrics.space4) {
                Image(systemName: "figure.run").font(.system(size: 27, weight: .light))
                    .foregroundStyle(blockedByLift ? StrandPalette.textTertiary : StrandPalette.accent)
                    .frame(width: 34).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(active ? "Return to workout" : "Start workout")
                        .font(StrandFont.title2).fixedSize(horizontal: false, vertical: true)
                    Text(workoutSubtitle).font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: active ? "arrow.up.right" : "arrow.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(blockedByLift ? StrandPalette.textTertiary : StrandPalette.onInk)
                    .frame(width: 38, height: 38)
                    .background(blockedByLift ? StrandPalette.inset : StrandPalette.ink, in: Circle())
                    .accessibilityHidden(true)
            }
            .padding(.vertical, NoopMetrics.space5).contentShape(Rectangle())
        }
        .disabled(blockedByLift || actionSelected)
        .accessibilityIdentifier(active ? "quickActions.resumeWorkout" : "quickActions.startWorkout")
    }

    private var workoutSubtitle: String {
        if let active = model.activeWorkout { return WorkoutSource.displaySport(active.sport) + " · In progress" }
        if blockedByLift { return "Close this menu to return to your active lift." }
        return String(localized: "Choose an activity and get started.")
    }

    private func action(_ title: String, detail: String, symbol: String, tint: Color,
                        id: String, action: @escaping () -> Void) -> some View {
        Button { perform(action) } label: {
            HStack(spacing: NoopMetrics.space4) {
                Image(systemName: symbol).font(.system(size: 18, weight: .regular))
                    .foregroundStyle(tint).frame(width: 34).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey(title)).font(StrandFont.subhead.weight(.medium))
                    Text(LocalizedStringKey(detail)).font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(StrandPalette.textTertiary).accessibilityHidden(true)
            }
            .padding(.vertical, 15).frame(minHeight: 68).contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(StrandPalette.hairline).frame(height: 1).padding(.leading, 50).accessibilityHidden(true)
            }
        }
        .disabled(actionSelected)
        .accessibilityIdentifier("quickActions.\(id)")
    }

    private func perform(_ action: () -> Void) {
        guard !actionSelected else { return }
        actionSelected = true
        action()
    }
}
#endif
