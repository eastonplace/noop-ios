import SwiftUI

// MARK: - Widget design language
//
// The look of the Coach in-chat cards, extracted as reusable primitives: a domain tint (accent colour,
// quiet gradient wash, thin border), a caps eyebrow with a leading domain symbol, a hero value, metric
// rows, a stat footer, and the spacing and chart defaults that go with them.
//
// These primitives compose directly on the flat canvas. `WidgetCard` (WidgetCard.swift) is the one
// bounded container, for the places where a card is the right choice. Nothing here hard-codes a colour;
// everything is derived from `StrandPalette` and `NoopMetrics`.

// MARK: - Metrics

public enum WidgetMetrics {
    // MARK: Card chrome
    /// Corner radius of a `WidgetCard` (continuous).
    public static let cornerRadius: CGFloat = NoopMetrics.radius4
    /// Interior padding of a `WidgetCard` on all four sides.
    public static let cardPadding: CGFloat = NoopMetrics.cardPadding
    /// Border thickness.
    public static let borderWidth: CGFloat = 1
    /// Strength of the domain wash at the card's top-leading corner.
    public static let washOpacity: Double = 0.12

    // MARK: Rhythm (cards and flat sections share it)
    /// Gap between a section's eyebrow header and its content.
    public static let headerSpacing: CGFloat = NoopMetrics.space3
    /// Gap between stacked elements inside a section (hero to chart, chart to stat footer).
    public static let contentSpacing: CGFloat = NoopMetrics.space3
    /// Gap between two widget cards stacked in a column.
    public static let interCardSpacing: CGFloat = NoopMetrics.space3
    /// Gap between two flat sections on the canvas.
    public static let sectionSpacing: CGFloat = NoopMetrics.space6

    // MARK: Type sizes (before Dynamic Type scaling)
    /// Point size of a hero value.
    public static let heroValueSize: CGFloat = 34
    /// Point size of a prominent stat value.
    public static let statValueSize: CGFloat = 20
    /// Width of the icon column in a metric row.
    public static let metricIconWidth: CGFloat = 18

    // MARK: Charts
    /// Height of a chart inside a section or card.
    public static let chartHeight: CGFloat = 112
    /// Most x-axis labels a chart shows at phone width. More than this and the dates collide.
    public static let maxXAxisLabels = 4

    // MARK: Missing data
    /// What a missing value reads as. Never zero, never blank.
    public static let missingValue = "—"
}

// MARK: - Tint

/// The domain a section or card belongs to. A tint supplies the accent colour (icon, chart ink), the
/// quiet background wash and the border, so a tinted card and the flat sections around it agree.
public enum DomainTint: Sendable {
    /// Recovery band colour for a 0...100 score (green / yellow / red). A missing score is neutral grey.
    case recovery(score: Double?)
    case sleep
    case strain
    case stress
    case hrv
    case heart
    case journal
    case workout
    /// The app's teal action accent.
    case accent
    /// No domain: graphite surface, no wash.
    case neutral
    case custom(Color)

    /// Effort shares the strain colour.
    public static var effort: DomainTint { .strain }

    /// Icon / chart ink for this domain.
    public var accent: Color {
        switch self {
        case .recovery(let score): return score.map { RecoveryBands.color(for: $0) } ?? StrandPalette.textTertiary
        case .sleep: return StrandPalette.sleepAccent
        case .strain, .workout: return StrandPalette.strainAccent
        case .stress: return StrandPalette.stressAccent
        case .hrv: return StrandPalette.metricCyan
        case .heart: return StrandPalette.metricRose
        case .journal: return StrandPalette.journalAccent
        case .accent: return StrandPalette.accent
        case .neutral: return StrandPalette.textSecondary
        case .custom(let color): return color
        }
    }

    /// Corner wash colour, or `nil` for a neutral surface.
    public var wash: Color? {
        if case .neutral = self { return nil }
        return accent
    }

    /// The graphite surface every card shares, top-leading to bottom-trailing.
    public var surfaceGradient: LinearGradient {
        LinearGradient(
            colors: [StrandPalette.cardFillTop, StrandPalette.cardFillBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// The domain wash laid over `surfaceGradient`, or `nil` for a neutral surface.
    public var washGradient: LinearGradient? {
        wash.map {
            LinearGradient(
                colors: [$0.opacity(WidgetMetrics.washOpacity), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    /// Thin card border.
    public var border: Color { StrandPalette.cardBorder }

    /// Gradient for a chart drawn in this domain: the recovery bands for recovery, the rest ramp for
    /// sleep, otherwise a fade up to the accent.
    public var chartGradient: Gradient {
        switch self {
        case .recovery: return StrandPalette.recoveryGradient
        case .sleep: return StrandPalette.restGradient
        default: return Gradient(colors: [accent.opacity(0.55), accent])
        }
    }
}
