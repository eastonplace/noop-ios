import SwiftUI

// MARK: - The live screens' controls
//
// Calm circles, easy to hit mid-stride and never louder than the data: a soft mint Pause, a ringed red Hold to End, and
// one solid mint circle on the whole screen (Resume, or Start on the setup page). No full-width slab anywhere.

/// The diameters of the circles, which shrink a step at the accessibility sizes so the controls and their labels still fit
/// under the figures.
public enum LiveCircleMetrics {
    public static let standard: CGFloat = 76
    public static let accessibility: CGFloat = 64
    public static let start: CGFloat = 88
    public static let startAccessibility: CGFloat = 72

    public static func diameter(accessibilitySize: Bool) -> CGFloat { accessibilitySize ? accessibility : standard }
    public static func startDiameter(accessibilitySize: Bool) -> CGFloat { accessibilitySize ? startAccessibility : start }
}

/// A circle with a glyph and its name beneath it. `solid` is the one loud control (mint fill, dark glyph); otherwise the
/// circle is a 15% wash of `tint` with a glyph in `tint`.
public struct LiveCircleButton: View {
    private let title: String
    private let systemImage: String
    private let tint: Color
    private let solid: Bool
    private let diameter: CGFloat?
    private let accessibilityLabelText: String?
    private let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.isEnabled) private var isEnabled

    public init(title: String, systemImage: String, tint: Color = LivePalette.mint, solid: Bool = false,
                diameter: CGFloat? = nil, accessibilityLabel: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.solid = solid
        self.diameter = diameter
        self.accessibilityLabelText = accessibilityLabel
        self.action = action
    }

    private var size: CGFloat { diameter ?? LiveCircleMetrics.diameter(accessibilitySize: typeSize.isAccessibilitySize) }

    public var body: some View {
        Button(action: action) {
            VStack(spacing: 11) {
                Circle()
                    .fill(solid ? tint : tint.opacity(0.15))
                    .frame(width: size, height: size)
                    .overlay {
                        Image(systemName: systemImage)
                            .font(.system(size: size * 0.38, weight: .bold))
                            .foregroundStyle(solid ? Color.black : tint)
                            // The play triangle sits optically left of centre.
                            .offset(x: systemImage == "play.fill" ? size * 0.04 : 0)
                    }
                Text(verbatim: title)
                    .foregroundStyle(tint)
                    .liveText(14, weight: .semibold, maxSize: 19, lines: 2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: max(size + 28, 104))
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The same 6 pt of air as the held circle's ring, so a row of both lines up.
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(LiveCirclePressStyle())
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(Text(verbatim: accessibilityLabelText ?? title))
    }
}

/// A quiet capsule for a choice that is not the main control: the neutral secondary (Try again, Keep recording), the grey
/// one (Discard), or a 15% wash of an explicit `tint`. Two lines at most, then smaller; never cut off.
public struct LiveCapsuleButton: View {
    private let title: String
    private let tint: Color?
    private let isGrey: Bool
    private let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    /// `tint` is for a caller that really is a recording-now control; left nil the button is the neutral secondary
    /// (clear, a `hairlineStrong` edge, a `textPrimary` label), and `isGrey` is the quieter fill.
    public init(_ title: String, tint: Color? = nil, isGrey: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.tint = tint
        self.isGrey = isGrey
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .foregroundStyle(isGrey ? LivePalette.quietAction : (tint ?? StrandPalette.textPrimary))
                .liveText(17, weight: .semibold, maxSize: 22, lines: 2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 56 : 52)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Capsule(style: .continuous).fill(isGrey ? LivePalette.fill : (tint?.opacity(0.15) ?? Color.clear)))
                .overlay {
                    if !isGrey, tint == nil {
                        Capsule(style: .continuous).strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1)
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(LiveCirclePressStyle())
    }
}

/// The press: a small shrink and a step back, nothing that moves anything else.
struct LiveCirclePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// End: a red stop glyph in a ring that fills over the hold (1.2 s by default, the same contract as every hold in the app:
/// one uninterrupted press, exactly once). VoiceOver and Switch Control cannot hold, so `accessibilityConfirm` runs instead.
public struct LiveHoldCircleButton: View {
    private let title: String
    private let completedTitle: String
    private let tapHint: String?
    private let holdSeconds: Double
    private let tint: Color
    private let previewProgress: Double?
    private let accessibilityConfirm: (() -> Void)?
    private let action: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: Double = 0
    @State private var contract = HoldToConfirmContract()
    @State private var confirmationTask: Task<Void, Never>?
    @State private var hintTask: Task<Void, Never>?
    @State private var showsHint = false

    /// - Parameters:
    ///   - tapHint: What the label says for a moment after a hold is let go early ("Keep holding").
    ///   - previewProgress: Draws the ring filled to this share, with no gesture (screenshots and previews only).
    public init(title: String, completedTitle: String, tapHint: String? = nil, holdSeconds: Double = 1.2,
                tint: Color = LivePalette.red, previewProgress: Double? = nil,
                accessibilityConfirm: (() -> Void)? = nil, action: @escaping () -> Void) {
        self.title = title
        self.completedTitle = completedTitle
        self.tapHint = tapHint
        self.holdSeconds = HoldToConfirmContract.normalized(seconds: holdSeconds)
        self.tint = tint
        self.previewProgress = previewProgress
        self.accessibilityConfirm = accessibilityConfirm
        self.action = action
    }

    private var size: CGFloat { LiveCircleMetrics.diameter(accessibilitySize: typeSize.isAccessibilitySize) }
    private var shown: Double { previewProgress ?? progress }

    private var shownTitle: String {
        if contract.confirmed { return completedTitle }
        if showsHint, let tapHint { return tapHint }
        return title
    }

    public var body: some View {
        VStack(spacing: 11) {
            ZStack {
                Circle().fill(tint.opacity(0.15 + 0.2 * shown))
                Image(systemName: contract.confirmed ? "checkmark" : "stop.fill")
                    .font(.system(size: size * 0.32, weight: .bold))
                    .foregroundStyle(tint)
            }
            .frame(width: size, height: size)
            .overlay {
                // The ring sits just outside the circle: faint while idle, filling clockwise from the top as the hold runs.
                ZStack {
                    Circle().stroke(LivePalette.ring(tint), lineWidth: 2.5)
                    Circle().trim(from: 0, to: shown)
                        .stroke(tint, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .padding(-6)
            }
            .scaleEffect(contract.holding && !reduceMotion ? 0.97 : 1)
            Text(verbatim: shownTitle)
                .foregroundStyle(tint)
                .liveText(14, weight: .semibold, maxSize: 19, lines: 2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: max(size + 28, 104))
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        // The ring reaches 6 pt past the circle; the padding keeps a neighbour clear of it.
        .padding(6)
        .contentShape(Rectangle())
        .gesture(holdGesture)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(contract.confirmed ? completedTitle
                            : String(localized: "\(title). Hold to confirm", bundle: .module))
        .modifier(LiveHoldAccessibilityAction(perform: accessibilityConfirm))
        .onDisappear {
            cancelHold(playWarning: false)
            hintTask?.cancel()
        }
    }

    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in if previewProgress == nil { startHold() } }
            .onEnded { _ in
                if previewProgress == nil, !contract.confirmed { cancelHold(playWarning: true) }
            }
    }

    private func startHold() {
        guard contract.begin() else { return }
        StrandHaptic.light.play()
        hintTask?.cancel()
        showsHint = false
        withAnimation(.linear(duration: holdSeconds)) { progress = 1 }
        confirmationTask?.cancel()
        confirmationTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: UInt64(holdSeconds * 1_000_000_000))
            } catch { return }
            guard !Task.isCancelled, contract.complete() else { return }
            StrandHaptic.commit.play()
            action()
        }
    }

    private func cancelHold(playWarning: Bool) {
        confirmationTask?.cancel()
        confirmationTask = nil
        if !contract.confirmed {
            withAnimation(reduceMotion ? nil : StrandMotion.value) { progress = 0 }
            if playWarning {
                StrandHaptic.warning.play()
                flashHint()
            }
        }
        contract.cancel()
    }

    /// The label names what the hold needs for 1.5 seconds, then goes back to its title.
    private func flashHint() {
        guard tapHint != nil else { return }
        showsHint = true
        hintTask?.cancel()
        hintTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
            showsHint = false
        }
    }
}

private struct LiveHoldAccessibilityAction: ViewModifier {
    let perform: (() -> Void)?

    @ViewBuilder func body(content: Content) -> some View {
        if let perform {
            content.accessibilityAction(.default, perform)
        } else {
            content
        }
    }
}

/// Start: the one solid mint circle of the setup page, held for half a second to skip the countdown. The hold shows as a
/// ring that fills; a tap that ends a hold is not also a tap.
public struct LiveStartCircle: View {
    private let title: String
    private let tint: Color
    private let isEnabled: Bool
    private let holdSeconds: Double
    private let previewProgress: Double?
    private let onTap: () -> Void
    private let onHold: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var progress: Double = 0
    @State private var holdTask: Task<Void, Never>?
    /// A finger is down on the circle and its press has not ended or been cancelled.
    @State private var touching = false
    /// The hold ran its half second: lifting is not also a tap.
    @State private var held = false
    /// The finger slid away from the circle before the hold finished: the press is neither a hold nor a tap.
    @State private var aborted = false
    /// True exactly while a touch is down; SwiftUI resets it when the touch ends or is cancelled, which `onEnded` is not
    /// called for (the app resigned active, the gesture was removed).
    @GestureState private var isDown = false

    /// How far a finger may wander from where it landed and still mean this circle (a tap or the hold).
    private static let slop: CGFloat = 24

    public init(title: String, tint: Color = LivePalette.mint, isEnabled: Bool = true, holdSeconds: Double = 0.5,
                previewProgress: Double? = nil, onTap: @escaping () -> Void, onHold: @escaping () -> Void) {
        self.title = title
        self.tint = tint
        self.isEnabled = isEnabled
        self.holdSeconds = holdSeconds
        self.previewProgress = previewProgress
        self.onTap = onTap
        self.onHold = onHold
    }

    private var size: CGFloat { LiveCircleMetrics.startDiameter(accessibilitySize: typeSize.isAccessibilitySize) }
    private var shown: Double { previewProgress ?? progress }

    public var body: some View {
        VStack(spacing: 11) {
            Circle()
                .fill(isEnabled ? tint : LivePalette.fill)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.system(size: size * 0.38, weight: .bold))
                        .foregroundStyle(isEnabled ? Color.black : LivePalette.secondaryText)
                        .offset(x: size * 0.04)
                }
                .overlay {
                    // The hold: a ring that fills clockwise from the top.
                    Circle().trim(from: 0, to: shown)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(-7)
                }
            Text(verbatim: title)
                .foregroundStyle(isEnabled ? tint : LivePalette.secondaryText)
                .liveText(15, weight: .semibold, maxSize: 20, lines: 2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(7)
        .contentShape(Rectangle())
        .scaleEffect(shown > 0 ? 0.97 : 1)
        .gesture(isEnabled ? gesture : nil)
        // Not enabled: VoiceOver says "dimmed" and neither it nor Switch Control can activate it.
        .disabled(!isEnabled)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityAction(.default) { if isEnabled { onTap() } }
        .onChangeCompat(of: isDown) { down in
            guard !down else { return }
            // A touch that ended normally has already run `onEnded` by the time this turn comes round. One that was cancelled
            // has not, and would otherwise leave the hold running (and the ring full) with no finger down.
            Task { @MainActor in if touching { endTouch() } }
        }
        .onChangeCompat(of: isEnabled) { _ in endTouch() }
        .onDisappear { endTouch() }
    }

    /// Back to rest: the hold stops, the ring empties.
    private func endTouch() {
        holdTask?.cancel()
        holdTask = nil
        touching = false
        held = false
        aborted = false
        if progress != 0 { withAnimation(.easeOut(duration: 0.15)) { progress = 0 } }
    }

    private static func distance(_ value: DragGesture.Value) -> CGFloat {
        hypot(value.translation.width, value.translation.height)
    }

    /// A tap is a tap; a press held for `holdSeconds` is the hold, and lifting after it is not a second action. Sliding away
    /// from the circle abandons the press, as a long press does, so the workout never starts from a finger that left.
    private var gesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isDown) { _, state, _ in state = true }
            .onChanged { value in
                guard previewProgress == nil else { return }
                if !touching {
                    touching = true
                    held = false
                    aborted = false
                    withAnimation(.linear(duration: holdSeconds)) { progress = 1 }
                    holdTask = Task { @MainActor in
                        do { try await Task.sleep(nanoseconds: UInt64(holdSeconds * 1_000_000_000)) } catch { return }
                        guard !Task.isCancelled, touching, !aborted else { return }
                        held = true
                        StrandHaptic.commit.play()
                        onHold()
                    }
                } else if !held, !aborted, Self.distance(value) > Self.slop {
                    aborted = true
                    holdTask?.cancel()
                    holdTask = nil
                    withAnimation(.easeOut(duration: 0.15)) { progress = 0 }
                }
            }
            .onEnded { value in
                guard previewProgress == nil else { return }
                let tapped = touching && !held && !aborted && Self.distance(value) <= Self.slop
                endTouch()
                if tapped { onTap() }
            }
    }
}
