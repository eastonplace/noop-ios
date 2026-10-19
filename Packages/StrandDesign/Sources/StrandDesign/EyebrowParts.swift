import SwiftUI

// MARK: - Shared parts of the Today widget headers and footers
//
// The Live HR, Stress and Health Monitor modules all open with the same eyebrow (a symbol in `caption`, an 8pt
// gap, the caps overline title) and close with the same compact chip. They live here once so the three
// modules cannot drift apart.

/// An eyebrow symbol in the domain colour. When `pulses`, a ghost copy of it swells and fades behind it at
/// `period` seconds (off under Reduce Motion), so a status that used to be a breathing dot keeps its life.
public struct EyebrowPulseIcon: View {
    let systemName: String
    let color: Color
    var period: Double = 2
    /// How far the ghost swells before it has faded out.
    var spread: CGFloat = 1.7
    var pulses: Bool = true

    public init(systemName: String, color: Color, period: Double = 2, spread: CGFloat = 1.7, pulses: Bool = true) {
        self.systemName = systemName
        self.color = color
        self.period = period
        self.spread = spread
        self.pulses = pulses
    }

    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.strandRendersStatically) private var rendersStatically

    private var isPulsing: Bool { pulses && !reduceMotion && !rendersStatically }

    public var body: some View {
        Image(systemName: systemName)
            .font(StrandFont.caption)
            .foregroundStyle(color)
            .background {
                if isPulsing {
                    Image(systemName: systemName)
                        .font(StrandFont.caption)
                        .foregroundStyle(color.opacity(0.4))
                        .scaleEffect(breathing ? spread : 0.9)
                        .opacity(breathing ? 0 : 0.8)
                }
            }
            // Driven by the state, not by appearance: a Live HR card that appeared before its first sample starts
            // pulsing when the sample arrives, Reduce Motion turning off restarts it, and a new period takes effect.
            .onAppear(perform: restart)
            .onChangeCompat(of: isPulsing) { _ in restart() }
            .onChangeCompat(of: period) { _ in restart() }
            .accessibilityHidden(true)
    }

    /// Settles the ghost without animation, then (when pulsing) starts the repeating swell on the next turn so the
    /// ghost, which is inserted in this same update, animates from its resting state rather than appearing swollen.
    private func restart() {
        var settle = Transaction()
        settle.disablesAnimations = true
        withTransaction(settle) { breathing = false }
        guard isPulsing else { return }
        let duration = max(period, 0.5)
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: duration).repeatForever(autoreverses: false)) { breathing = true }
        }
    }
}

public extension EnvironmentValues {
    /// Set by a host that draws a snapshot of the view rather than running it: a Live Activity, whose Lock Screen card
    /// and Dynamic Island the system renders in the widget extension against a watchdog. Nothing there starts a task or a
    /// repeating animation (the system would not play it anyway), so the render is done when the layout is.
    @Entry var strandRendersStatically: Bool = false
}

/// The compact footer / header chip: an optional symbol, a title, and a chevron on a quiet capsule ("2H ›",
/// "Details ›", "Customise"). By default its capsule is drawn a little taller than the layout it claims, so a
/// footer row that carries it grows by 2pt rather than by the full padding. A header row passes
/// `overhangs: false`, so the chip's whole height is part of the row, like the state pill's.
///
/// With a symbol and no title it is the matching icon button: same capsule, same height as a titled chip beside
/// it, so a title row can carry "Explore" and a share glyph as one family. The caller supplies the accessibility
/// label (a titled chip reads its title) and a 44pt tap area with `chipHitTarget()`.
///
/// A chip that is one of a set of choices (a topic filter) passes `isSelected`: the capsule fills with the brand
/// ink and the label turns to dark ink. That solid fill is deliberately a different, stronger state than the flat tabs of
/// `SegmentedPillControl` (a soft thumb behind a coloured label): a chip filter is a set of independent toggles, not a range. The caller adds the
/// `.isSelected` accessibility trait to the button that wraps it.
public struct WidgetChip: View {
    private let title: LocalizedStringKey?
    /// A title that is already text in the person's language (a sport, a source), never looked up.
    private let verbatimTitle: String?
    private let systemImage: String?
    private let showsChevron: Bool
    private let chevronSymbol: String
    private let overhangs: Bool
    private let isSelected: Bool
    /// Where `title` is looked up: this package's string table for the Today chips, or the app's (`nil`).
    private let bundle: Bundle?

    /// The height of one line of the chip's title, so an icon-only chip is as tall as a titled one.
    @ScaledMetric(relativeTo: .caption2) private var lineHeight: CGFloat = 13

    private init(title: LocalizedStringKey?, verbatimTitle: String? = nil, bundle: Bundle?, systemImage: String?,
                 showsChevron: Bool, chevronSymbol: String = "chevron.right", overhangs: Bool, isSelected: Bool) {
        self.title = title
        self.verbatimTitle = verbatimTitle
        self.bundle = bundle
        self.systemImage = systemImage
        self.showsChevron = showsChevron
        self.chevronSymbol = chevronSymbol
        self.overhangs = overhangs
        self.isSelected = isSelected
    }

    public init(_ title: LocalizedStringKey? = nil, systemImage: String? = nil, showsChevron: Bool = true,
                overhangs: Bool = true, isSelected: Bool = false) {
        self.init(title: title, bundle: .module, systemImage: systemImage, showsChevron: showsChevron,
                  overhangs: overhangs, isSelected: isSelected)
    }

    /// A chip built in the app, whose title is in the app's own string table (so it localises with the screen).
    public init(appTitle title: LocalizedStringKey, systemImage: String? = nil, showsChevron: Bool = true,
                overhangs: Bool = true, isSelected: Bool = false) {
        self.init(title: title, bundle: nil, systemImage: systemImage, showsChevron: showsChevron,
                  overhangs: overhangs, isSelected: isSelected)
    }

    /// A chip whose title is text already in the person's language (the current choice of a filter), with a
    /// down-pointing chevron when it opens a menu.
    public init(verbatimTitle: String, systemImage: String? = nil, showsChevron: Bool = true,
                opensMenu: Bool = false, overhangs: Bool = false, isSelected: Bool = false) {
        self.init(title: nil, verbatimTitle: verbatimTitle, bundle: nil, systemImage: systemImage,
                  showsChevron: showsChevron, chevronSymbol: opensMenu ? "chevron.down" : "chevron.right",
                  overhangs: overhangs, isSelected: isSelected)
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
            }
            if let verbatimTitle {
                Text(verbatim: verbatimTitle)
                    .font(StrandFont.micro.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            } else if let title {
                Text(title, bundle: bundle)
                    .font(StrandFont.micro.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if showsChevron {
                Image(systemName: chevronSymbol)
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: title == nil && verbatimTitle == nil && systemImage != nil ? lineHeight : nil)
        .foregroundStyle(isSelected ? StrandPalette.onInk : StrandPalette.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule(style: .continuous).fill(isSelected ? StrandPalette.ink : StrandPalette.chipFill))
        .overlay(Capsule(style: .continuous).stroke(isSelected ? Color.clear : StrandPalette.hairline, lineWidth: 1))
        .padding(.vertical, overhangs ? -2 : 0)
    }
}

/// How far a chip's tap area reaches past its drawn capsule, horizontally and vertically. A lone chip reaches 13pt
/// on every side (44pt for a 18pt chip). Chips in a `ChipRow` reach only as far as half the gap to their neighbour on
/// that axis, so neighbouring tap areas meet and never overlap a neighbour's visible edge.
struct ChipHitInsets: Equatable {
    var horizontal: CGFloat = 13
    var vertical: CGFloat = 13
}

private struct ChipHitInsetsKey: EnvironmentKey {
    static let defaultValue = ChipHitInsets()
}

extension EnvironmentValues {
    var chipHitInsets: ChipHitInsets {
        get { self[ChipHitInsetsKey.self] }
        set { self[ChipHitInsetsKey.self] = newValue }
    }
}

private struct ChipHitShape: Shape {
    let insets: ChipHitInsets
    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: -insets.horizontal, dy: -insets.vertical))
    }
}

private struct ChipHitTarget: ViewModifier {
    @Environment(\.chipHitInsets) private var insets
    func body(content: Content) -> some View {
        content.contentShape(ChipHitShape(insets: insets))
    }
}

public extension View {
    /// Grows a small chip's tap area to the 44pt minimum without moving anything: the hit region reaches past the
    /// chip's layout bounds. Inside a `ChipRow` it stops short of the chip's neighbours.
    func chipHitTarget() -> some View {
        modifier(ChipHitTarget())
    }
}
