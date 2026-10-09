import SwiftUI

// MARK: - Stress load

public struct StressLoadPoint: Identifiable, Equatable, Sendable {
    public let id: Int
    public let hour: Int
    public let level: Double?

    public init(id: Int, hour: Int, level: Double?) {
        self.id = id
        self.hour = hour
        self.level = level
    }
}

public enum StressLoadStyle {
    public static let calm = StrandPalette.accent
    public static let moderate = StrandPalette.statusPositive
    public static let high = StrandPalette.statusWarning

    public static let stops: [Gradient.Stop] = [
        .init(color: calm, location: 0),
        .init(color: moderate, location: 0.5),
        .init(color: high, location: 1),
    ]

    public static let gradient = Gradient(stops: stops)

    public static func color(for level: Double) -> Color {
        StrandPalette.sample(stops: stops, at: min(max(level / 3, 0), 1))
    }
}

/// A reusable, visual-only autonomic-load chart. It is intentionally a custom SwiftUI
/// `Path`, not an Apple Swift Charts `Chart`: the component needs a tightly controlled
/// gradient stroke, peak bead, reveal animation, and compact in-card legend.
public struct StressLoadChart: View {
    public let points: [StressLoadPoint]
    public let peakID: Int?
    public let hourLabel: (Int) -> String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    public init(
        points: [StressLoadPoint],
        peakID: Int? = nil,
        hourLabel: @escaping (Int) -> String
    ) {
        self.points = points
        self.peakID = peakID
        self.hourLabel = hourLabel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            header
            plot.frame(height: 110)
            timeAxis
            StressBandLegend()
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.85).delay(0.1)) {
                revealed = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var scored: [(point: StressLoadPoint, level: Double)] {
        points.compactMap { point in point.level.map { (point, $0) } }
    }

    private var peak: (point: StressLoadPoint, level: Double)? {
        if let peakID, let match = scored.first(where: { $0.point.id == peakID }) { return match }
        return scored.max(by: { $0.level < $1.level })
    }

    private var header: some View {
        HStack {
            Text("Hourly load")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
            Spacer()
            if let peak {
                Text("PEAK \(String(format: "%.1f", peak.level)) · \(hourLabel(peak.point.hour))")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StressLoadStyle.color(for: peak.level))
            }
        }
    }

    private var plot: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let count = max(points.count, 1)
            let x: (Int) -> CGFloat = { index in
                count <= 1 ? width / 2 : width * CGFloat(index) / CGFloat(count - 1)
            }
            let y: (Double) -> CGFloat = { level in
                height - height * CGFloat(min(max(level / 3, 0), 1))
            }
            let rendered = points.enumerated().compactMap { index, point in
                point.level.map { (x(index), y($0)) }
            }
            let peakPosition: CGPoint? = peak.flatMap { peak in
                guard let index = points.firstIndex(where: { $0.id == peak.point.id }) else { return nil }
                return CGPoint(x: x(index), y: y(peak.level))
            }

            ZStack {
                ForEach([1.0, 2.0], id: \.self) { level in
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: y(level)))
                        path.addLine(to: CGPoint(x: width, y: y(level)))
                    }
                    .stroke(
                        StrandPalette.hairlineStrong.opacity(0.7),
                        style: StrokeStyle(lineWidth: 0.7, dash: [3, 4])
                    )
                }

                if rendered.count >= 2 {
                    areaPath(rendered, height: height)
                        .fill(
                            LinearGradient(
                                colors: [StressLoadStyle.calm.opacity(0.22), StressLoadStyle.calm.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .opacity(revealed ? 1 : 0)
                    linePath(rendered)
                        .trim(from: 0, to: revealed ? 1 : 0)
                        .stroke(
                            LinearGradient(
                                gradient: StressLoadStyle.gradient,
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                        )
                } else if let only = rendered.first, let level = scored.first?.level {
                    Circle()
                        .fill(StressLoadStyle.color(for: level))
                        .frame(width: 7, height: 7)
                        .position(x: only.0, y: only.1)
                        .opacity(revealed ? 1 : 0)
                }

                if let peakPosition, let peak {
                    Circle()
                        .fill(StressLoadStyle.color(for: peak.level))
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(StrandPalette.surfaceRaised, lineWidth: 1.5))
                        .position(peakPosition)
                        .opacity(revealed ? 1 : 0)
                }
            }
        }
    }

    @ViewBuilder
    private var timeAxis: some View {
        if let first = points.first?.hour, let last = points.last?.hour {
            HStack {
                Text(hourLabel(first))
                Spacer()
                Text(hourLabel((first + last) / 2))
                Spacer()
                Text(hourLabel(last))
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func linePath(_ points: [(CGFloat, CGFloat)]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: first.0, y: first.1))
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let midpoint = (previous.0 + current.0) / 2
            path.addCurve(
                to: CGPoint(x: current.0, y: current.1),
                control1: CGPoint(x: midpoint, y: previous.1),
                control2: CGPoint(x: midpoint, y: current.1)
            )
        }
        return path
    }

    private func areaPath(_ points: [(CGFloat, CGFloat)], height: CGFloat) -> Path {
        var path = linePath(points)
        if let first = points.first, let last = points.last {
            path.addLine(to: CGPoint(x: last.0, y: height))
            path.addLine(to: CGPoint(x: first.0, y: height))
            path.closeSubpath()
        }
        return path
    }

    private var accessibilitySummary: String {
        guard !scored.isEmpty else { return "No intraday stress data yet today." }
        let values = scored.map { "\(hourLabel($0.point.hour)) \(String(format: "%.1f", $0.level))" }
        return "Autonomic load today: \(values.joined(separator: ", "))"
    }
}

public struct StressBandLegend: View {
    public init() {}

    public var body: some View {
        HStack(spacing: NoopMetrics.space3) {
            key(range: "0–1", label: "Calm", color: StressLoadStyle.calm)
            key(range: "1–2", label: "Moderate", color: StressLoadStyle.moderate)
            key(range: "2–3", label: "High", color: StressLoadStyle.high)
        }
    }

    private func key(range: String, label: LocalizedStringKey, color: Color) -> some View {
        HStack(spacing: NoopMetrics.space1) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 7)
                .accessibilityHidden(true)
            Text(range)
                .font(StrandFont.micro.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textPrimary)
            Text(label)
                .font(StrandFont.micro)
                .textCase(.uppercase)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }
}

public struct StressBandTotal: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let duration: String
    public let fraction: Double
    public let band: Int

    public init(id: String, label: String, duration: String, fraction: Double, band: Int) {
        self.id = id
        self.label = label
        self.duration = duration
        self.fraction = fraction
        self.band = band
    }
}

public struct StressBandTotalsView: View {
    public let totals: [StressBandTotal]

    public init(totals: [StressBandTotal]) { self.totals = totals }

    public var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            ForEach(totals) { total in
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(total.label)
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Text(total.duration)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    PipBar(
                        value: total.fraction,
                        range: 0...1,
                        segments: 20,
                        tint: color(for: total.band),
                        height: 8
                    )
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func color(for band: Int) -> Color {
        switch band {
        case 0: StressLoadStyle.calm
        case 1: StressLoadStyle.moderate
        default: StressLoadStyle.high
        }
    }
}

#Preview("Stress components") {
    ScrollView {
        VStack(spacing: 24) {
            StressLoadChart(
                points: [0.5, 0.8, 1.3, 1.9, 2.2, 1.6, 1.1].enumerated().map {
                    StressLoadPoint(id: $0.offset, hour: $0.offset + 6, level: $0.element)
                },
                peakID: 4,
                hourLabel: { "\($0):00" }
            )
            StressBandTotalsView(totals: [
                .init(id: "calm", label: "Calm", duration: "4h", fraction: 0.25, band: 0),
                .init(id: "moderate", label: "Moderate", duration: "9h", fraction: 0.56, band: 1),
                .init(id: "high", label: "High", duration: "3h", fraction: 0.19, band: 2),
            ])
        }
        .padding()
    }
    .background(StrandPalette.surfaceBase)
}
