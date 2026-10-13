import SwiftUI

// MARK: - Sparse-window resolver
//
// The Metric Detail screen is a flat drill-in built from the widget primitives (`TrendsHeroChart`, `StatFooter`,
// `MetricValueRow`), so the card kit that used to live here (`MetricDetailHeroCard`, `MetricDetailTemplate` and
// their config) is gone. What stays is the pure sparse-window rule the screen still uses.

/// Pure, generic implementation of the sparse-window rule used by Explore.
public enum MetricDetailWindowResolver {
    public static func resolve<Row, Range>(
        selection: Range,
        widening: [Range],
        rows: [Row],
        slice: (Range, [Row]) -> [Row]
    ) -> (range: Range, rows: [Row]) {
        let candidates = widening.isEmpty ? [selection] : widening
        for candidate in candidates {
            let result = slice(candidate, rows)
            if !result.isEmpty { return (candidate, result) }
        }
        return (candidates.last ?? selection, [])
    }
}

// MARK: - Compare
//
// The series a Compare screen hands to `CompareOverlayChart`. The screen around it (the pickers, the verdict, the
// rows) is built from the flat widget primitives and lives in the app.

public struct ComparePoint: Identifiable, Equatable, Sendable {
    public let date: Date
    public let value: Double
    public var id: Date { date }

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

/// How a series' line is drawn on top of its colour, so two lines of nearly the same hue (Recovery's blue and Sleep's slate
/// blue) still differ by more than colour: A solid, B dashed, C dotted, D long-dash. The legend swatch (`CompareLineSwatch`)
/// draws the same pattern.
public enum CompareLineStyle: Equatable, Sendable, CaseIterable {
    case solid, dashed, dotted, longDash

    /// The style of the line in a slot (0 is A, in pick order). More than four slots start over.
    public static func forSlot(_ slot: Int) -> CompareLineStyle {
        let all = allCases
        return all[((slot % all.count) + all.count) % all.count]
    }

    /// The stroke's dash pattern for a line this wide, empty for a solid one. Lengths are the pen's own, so with round caps a
    /// dash shows `lineWidth` longer than its first number and a gap `lineWidth` shorter than its second.
    public func dash(lineWidth: CGFloat) -> [CGFloat] {
        switch self {
        case .solid: return []
        case .dashed: return [lineWidth * 2.2, lineWidth * 2.4]
        case .dotted: return [0.01, lineWidth * 2.4]
        case .longDash: return [lineWidth * 5, lineWidth * 3]
        }
    }
}

/// A short line in a series' colour and style: the legend's and the readouts' stand-in for the dot, so a reader who cannot
/// tell two hues apart can still tell which line is which.
public struct CompareLineSwatch: View {
    public static let width: CGFloat = 22
    private static let lineWidth: CGFloat = 2.2

    private let color: Color
    private let style: CompareLineStyle

    public init(color: Color, style: CompareLineStyle) {
        self.color = color
        self.style = style
    }

    public var body: some View {
        Path { path in
            path.move(to: CGPoint(x: Self.lineWidth / 2, y: 4))
            path.addLine(to: CGPoint(x: Self.width - Self.lineWidth / 2, y: 4))
        }
        .stroke(color, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, dash: style.dash(lineWidth: Self.lineWidth)))
        .frame(width: Self.width, height: 8)
        .accessibilityHidden(true)
    }
}

public struct CompareSeries {
    public let title: String
    public let unit: String
    public let tint: Color
    public let lineStyle: CompareLineStyle
    public let points: [ComparePoint]
    public let format: (Double) -> String
    /// The series' own range, found once so scaling every point stays linear in the number of points.
    let minValue: Double
    let maxValue: Double

    public init(
        title: String,
        unit: String,
        tint: Color,
        points: [ComparePoint],
        lineStyle: CompareLineStyle = .solid,
        format: @escaping (Double) -> String = { ComponentValueFormat.rounded($0) }
    ) {
        self.title = title
        self.unit = unit
        self.tint = tint
        self.lineStyle = lineStyle
        self.points = points.sorted { $0.date < $1.date }
        self.format = format
        let values = points.map(\.value)
        self.minValue = values.min() ?? 0
        self.maxValue = values.max() ?? 0
    }

    /// The value scaled to 0...1 within this series' own range, so metrics in different units share one axis. A flat
    /// series sits on the middle line so it still draws.
    func normalized(_ value: Double) -> Double {
        guard maxValue > minValue else { return 0.5 }
        return min(max((value - minValue) / (maxValue - minValue), 0), 1)
    }
}
