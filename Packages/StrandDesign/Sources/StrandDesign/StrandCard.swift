import SwiftUI

// MARK: - Shared card surface

public extension View {
    /// Apply the shared dark card surface. A metric tint adds a quiet corner wash while the card
    /// chrome stays neutral. Existing call sites and component structure remain unchanged.
    func frostedCardSurface(
        tint: Color? = nil,
        cornerRadius: CGFloat = NoopMetrics.cardRadius,
        washStrength: Double = 1.0
    ) -> some View {
        background(
            FrostedCardSurface(
                tint: tint,
                cornerRadius: cornerRadius,
                washStrength: washStrength
            )
        )
    }
}

/// One card background for all modules. The gradient follows WHOOP's dark graphite surface.
public struct FrostedCardSurface: View {
    public var tint: Color?
    public var cornerRadius: CGFloat
    public var washStrength: Double

    public init(
        tint: Color? = nil,
        cornerRadius: CGFloat = NoopMetrics.cardRadius,
        washStrength: Double = 1.0
    ) {
        self.tint = tint
        self.cornerRadius = cornerRadius
        self.washStrength = washStrength
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let strength = min(max(washStrength, 0), 1)

        ZStack {
            shape.fill(
                LinearGradient(
                    colors: [StrandPalette.cardFillTop, StrandPalette.cardFillBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

            if let tint {
                shape.fill(
                    LinearGradient(
                        colors: [tint.opacity(0.12 * strength), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }

            shape.strokeBorder(StrandPalette.cardBorder, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.24), radius: 10, x: 0, y: 5)
    }
}

// MARK: - StrandCard

public struct StrandCard<Content: View>: View {
    public var padding: CGFloat
    public var cornerRadius: CGFloat
    public var tint: Color?
    @ViewBuilder public var content: () -> Content
    @Environment(\.contentSurfacePresentation) private var contentSurfacePresentation

    public init(
        padding: CGFloat = 16,
        cornerRadius: CGFloat = NoopMetrics.cardRadius,
        tint: Color? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.tint = tint
        self.content = content
    }

    @ViewBuilder public var body: some View {
        #if os(iOS)
        if contentSurfacePresentation == .flat {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, min(padding, NoopMetrics.space3))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(StrandPalette.hairline)
                        .frame(height: 1)
                        .accessibilityHidden(true)
                }
        } else {
            boundedBody
        }
        #else
        boundedBody
        #endif
    }

    private var boundedBody: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frostedCardSurface(tint: tint, cornerRadius: cornerRadius)
            .strandCardHover(cornerRadius: cornerRadius)
    }
}

// MARK: - Hover lift

public struct StrandCardHover: ViewModifier {
    public var cornerRadius: CGFloat
    @State private var hovering = false

    public init(cornerRadius: CGFloat = NoopMetrics.cardRadius) {
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1)
                    .opacity(hovering ? 1 : 0)
            )
            .shadow(
                color: hovering ? Color.black.opacity(0.34) : .clear,
                radius: hovering ? 12 : 0,
                x: 0,
                y: hovering ? 6 : 0
            )
            .offset(y: hovering ? -1 : 0)
            .animation(StrandMotion.interactive, value: hovering)
            #if !os(watchOS)
            .onHover { hovering = $0 }
            #endif
    }
}

public extension View {
    func strandCardHover(cornerRadius: CGFloat = NoopMetrics.cardRadius) -> some View {
        modifier(StrandCardHover(cornerRadius: cornerRadius))
    }
}

// MARK: - Touch feedback

public struct StrandPressableButtonStyle: ButtonStyle {
    public var cornerRadius: CGFloat
    public var scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(cornerRadius: CGFloat = NoopMetrics.cardRadius, scale: CGFloat = 0.985) {
        self.cornerRadius = cornerRadius
        self.scale = scale
    }

    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .scaleEffect(reduceMotion ? 1 : (pressed ? scale : 1))
            .opacity(reduceMotion && pressed ? 0.82 : 1)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1)
                    .opacity(pressed ? 1 : 0)
            )
            .animation(StrandMotion.interactive, value: pressed)
            .contentShape(Rectangle())
    }
}

public struct StrandPressableModifier: ViewModifier {
    public var cornerRadius: CGFloat
    public var scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var pressed = false

    public init(cornerRadius: CGFloat = NoopMetrics.cardRadius, scale: CGFloat = 0.985) {
        self.cornerRadius = cornerRadius
        self.scale = scale
    }

    public func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion ? 1 : (pressed ? scale : 1))
            .opacity(reduceMotion && pressed ? 0.82 : 1)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1)
                    .opacity(pressed ? 1 : 0)
            )
            .animation(StrandMotion.interactive, value: pressed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressed) { _, state, _ in state = true }
            )
    }
}

public extension View {
    func strandPressable(
        cornerRadius: CGFloat = NoopMetrics.cardRadius,
        scale: CGFloat = 0.985
    ) -> some View {
        modifier(StrandPressableModifier(cornerRadius: cornerRadius, scale: scale))
    }
}

#if DEBUG && !os(watchOS)
#Preview("StrandCard") {
    VStack(spacing: 16) {
        StrandCard(tint: StrandPalette.sleepAccent) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sleep performance").strandOverline()
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("87")
                        .font(StrandFont.number(34))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("%")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Text("7h 42m asleep · 92% efficiency")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }

        StrandCard {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Resting HR").strandOverline()
                    Text("51 bpm")
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Spacer()
                Sparkline(values: (0..<30).map { index -> Double in
                    50 + 4 * sin(Double(index) / 5)
                })
                .frame(width: 120, height: 40)
            }
        }
    }
    .padding(28)
    .frame(width: 420, height: 360)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
