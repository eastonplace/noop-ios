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

    var body: some View {
        Image(systemName: systemName)
            .font(StrandFont.caption)
            .foregroundStyle(color)
            .background {
                if pulses && !reduceMotion {
                    Image(systemName: systemName)
                        .font(StrandFont.caption)
                        .foregroundStyle(color.opacity(0.4))
                        .scaleEffect(breathing ? spread : 0.9)
                        .opacity(breathing ? 0 : 0.8)
                }
            }
            .onAppear {
                guard pulses, !reduceMotion else { return }
                withAnimation(.easeOut(duration: max(period, 0.5)).repeatForever(autoreverses: false)) {
                    breathing = true
                }
            }
            .accessibilityHidden(true)
    }
}

/// The compact footer / header chip: an optional symbol, a title, and a chevron on a quiet capsule ("2H ›",
/// "Details ›", "Customise"). Its capsule is drawn a little taller than the layout it claims, so a row that
/// carries it grows by 2pt rather than by the full padding.
struct WidgetChip: View {
    let title: LocalizedStringKey?
    var systemImage: String? = nil
    var showsChevron: Bool = true

    init(_ title: LocalizedStringKey? = nil, systemImage: String? = nil, showsChevron: Bool = true) {
        self.title = title
        self.systemImage = systemImage
        self.showsChevron = showsChevron
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
            }
            if let title {
                Text(title, bundle: .module)
                    .font(StrandFont.micro.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
        }
        .foregroundStyle(StrandPalette.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(Capsule(style: .continuous).stroke(StrandPalette.hairline, lineWidth: 1))
        .padding(.vertical, -2)
    }
}
