import SwiftUI

// MARK: - Shared parts of the Today widget headers and footers
//
// The Live HR, Stress and Health Monitor modules all open with the same eyebrow (a symbol in `caption`, an 8pt
// gap, the caps overline title) and close with the same compact chip. They live here once so the three
// modules cannot drift apart.

/// An eyebrow symbol in the domain colour. When `pulses`, a ghost copy of it swells and fades behind it at
/// `period` seconds (off under Reduce Motion), so a status that used to be a breathing dot keeps its life.
struct EyebrowPulseIcon: View {
    let systemName: String
    let color: Color
    var period: Double = 2
    /// How far the ghost swells before it has faded out.
    var spread: CGFloat = 1.7
    var pulses: Bool = true

    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isPulsing: Bool { pulses && !reduceMotion }

    var body: some View {
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
/// ink and the label turns to dark ink, the same selected look as `SegmentedPillControl`. The caller adds the
/// `.isSelected` accessibility trait to the button that wraps it.
public struct WidgetChip: View {
    private let title: LocalizedStringKey?
    private let systemImage: String?
    private let showsChevron: Bool
    private let overhangs: Bool
    private let isSelected: Bool
    /// Where `title` is looked up: this package's string table for the Today chips, or the app's (`nil`).
    private let bundle: Bundle?

    /// The height of one line of the chip's title, so an icon-only chip is as tall as a titled one.
    @ScaledMetric(relativeTo: .caption2) private var lineHeight: CGFloat = 13

    private init(title: LocalizedStringKey?, bundle: Bundle?, systemImage: String?, showsChevron: Bool,
                 overhangs: Bool, isSelected: Bool) {
        self.title = title
        self.bundle = bundle
        self.systemImage = systemImage
        self.showsChevron = showsChevron
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

    public var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
            }
            if let title {
                Text(title, bundle: bundle)
                    .font(StrandFont.micro.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: title == nil && systemImage != nil ? lineHeight : nil)
        .foregroundStyle(isSelected ? StrandPalette.onInk : StrandPalette.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule(style: .continuous).fill(isSelected ? StrandPalette.ink : StrandPalette.chipFill))
        .overlay(Capsule(style: .continuous).stroke(isSelected ? Color.clear : StrandPalette.hairline, lineWidth: 1))
        .padding(.vertical, overhangs ? -2 : 0)
    }
}

public extension View {
    /// Grows a small chip's tap area to the 44pt minimum without moving anything: the hit region reaches past the
    /// chip's layout bounds on every side.
    func chipHitTarget() -> some View {
        contentShape(Rectangle().inset(by: -13))
    }
}
