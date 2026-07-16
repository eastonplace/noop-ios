import SwiftUI

/// Presentation policy for ordinary information containers.
///
/// Package consumers default to ``bounded``. The NOOP iOS app opts into ``flat`` at
/// its root, so widgets, macOS, watchOS, previews, and other package clients retain
/// the established card treatment unless they explicitly request the new grammar.
public enum ContentSurfacePresentation: Sendable {
    case bounded
    case flat
}

public enum ContentSectionBoundary: Sendable {
    case none
    case top
    case bottom
    case both
}

public extension EnvironmentValues {
    @Entry var contentSurfacePresentation: ContentSurfacePresentation = .bounded
}

public extension View {
    /// Select the presentation of ordinary information containers below this view.
    func contentSurfacePresentation(_ presentation: ContentSurfacePresentation) -> some View {
        environment(\.contentSurfacePresentation, presentation)
    }

    /// Full-width information/list row that is flat in the opted-in iOS app and a
    /// traditional bounded surface elsewhere. Padding lives here so flat rows do not
    /// accidentally retain card-era horizontal insets.
    func contentRowSurface(
        boundedPadding: CGFloat = NoopMetrics.cardPadding,
        flatVerticalPadding: CGFloat = NoopMetrics.space3,
        cornerRadius: CGFloat = NoopMetrics.cardRadius
    ) -> some View {
        modifier(ContentRowSurfaceModifier(
            boundedPadding: boundedPadding,
            flatVerticalPadding: flatVerticalPadding,
            cornerRadius: cornerRadius
        ))
    }
}

private struct ContentRowSurfaceModifier: ViewModifier {
    let boundedPadding: CGFloat
    let flatVerticalPadding: CGFloat
    let cornerRadius: CGFloat
    @Environment(\.contentSurfacePresentation) private var presentation

    @ViewBuilder func body(content: Content) -> some View {
        #if os(iOS)
        if presentation == .flat {
            content
                .padding(.vertical, flatVerticalPadding)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(StrandPalette.hairline)
                        .frame(height: 1)
                        .accessibilityHidden(true)
                }
        } else {
            bounded(content)
        }
        #else
        bounded(content)
        #endif
    }

    private func bounded(_ content: Content) -> some View {
        content
            .padding(boundedPadding)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(FrostedCardSurface(cornerRadius: cornerRadius))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Canonical information-section container.
///
/// On iPhone/iPad under the app's `.flat` environment it contributes only vertical
/// rhythm and optional hairlines. In every other context it preserves the familiar
/// bounded `StrandCard` surface. Controls and overlays should continue to use their
/// dedicated components rather than this type.
public struct ContentSection<Content: View>: View {
    private let verticalPadding: CGFloat
    private let boundedPadding: CGFloat
    private let boundary: ContentSectionBoundary
    @ViewBuilder private let content: () -> Content

    @Environment(\.contentSurfacePresentation) private var presentation

    public init(
        verticalPadding: CGFloat = NoopMetrics.space3,
        boundedPadding: CGFloat = NoopMetrics.cardPadding,
        boundary: ContentSectionBoundary = .bottom,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.verticalPadding = verticalPadding
        self.boundedPadding = boundedPadding
        self.boundary = boundary
        self.content = content
    }

    @ViewBuilder public var body: some View {
        #if os(iOS)
        if presentation == .flat {
            flatBody
        } else {
            StrandCard(padding: boundedPadding, content: content)
        }
        #else
        StrandCard(padding: boundedPadding, content: content)
        #endif
    }

    private var flatBody: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, verticalPadding)
            .overlay(alignment: .top) {
                if boundary == .top || boundary == .both { divider }
            }
            .overlay(alignment: .bottom) {
                if boundary == .bottom || boundary == .both { divider }
            }
    }

    private var divider: some View {
        Rectangle()
            .fill(StrandPalette.hairline)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

#Preview("Flat content section") {
    VStack(spacing: 0) {
        ContentSection {
            Text("Recovery over time")
            Text("Charts and metrics sit directly on the page.")
                .foregroundStyle(StrandPalette.textSecondary)
        }
        ContentSection(boundary: .none) {
            Text("Next section")
        }
    }
    .padding(.horizontal, NoopMetrics.screenHPadding)
    .contentSurfacePresentation(.flat)
    .background(StrandPalette.appCanvas)
}
