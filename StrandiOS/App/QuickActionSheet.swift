#if os(iOS)
import SwiftUI
import StrandDesign

/// Quick Actions. The tab bar's + turns into a ×, a scrim dims the screen behind it, and the actions spring out of the
/// button above it: Start workout and Strength side by side on top, the other four arcing down to the +. The file keeps
/// the name of the sheet it replaced.
///
/// Presentation only. The app shell remains the sole owner of starting, restoring and presenting a workout, and of the
/// + button itself (`PaperTabBar`), which is drawn above this view so it stays fully visible over the scrim.
struct QuickActionFan: View {
    /// True from the tap that opens it until the tap that closes it. The view stays mounted while it animates out.
    let isOpen: Bool
    /// QA only: holds the animation at this progress (0...1) so a capture can show a frame mid-spring.
    var frozenProgress: CGFloat?
    let onClose: () -> Void
    let onPick: (QuickAction) -> Void
    let onWorkout: (_ active: Bool) -> Void
    /// Opens the Lift flow, the one "Lift weights instead" on the workout setup page also leads to.
    let onStrength: () -> Void
    let onQuickStart: (_ sport: String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: NavRouter
    @AccessibilityFocusState private var primaryFocused: Bool
    @State private var quickStartSport: String?
    @State private var actionSelected = false

    // MARK: Geometry (the mockup's numbers, 1 pt = 1 pt)

    /// The + sits on the centre line of the tab bar's 76pt row, so its centre is half a row above the bottom edge.
    private static let plusCentreAboveBottom = NoopMetrics.navBarHeight / 2
    /// The tab bar's row and the hairline over it.
    private static let barHeight = NoopMetrics.navBarHeight + 1
    private static let labelWidth: CGFloat = 92
    /// Two lines of the 13pt label.
    private static let labelHeight: CGFloat = 34
    private static let stagger = 0.035
    /// The circle in an accessibility-size row stays a fixed size: only the label grows, so five rows still fit above the +.
    private static let rowCircle: CGFloat = 56

    private var blockedByLift: Bool { model.activeWorkout == nil && model.workoutStartBlock == .liftActive }

    /// 0 closed, 1 open. Everything that moves is driven from this one value, each piece with its own animation.
    private var progress: CGFloat { isOpen ? (frozenProgress ?? 1) : 0 }

    var body: some View {
        ZStack {
            scrim
            GeometryReader { geo in
                if usesStack(in: geo.size) {
                    stack
                } else {
                    arc(in: geo.size)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(StrandPalette.textPrimary)
        // One pick per presentation: later taps land nowhere while it closes, without dimming the controls.
        .allowsHitTesting(isOpen && !actionSelected)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityHidden(!isOpen)
        .accessibilityAction(.escape, onClose)
        .onAppear { if isOpen { refresh() } }
        .onChange(of: isOpen) { _, open in
            if open { refresh() }
        }
    }

    /// A new presentation: the pick guard is re-armed, the recent-sport shortcut is looked at again, and VoiceOver moves to
    /// the primary action once it is on screen.
    private func refresh() {
        actionSelected = false
        quickStartSport = WorkoutQuickStart.offer(recents: RecentSportsPrefs.recent(),
            gps: WorkoutQuickStart.currentGps(), blockedByLift: model.workoutStartBlock != nil)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            primaryFocused = true
        }
    }

    /// At accessibility sizes the arc has no room for its labels, and in a short window (landscape) it has no height:
    /// large rows above the + replace it.
    private func usesStack(in size: CGSize) -> Bool {
        typeSize.isAccessibilitySize || size.height < 420
    }

    // MARK: Scrim

    /// Taps anywhere outside the actions close it. It sits under the tab bar, so the bar is the one thing it does not dim.
    private var scrim: some View {
        Button(action: onClose) {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.black.opacity(0.66)
            }
            .opacity(Double(min(max(progress, 0), 1)))
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .easeOut(duration: 0.28), value: isOpen)
            .contentShape(Rectangle())
        }
        .ignoresSafeArea()
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Close Quick Actions")
        .accessibilityIdentifier("quickActions.close")
        .accessibilitySortPriority(-1)
    }

    // MARK: Actions

    private struct FanAction: Identifiable {
        let id: String
        let title: LocalizedStringKey
        /// What VoiceOver says when it differs from what is drawn.
        var spokenTitle: LocalizedStringKey?
        let symbol: String
        let tint: Color
        var hint: LocalizedStringKey?
        var value: Text?
        let slot: QuickActionSlot
        /// VoiceOver lands here when Quick Actions opens.
        var takesFocus = false
        let run: () -> Void

        var isPrimary: Bool { slot.isPrimary }
    }

    /// Left to right across the fan, which is also the order they spring out in.
    private var actions: [FanAction] {
        [
            FanAction(id: "journal", title: "Journal", spokenTitle: "Log journal", symbol: "pencil.line",
                      tint: StrandPalette.journalAccent, hint: "Record how you feel", slot: .journal) { onPick(.journal) },
            FanAction(id: "live", title: "Live HR", symbol: "heart.fill", tint: StrandPalette.liveRed,
                      hint: "See your heart rate now", slot: .live) { onPick(.live) },
            workoutAction,
            strengthAction,
            FanAction(id: "intervals", title: "Intervals", symbol: "timer", tint: StrandPalette.strainAccent,
                      hint: "Open your interval timer", slot: .intervals) { onPick(.intervals) },
            // UX-07 is P3 and excluded. Preserve the existing unconditional entry and preferences.
            FanAction(id: "breathe", title: "Breathe", symbol: "wind", tint: StrandPalette.chargeAccent,
                      hint: "Open guided breathing", slot: .breathe) { onPick(.breathe) },
        ]
    }

    /// Starts a workout, or returns to the one in progress. A lift in progress leaves it as it is: Start opens the setup,
    /// which says a lift is recording and offers it, and Strength is the way straight back to the lift.
    private var workoutAction: FanAction {
        if let active = model.activeWorkout {
            return FanAction(id: "resumeWorkout", title: "Return to workout", symbol: "figure.run",
                             tint: StrandPalette.onInk,
                             value: Text("\(WorkoutSource.displaySport(active.sport)) · in progress"),
                             slot: .workout, takesFocus: true) { onWorkout(true) }
        }
        return FanAction(id: "startWorkout", title: "Start workout", symbol: "figure.run", tint: StrandPalette.onInk,
                         hint: "Choose an activity and get started.", slot: .workout, takesFocus: !blockedByLift) {
            onWorkout(false)
        }
    }

    /// Opens the Lift flow, or, while a lift is recording (a workout cannot start under it), returns to that lift.
    private var strengthAction: FanAction {
        if blockedByLift {
            return FanAction(id: "returnToLift", title: "Return to lift", symbol: "dumbbell.fill",
                             tint: StrandPalette.onInk,
                             hint: "Your lift is recording. Finish it before starting a workout.",
                             slot: .strength, takesFocus: true) { router.openActiveLift() }
        }
        return FanAction(id: "strength", title: "Strength", spokenTitle: "Strength training", symbol: "dumbbell.fill",
                         tint: StrandPalette.onInk, hint: "Choose a routine and track sets, reps and weight.",
                         slot: .strength) { onStrength() }
    }

    /// The "Start <last sport>" shortcut, offered only when starting it would not have to ask anything.
    private var recentSport: String? {
        guard model.activeWorkout == nil, !blockedByLift else { return nil }
        return quickStartSport
    }

    private func perform(_ action: () -> Void) {
        guard !actionSelected else { return }
        actionSelected = true
        action()
    }

    // MARK: The arc

    private var spring: Animation { .spring(response: 0.42, dampingFraction: 0.72) }

    /// Each piece springs on its own clock, 35 ms after the one before it. With Reduce Motion there is no travel or scale,
    /// only a fade.
    private func motion(delay index: Int) -> (move: Animation, fade: Animation) {
        if reduceMotion { return (.easeInOut(duration: 0.2), .easeInOut(duration: 0.2)) }
        let delay = Double(index) * Self.stagger
        return (spring.delay(delay), .easeOut(duration: 0.2).delay(delay))
    }

    private func arc(in size: CGSize) -> some View {
        let plus = CGPoint(x: size.width / 2, y: size.height - Self.plusCentreAboveBottom)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                let target = action.slot.centre(plus: plus, width: size.width)
                bubble(action, index: index, target: target,
                       labelWidth: action.slot.labelWidth(width: size.width, maximum: Self.labelWidth), start: plus)
            }
            if let sport = recentSport {
                // Above the two top actions, centred between them, as a quiet capsule.
                let target = CGPoint(x: plus.x, y: plus.y + QuickActionSlot.chipOffsetY)
                chip(sport: sport, target: target, start: plus, index: 2)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func circle(_ action: FanAction, diameter: CGFloat, glyph: CGFloat) -> some View {
        ZStack {
            Circle().fill(action.isPrimary ? StrandPalette.ink : StrandPalette.inset)
            if !action.isPrimary {
                Circle().strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1)
            }
            Image(systemName: action.symbol)
                .font(.system(size: glyph, weight: .medium))
                .foregroundStyle(action.tint)
                .accessibilityHidden(true)
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: action.isPrimary ? StrandPalette.ink.opacity(0.35) : Color.black.opacity(0.45),
                radius: action.isPrimary ? 20 : 15, y: 10)
    }

    private func bubble(_ action: FanAction, index: Int, target: CGPoint, labelWidth: CGFloat, start: CGPoint) -> some View {
        let diameter = action.slot.diameter
        let height = diameter + QuickActionSlot.labelGap + Self.labelHeight
        let t = progress
        let anim = motion(delay: index)
        return Button { perform(action.run) } label: {
            VStack(spacing: QuickActionSlot.labelGap) {
                circle(action, diameter: diameter, glyph: action.isPrimary ? 30 : 24)
                Text(action.title)
                    .font(StrandFont.footnote.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .frame(width: labelWidth, height: Self.labelHeight, alignment: .top)
            }
            .frame(width: labelWidth, height: height, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuickActionPressStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(action.spokenTitle ?? action.title)
        .modifier(OptionalAccessibilityHint(hint: action.hint, value: action.value))
        .accessibilityIdentifier("quickActions.\(action.id)")
        .modifier(PrimaryFocus(takesFocus: action.takesFocus, focus: $primaryFocused))
        .opacity(Double(t))
        .animation(anim.fade, value: isOpen)
        // The circle is what springs out of the +, so it is the circle's centre the scale holds still.
        .scaleEffect(reduceMotion ? 1 : 0.35 + 0.65 * t, anchor: UnitPoint(x: 0.5, y: (diameter / 2) / height))
        .position(x: target.x, y: target.y + (height - diameter) / 2)
        .offset(reduceMotion ? .zero
                : CGSize(width: (start.x - target.x) * (1 - t), height: (start.y - target.y) * (1 - t)))
        .animation(anim.move, value: isOpen)
    }

    private func chip(sport: String, target: CGPoint, start: CGPoint, index: Int) -> some View {
        let t = progress
        let anim = motion(delay: index)
        return Button { perform { onQuickStart(sport) } } label: {
            HStack(spacing: 7) {
                Image(systemName: "bolt.fill").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StrandPalette.ink).accessibilityHidden(true)
                Text("Start \(StartWorkoutChoices.displayTitle(for: sport))")
                    .font(StrandFont.footnote.weight(.semibold))
                Text("Skips setup").font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(StrandPalette.card, in: Capsule())
            .overlay(Capsule().strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuickActionPressStyle(reduceMotion: reduceMotion))
        .accessibilityHint("Starts the countdown using the eligible recent sport")
        .accessibilityIdentifier("quickActions.recentSport")
        .opacity(Double(t))
        .animation(anim.fade, value: isOpen)
        .scaleEffect(reduceMotion ? 1 : 0.35 + 0.65 * t)
        .position(x: target.x, y: target.y)
        .offset(reduceMotion ? .zero
                : CGSize(width: (start.x - target.x) * (1 - t), height: (start.y - target.y) * (1 - t)))
        .animation(anim.move, value: isOpen)
    }

    // MARK: Accessibility sizes: large rows above the +

    private var stack: some View {
        let ordered = actions.filter { !$0.isPrimary } + actions.filter { $0.isPrimary }
        let rows = VStack(spacing: 10) {
            ForEach(Array(ordered.enumerated()), id: \.element.id) { index, action in
                if action.slot == .workout, let sport = recentSport {
                    recentRow(sport: sport, index: index)
                }
                row(action, index: index)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // Rows that fit sit bare, so a tap on the space around them reaches the scrim; only a stack taller than the screen
        // (the very largest sizes) scrolls, and a scroll view takes the taps on its own empty space.
        return ViewThatFits(in: .vertical) {
            rows.frame(maxHeight: .infinity, alignment: .bottom)
            ScrollView { rows }
                .defaultScrollAnchor(.bottom)
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
        }
        // The rows end above the tab bar (its row and the hairline over it).
        .padding(.bottom, Self.barHeight)
    }

    private func rowChrome<Content: View>(index: Int, @ViewBuilder _ content: () -> Content) -> some View {
        let t = progress
        let anim = motion(delay: index)
        return content()
            .opacity(Double(t))
            .animation(anim.fade, value: isOpen)
            .offset(y: reduceMotion ? 0 : 28 * (1 - t))
            .animation(anim.move, value: isOpen)
    }

    private func row(_ action: FanAction, index: Int) -> some View {
        rowChrome(index: index) {
            Button { perform(action.run) } label: {
                let circleSize = action.isPrimary ? Self.rowCircle + 8 : Self.rowCircle
                HStack(spacing: 16) {
                    ZStack {
                        Circle().fill(action.isPrimary ? StrandPalette.ink : StrandPalette.inset)
                        if !action.isPrimary {
                            Circle().strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1)
                        }
                        Image(systemName: action.symbol)
                            .font(.system(size: circleSize * 0.42, weight: .medium))
                            .foregroundStyle(action.tint)
                            .accessibilityHidden(true)
                    }
                    .frame(width: circleSize, height: circleSize)
                    Text(action.title)
                        .font(StrandFont.body.weight(.semibold))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(minHeight: 72)
                .background(StrandPalette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(QuickActionPressStyle(reduceMotion: reduceMotion))
            .accessibilityLabel(action.spokenTitle ?? action.title)
            .modifier(OptionalAccessibilityHint(hint: action.hint, value: action.value))
            .accessibilityIdentifier("quickActions.\(action.id)")
            .modifier(PrimaryFocus(takesFocus: action.takesFocus, focus: $primaryFocused))
        }
    }

    private func recentRow(sport: String, index: Int) -> some View {
        rowChrome(index: index) {
            Button { perform { onQuickStart(sport) } } label: {
                HStack(spacing: 12) {
                    Image(systemName: "bolt.fill").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(StrandPalette.ink).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start \(StartWorkoutChoices.displayTitle(for: sport))")
                            .font(StrandFont.subhead.weight(.semibold))
                        Text("Skips setup").font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
                .frame(minHeight: 56)
                .background(StrandPalette.card, in: Capsule())
                .overlay(Capsule().strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(QuickActionPressStyle(reduceMotion: reduceMotion))
            .accessibilityHint("Starts the countdown using the eligible recent sport")
            .accessibilityIdentifier("quickActions.recentSport")
        }
    }
}

/// Where each Quick Action sits: Start workout and Strength side by side on top, the other four arcing down to the +.
/// The offsets are the circle's centre from the + button's centre on a `referenceWidth` screen (the mockup's horizontal
/// numbers, lifted so the lowest labels clear the tab bar).
enum QuickActionSlot: CaseIterable {
    case journal, live, workout, strength, intervals, breathe

    /// The screen width the offsets were drawn for. Horizontal offsets scale with the real width.
    static let referenceWidth: CGFloat = 393
    /// The least room kept between a circle or a label and the edge of the screen.
    static let edgeMargin: CGFloat = 12
    /// Between a circle and its label.
    static let labelGap: CGFloat = 8
    /// The recent-sport chip's centre above the + centre: its 44pt frame (the capsule is 36pt) ends 14pt over the two top
    /// circles.
    static var chipOffsetY: CGFloat { workout.offset.y - workout.diameter / 2 - 14 - 22 }

    var offset: CGPoint {
        switch self {
        case .journal: CGPoint(x: -152.5, y: -118)
        case .live: CGPoint(x: -126.5, y: -215)
        case .workout: CGPoint(x: -48.5, y: -262)
        case .strength: CGPoint(x: 48.5, y: -262)
        case .intervals: CGPoint(x: 126.5, y: -215)
        case .breathe: CGPoint(x: 152.5, y: -118)
        }
    }

    var isPrimary: Bool { self == .workout || self == .strength }
    var diameter: CGFloat { isPrimary ? 72 : 60 }

    /// The circle's centre. A narrow screen scales the horizontal offsets down; the outer circles never come nearer the
    /// edge than `edgeMargin`.
    func centre(plus: CGPoint, width: CGFloat) -> CGPoint {
        let reach = width / 2 - Self.edgeMargin - diameter / 2
        let dx = min(abs(offset.x) * width / Self.referenceWidth, reach)
        return CGPoint(x: plus.x + (offset.x < 0 ? -dx : dx), y: plus.y + offset.y)
    }

    /// The label, and with it the tap area: `maximum` wide, or less where that would cross `edgeMargin`.
    func labelWidth(width: CGFloat, maximum: CGFloat) -> CGFloat {
        let x = centre(plus: CGPoint(x: width / 2, y: 0), width: width).x
        return min(maximum, 2 * (min(x, width - x) - Self.edgeMargin))
    }
}

/// A hint and a value only where there are some, so a plain button does not carry an empty one.
private struct OptionalAccessibilityHint: ViewModifier {
    let hint: LocalizedStringKey?
    let value: Text?

    func body(content: Content) -> some View {
        content
            .accessibilityHint(hint ?? "")
            .accessibilityValue(value ?? Text(""))
    }
}

/// VoiceOver lands on the one action marked to take it when Quick Actions opens.
private struct PrimaryFocus: ViewModifier {
    let takesFocus: Bool
    var focus: AccessibilityFocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if takesFocus {
            content.accessibilityFocused(focus)
        } else {
            content
        }
    }
}

/// The press feedback #55 rows use: a slight scale and dim, dim only under Reduce Motion.
private struct QuickActionPressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? (reduceMotion ? 0.82 : 0.9) : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
#endif
