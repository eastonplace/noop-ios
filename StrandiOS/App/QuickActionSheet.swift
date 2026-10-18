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
    @Environment(\.dynamicTypeSize) private var typeSize
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: NavRouter
    @State private var quickStartSport: String?
    @State private var actionSelected = false
    /// The glyph column of every row, so the text of all rows starts on one line. It follows the text size up to a ceiling.
    @ScaledMetric(relativeTo: .body) private var scaledGlyphColumn: CGFloat = 24

    private var glyphColumn: CGFloat { min(scaledGlyphColumn, 34) }
    private var rowSpacing: CGFloat { NoopMetrics.space3 }
    /// Where a row's text begins: after the glyph column and its gap.
    private var textInset: CGFloat { glyphColumn + rowSpacing }

    private var blockedByLift: Bool { model.activeWorkout == nil && model.workoutStartBlock == .liftActive }

    var body: some View {
        VStack(spacing: 0) {
            NoopSheetTitleRow("Quick Actions") {
                HeaderChipButton("xmark", accessibilityLabel: "Close Quick Actions") { dismiss() }
                    .accessibilityIdentifier("quickActions.close")
            }
            .padding(.horizontal, 16).padding(.top, NoopMetrics.space3)
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
                            // On the text column of the row above.
                            .padding(.leading, textInset)
                            .frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .accessibilityHint("Starts the countdown using the eligible recent sport")
                        .accessibilityIdentifier("quickActions.recentSport")
                        .padding(.bottom, NoopMetrics.space3)
                    }
                    FlatRowSeparator()
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
                .padding(.horizontal, 16).padding(.bottom, NoopMetrics.space5)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .buttonStyle(.plain)
        .foregroundStyle(StrandPalette.textPrimary)
        .background(StrandPalette.appCanvas.ignoresSafeArea())
        // One pick per presentation: later taps land nowhere while the sheet closes, without dimming the rows.
        .allowsHitTesting(!actionSelected)
        .onAppear {
            actionSelected = false
            quickStartSport = WorkoutQuickStart.offer(recents: RecentSportsPrefs.recent(),
                gps: WorkoutQuickStart.currentGps(), blockedByLift: model.workoutStartBlock != nil)
        }
    }

    /// The primary row. It starts a workout, returns to the one in progress, or, while a lift is recording, returns to
    /// the lift (a workout cannot start under it). The one solid action of the sheet: Today's Start pill at its end.
    private var workoutAction: some View {
        let active = model.activeWorkout != nil
        return Button {
            perform {
                if blockedByLift { router.openActiveLift() } else { onWorkout(active) }
            }
        } label: {
            let glyph = glyph(blockedByLift ? "dumbbell.fill" : "figure.run", tint: DomainTint.workout.accent)
            let texts = VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                Text(workoutTitle)
                    .font(StrandFont.headline).fixedSize(horizontal: false, vertical: true)
                workoutSubtitle.font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let pill = Group {
                if active || blockedByLift { Text("Open") } else { Text("Start") }
            }
            .font(StrandFont.caption.weight(.semibold))
            .foregroundStyle(StrandPalette.appCanvas)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(StrandPalette.ink, in: Capsule(style: .continuous))
            .accessibilityHidden(true)
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        HStack(alignment: .firstTextBaseline, spacing: rowSpacing) { glyph; texts }
                        pill
                    }
                } else {
                    HStack(alignment: .center, spacing: rowSpacing) {
                        glyph
                        texts.frame(maxWidth: .infinity, alignment: .leading)
                        pill
                    }
                }
            }
            .padding(.vertical, NoopMetrics.space4).contentShape(Rectangle())
        }
        .buttonStyle(QuickActionPressStyle(reduceMotion: reduceMotion))
        .accessibilityIdentifier(active ? "quickActions.resumeWorkout"
                                 : blockedByLift ? "quickActions.returnToLift" : "quickActions.startWorkout")
    }

    /// A row's symbol, inline in its metric colour (no disc), centred in the shared glyph column.
    private func glyph(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: glyphColumn)
            .accessibilityHidden(true)
    }

    private var workoutTitle: LocalizedStringKey {
        if model.activeWorkout != nil { return "Return to workout" }
        if blockedByLift { return "Return to lift" }
        return "Start workout"
    }

    private var workoutSubtitle: Text {
        if let active = model.activeWorkout {
            return Text("\(WorkoutSource.displaySport(active.sport)) · in progress")
        }
        if blockedByLift { return Text("Your lift is recording. Finish it before starting a workout.") }
        return Text("Choose an activity and get started.")
    }

    private func action(_ title: LocalizedStringKey, detail: LocalizedStringKey, symbol: String, tint: Color,
                        id: String, action: @escaping () -> Void) -> some View {
        Button { perform(action) } label: {
            HStack(alignment: .firstTextBaseline, spacing: rowSpacing) {
                glyph(symbol, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(StrandFont.subhead.weight(.semibold))
                    Text(detail).font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: NoopMetrics.space2)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary).accessibilityHidden(true)
            }
            .padding(.vertical, NoopMetrics.space3).frame(minHeight: 56).contentShape(Rectangle())
            .overlay(alignment: .bottom) { FlatRowSeparator(leadingInset: textInset) }
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
