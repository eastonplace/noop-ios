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

public struct CompareSeries {
    public let title: String
    public let unit: String
    public let tint: Color
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
        format: @escaping (Double) -> String = { ComponentValueFormat.rounded($0) }
    ) {
        self.title = title
        self.unit = unit
        self.tint = tint
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
