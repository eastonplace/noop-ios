import SwiftUI

/// A tiny optional-icon badge promoted from the NOOP design lab.
public struct MicroBadge: View {
    private let title: LocalizedStringKey
    private let systemImage: String?
    private let tint: Color

    public init(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        tint: Color = StrandPalette.textPrimary
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 8, weight: .bold))
                    .accessibilityHidden(true)
            }
            Text(title).textCase(.uppercase)
        }
        .font(StrandFont.micro.weight(.bold))
        .tracking(0.5)
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(tint.opacity(0.09), in: Capsule(style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A leaf-level live-status dot. Its repeating pulse disappears under Reduce Motion.
public struct MicroStatusDot: View {
    private let color: Color
    private let isActive: Bool
    private let diameter: CGFloat

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(color: Color, isActive: Bool = false) {
        self.init(color: color, isActive: isActive, diameter: 8)
    }

    init(color: Color, isActive: Bool, diameter: CGFloat) {
        self.color = color
        self.isActive = isActive
        self.diameter = diameter
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .overlay {
                if isActive && !reduceMotion {
                    Circle()
                        .stroke(color.opacity(0.34), lineWidth: max(2, diameter / 2))
                        .scaleEffect(pulse ? 1.7 : 0.8)
                        .opacity(pulse ? 0 : 1)
                }
            }
            .onAppear(perform: updatePulse)
            .onChangeCompat(of: isActive) { _ in updatePulse() }
            .onChangeCompat(of: reduceMotion) { _ in updatePulse() }
            .accessibilityHidden(true)
    }

    private func updatePulse() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { pulse = false }
        guard isActive, !reduceMotion else { return }
        withAnimation(.easeOut(duration: 1.25).repeatForever(autoreverses: false)) {
            pulse = true
        }
    }
}

/// A compact step indicator for discrete journeys, never determinate progress.
public struct ProgressDots: View {
    private let count: Int
    private let current: Int
    private let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(count: Int, current: Int, tint: Color = StrandPalette.accent) {
        self.count = max(0, count)
        self.current = current
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index == normalizedCurrent ? tint : StrandPalette.cardBorder)
                    .frame(width: index == normalizedCurrent ? 22 : 7, height: 7)
            }
        }
        .animation(reduceMotion ? nil : StrandMotion.press, value: normalizedCurrent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(count: count, current: current))
    }

    private var normalizedCurrent: Int {
        guard count > 0 else { return 0 }
        return min(max(current, 0), count - 1)
    }

    static func accessibilityLabel(count: Int, current: Int) -> String {
        guard count > 0 else { return String(localized: "No steps", bundle: .module) }
        let step = min(max(current, 0), count - 1) + 1
        return String(localized: "Step \(step) of \(count)", bundle: .module)
    }
}

/// A circular icon action promoted from the NOOP design lab with a 44-point hit target.
public struct MicroIconButton: View {
    private let systemImage: String
    private let label: LocalizedStringKey
    private let isSelected: Bool
    private let action: () -> Void

    public init(
        systemImage: String,
        label: LocalizedStringKey,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.label = label
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isSelected ? StrandPalette.onInk : StrandPalette.textPrimary)
                .frame(width: 44, height: 44)
                .background(
                    isSelected ? StrandPalette.ink : StrandPalette.surfaceInset,
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(StrandPressableButtonStyle(cornerRadius: 22, scale: 0.975))
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#if DEBUG
private struct MicroPrimitivesPreview: View {
    @State private var current = 1
    @State private var selected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                MicroStatusDot(color: StrandPalette.statusPositive, isActive: true)
                MicroBadge("Synced", systemImage: "checkmark", tint: StrandPalette.statusPositive)
                MicroBadge("Local", systemImage: "lock.fill", tint: StrandPalette.accent)
            }
            ProgressDots(count: 4, current: current)
                .onTapGesture { current = (current + 1) % 4 }
            HStack {
                MicroIconButton(systemImage: "heart.fill", label: "Favorite", isSelected: selected) {
                    selected.toggle()
                }
                MicroIconButton(systemImage: "ellipsis", label: "More") {}
            }
        }
        .padding()
        .background(StrandPalette.canvas)
    }
}

#Preview("Micro primitives") { MicroPrimitivesPreview() }
#endif
