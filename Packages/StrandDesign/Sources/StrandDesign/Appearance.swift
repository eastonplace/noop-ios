import SwiftUI

// MARK: - App visual mode

/// The app has one supported data-visualization grammar. The legacy cases remain readable so
/// existing stored preferences do not break, but every value resolves to the WHOOP-aligned style.
public enum ChartStyle: String, CaseIterable, Identifiable, Sendable {
    case titanium
    case classic

    /// Settings only presents the supported style. The hidden legacy case remains decodable.
    public static let allCases: [ChartStyle] = [.titanium]

    public var id: String { rawValue }
    public static let storageKey = "chart.style"

    public var label: String {
        String(localized: "WHOOP", bundle: .module)
    }

    /// Resolve all stored values to the single supported data style.
    public static func resolve(_ raw: String) -> ChartStyle {
        _ = raw
        return .titanium
    }
}

public extension View {
    /// Apply the single supported chart style without changing view identity.
    ///
    /// The former implementation keyed the complete app tree by the stored value. That forced
    /// every visible screen, task, scroll position, and chart to rebuild when the preference changed.
    /// A fixed style needs no identity reset.
    func chartStyle(_ raw: String) -> some View {
        StrandPalette.chartStyle = ChartStyle.resolve(raw)
        return self
    }
}

/// The app uses one fixed dark appearance. Legacy raw values remain decodable for migration safety.
public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    /// Keep the stored default selected while exposing only one supported choice in old pickers.
    public static let allCases: [AppearanceMode] = [.system]

    public var id: String { rawValue }
    public static let storageKey = "theme.appearance"

    public var label: String {
        String(localized: "WHOOP Dark", bundle: .module)
    }

    public var symbol: String { "moon.stars.fill" }

    /// Every legacy preference resolves to dark.
    public var colorScheme: ColorScheme? { .dark }

    public static func resolve(_ raw: String) -> AppearanceMode {
        _ = raw
        return .system
    }
}

/// Retained only to read existing preference storage. Today no longer renders a day-cycle scene.
public enum SceneBackgroundPrefs {
    public static let enabledKey = "noop.showDayCycleBackground"
    public static let isEnabled = false
}

// MARK: - Dark-surface effects

/// A restrained additive bloom for score rings, chart heads, and hero highlights.
private struct AdditiveBloom: ViewModifier {
    func body(content: Content) -> some View {
        content
            .blendMode(.plusLighter)
            .opacity(0.45)
    }
}

/// One elevation model for all card and floating surfaces.
private struct NoopElevation: ViewModifier {
    var hovering: Bool

    func body(content: Content) -> some View {
        content.shadow(
            color: Color.black.opacity(hovering ? 0.42 : 0.18),
            radius: hovering ? 18 : 10,
            x: 0,
            y: hovering ? 8 : 4
        )
    }
}

public extension View {
    func additiveBloom() -> some View {
        modifier(AdditiveBloom())
    }

    func noopElevation(hovering: Bool = false) -> some View {
        modifier(NoopElevation(hovering: hovering))
    }
}
