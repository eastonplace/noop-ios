import SwiftUI

// MARK: - Widget card
//
// The one bounded container of the widget design language: a continuously-rounded card with a quiet
// domain wash and a thin border, the look of the Coach in-chat cards. Reach for it where a card is the
// right shape (a chat answer, a single hero summary). Ordinary screen sections are NOT cards: compose
// `SectionEyebrow`, `HeroValue`, `MetricValueRow` and `StatFooter` directly on the canvas instead.

/// The card background: graphite gradient, optional domain wash, thin border, soft drop shadow.
public struct WidgetCardSurface: View {
    public var tint: DomainTint
    public var cornerRadius: CGFloat

    public init(tint: DomainTint = .neutral, cornerRadius: CGFloat = WidgetMetrics.cornerRadius) {
        self.tint = tint
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(tint.surfaceGradient)
            if let wash = tint.washGradient {
                shape.fill(wash)
            }
            shape.strokeBorder(tint.border, lineWidth: WidgetMetrics.borderWidth)
        }
        .shadow(color: Color.black.opacity(0.24), radius: 10, x: 0, y: 5)
    }
}

public extension View {
    /// Wrap this view in the widget card chrome: padding, full-width leading alignment and the surface.
    /// Use for a header-less card; use `WidgetCard` when the card has an eyebrow header.
    func widgetCardSurface(
        tint: DomainTint = .neutral,
        padding: CGFloat = WidgetMetrics.cardPadding,
        cornerRadius: CGFloat = WidgetMetrics.cornerRadius
    ) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WidgetCardSurface(tint: tint, cornerRadius: cornerRadius))
    }
}

/// A bounded widget card: `SectionEyebrow` header over free-form content.
///
/// With an `action`, the whole card is a button with press feedback and (by default) a trailing
/// chevron. Without one it is a plain container.
public struct WidgetCard<Content: View>: View {
    private let title: String
    private let systemImage: String?
    private let tint: DomainTint
    private let trailing: EyebrowTrailing
    private let action: (() -> Void)?
    private let showsChevron: Bool
    @ViewBuilder private let content: () -> Content

    public init(
        title: String,
        systemImage: String? = nil,
        tint: DomainTint = .neutral,
        trailing: EyebrowTrailing = .none,
        action: (() -> Void)? = nil,
        showsChevron: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.trailing = trailing
        self.action = action
        self.showsChevron = showsChevron
        self.content = content
    }

    public var body: some View {
        if let action {
            Button(action: action) { card }
                .buttonStyle(StrandPressableButtonStyle(cornerRadius: WidgetMetrics.cornerRadius))
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow(
                title: title,
                systemImage: systemImage,
                tint: tint,
                trailing: trailing,
                showsChevron: action != nil && showsChevron
            )
            content()
        }
        .widgetCardSurface(tint: tint)
    }
}
