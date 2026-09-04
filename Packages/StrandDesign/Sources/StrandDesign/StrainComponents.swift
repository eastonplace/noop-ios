import SwiftUI

// MARK: - Strain Detail (NOOP scope, data-rich tier)
//
// The Strain detail surface in the paper dialect, for the future Strain-page rebuild.
// Detail in every layer: the 0–21 gauge carries the optimal band ON the track with tick
// marks at its bounds, scale end labels, and a 7-day average read; the build-up chart
// shades the target zone, badges each workout with the strain it earned, and rules the
// current moment; activity rows carry heart-rate and calorie context with a share bar;
// and a 7-day strip reads the week against the same target band. Fixture-only.

// MARK: - StrainGaugeCard

public struct StrainGaugeCard: View {
    /// Day strain on the 0–21 display scale.
    let strain: Double
    /// The recovery-derived optimal band (e.g. 10...14).
    let target: ClosedRange<Double>
    let sevenDayAverage: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    private static let sweep: Double = 240 / 360
    private static let scale: Double = 21
    private static let gaugeScaleTickDegrees: [Double] = (0..<22).map { index in
        150 + 240 * Double(index) / 21
    }

    private struct GaugeTick: Identifiable {
        let id: Int
        let rotation: Angle
        let xOffset: CGFloat
        let yOffset: CGFloat
        let width: CGFloat
        let height: CGFloat
        let color: Color
    }

    private struct GaugeTickView: View {
        let tick: GaugeTick

        var body: some View {
            Capsule(style: .continuous)
                .fill(tick.color)
                .frame(width: tick.width, height: tick.height)
                .rotationEffect(tick.rotation)
                .offset(x: tick.xOffset, y: tick.yOffset)
        }
    }

    public var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Day strain")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                Text("TARGET \(Int(target.lowerBound))–\(Int(target.upperBound))")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.statusPositive)
            }
            gauge
            HStack(spacing: 6) {
                Circle().fill(stateColor).frame(width: 6, height: 6)
                Text(stateLine)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                Text("7D AVG \(String(format: "%.1f", sevenDayAverage))")
                    .font(StrandFont.micro.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.9).delay(0.1)) {
                revealed = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var fraction: Double { min(max(strain / Self.scale, 0), 1) }

    private var stateLine: String {
        if strain < target.lowerBound { return "Under your optimal band — room to move." }
        if strain > target.upperBound { return "Past your band — recovery pays the bill." }
        return "Inside your \(Int(target.lowerBound))–\(Int(target.upperBound)) optimal band."
    }

    private var stateColor: Color {
        if strain < target.lowerBound { return StrandPalette.textTertiary }
        if strain > target.upperBound { return StrandPalette.statusWarning }
        return StrandPalette.statusPositive
    }

    private var gauge: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height * 1.35)
            let lineWidth: CGFloat = 11
            let radius = side / 2 - lineWidth / 2
            let bandLo = Self.sweep * min(max(target.lowerBound / Self.scale, 0), 1)
            let bandHi = Self.sweep * min(max(target.upperBound / Self.scale, 0), 1)
            gaugeFace(
                side: side,
                lineWidth: lineWidth,
                radius: radius,
                bandLo: bandLo,
                bandHi: bandHi
            )
        }
        .frame(height: 172)
    }

    private func gaugeFace(
        side: CGFloat,
        lineWidth: CGFloat,
        radius: CGFloat,
        bandLo: Double,
        bandHi: Double
    ) -> some View {
        ZStack {
            gaugeTrack(lineWidth: lineWidth)
            gaugeScaleTicks(radius: radius, lineWidth: lineWidth)
            gaugeBand(lineWidth: lineWidth, bandLo: bandLo, bandHi: bandHi)
            gaugeBandTicks(radius: radius, lineWidth: lineWidth)
            scaleLabel("0", at: .degrees(150), radius: radius + 16)
            scaleLabel("21", at: .degrees(30), radius: radius + 16)
            gaugeValueArc(lineWidth: lineWidth)
            gaugeTip(radius: radius)
            gaugeCenterValue
        }
        .frame(width: side, height: side)
        .frame(maxWidth: .infinity)
    }

    private func gaugeTrack(lineWidth: CGFloat) -> some View {
        Circle()
            .trim(from: 0, to: Self.sweep)
            .stroke(StrandPalette.surfaceInset, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(150))
    }

    private func gaugeScaleTicks(radius: CGFloat, lineWidth: CGFloat) -> some View {
        let ticks = gaugeScaleTickData(radius: radius, lineWidth: lineWidth)
        return ForEach(ticks) { tick in
            GaugeTickView(tick: tick)
        }
    }

    private func gaugeBand(lineWidth: CGFloat, bandLo: Double, bandHi: Double) -> some View {
        Circle()
            .trim(from: bandLo, to: bandHi)
            .stroke(StrandPalette.statusPositive.opacity(0.3), style: StrokeStyle(lineWidth: lineWidth))
            .rotationEffect(.degrees(150))
    }

    private func gaugeBandTicks(radius: CGFloat, lineWidth: CGFloat) -> some View {
        let ticks = gaugeBandTickData(radius: radius, lineWidth: lineWidth)
        return ForEach(ticks) { tick in
            GaugeTickView(tick: tick)
        }
    }

    private func gaugeScaleTickData(radius: CGFloat, lineWidth: CGFloat) -> [GaugeTick] {
        let tickRadius = radius - lineWidth / 2 - 7
        return Self.gaugeScaleTickDegrees.enumerated().map { index, degrees in
            let angle = Angle.degrees(degrees)
            return GaugeTick(
                id: index,
                rotation: angle + .degrees(90),
                xOffset: cos(angle.radians) * tickRadius,
                yOffset: sin(angle.radians) * tickRadius,
                width: 1,
                height: 4,
                color: StrandPalette.hairline
            )
        }
    }

    private func gaugeBandTickData(radius: CGFloat, lineWidth: CGFloat) -> [GaugeTick] {
        [target.lowerBound, target.upperBound].enumerated().map { index, bound in
            let angle = Angle.degrees(150 + 240 * bound / Self.scale)
            return GaugeTick(
                id: index,
                rotation: angle + .degrees(90),
                xOffset: cos(angle.radians) * radius,
                yOffset: sin(angle.radians) * radius,
                width: 2,
                height: lineWidth + 6,
                color: StrandPalette.statusPositive.opacity(0.85)
            )
        }
    }

    private func gaugeValueArc(lineWidth: CGFloat) -> some View {
        Circle()
            .trim(from: 0, to: Self.sweep * (revealed ? fraction : 0))
            .stroke(StrandPalette.strainAccent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(150))
    }

    @ViewBuilder
    private func gaugeTip(radius: CGFloat) -> some View {
        if revealed {
            let angle = Angle.degrees(150 + 240 * fraction)
            Circle()
                .fill(StrandPalette.strainAccent)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(StrandPalette.surfaceRaised, lineWidth: 1.5))
                .offset(x: cos(angle.radians) * radius, y: sin(angle.radians) * radius)
                .transition(.opacity)
        }
    }

    private var gaugeCenterValue: some View {
        VStack(spacing: 3) {
            Text(String(format: "%.1f", strain))
                .font(StrandFont.number(40, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textPrimary)
                .contentTransition(.numericText())
            Text("of 21")
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .offset(y: 6)
    }

    private func scaleLabel(_ text: String, at angle: Angle, radius: CGFloat) -> some View {
        Text(text)
            .font(StrandFont.micro)
            .monospacedDigit()
            .foregroundStyle(StrandPalette.textTertiary)
            .offset(x: cos(angle.radians) * radius, y: sin(angle.radians) * radius)
    }

    private var accessibilitySummary: String {
        "Day strain \(String(format: "%.1f", strain)) of 21. Optimal band \(Int(target.lowerBound)) to \(Int(target.upperBound)). Seven day average \(String(format: "%.1f", sevenDayAverage)). \(stateLine)"
    }
}

// MARK: - StrainBuildupChart

public struct StrainBuildupPoint: Identifiable, Equatable {
    public let id: Int
    /// Seconds from midnight.
    public let t: TimeInterval
    /// Cumulative day strain at that moment (0–21).
    public let strain: Double
}

/// A workout badge with the strain it earned, for the build-up chart.
public struct StrainEarnMark: Identifiable, Equatable {
    public let id: Int
    public let start: TimeInterval
    public let end: TimeInterval
    public let symbol: String
    public let earned: Double
}

public struct StrainBuildupChart: View {
    let points: [StrainBuildupPoint]
    let target: ClosedRange<Double>
    var earns: [StrainEarnMark] = []
    let timeLabel: (TimeInterval) -> String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("How the day built")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                if let last = points.last {
                    Text("NOW \(String(format: "%.1f", last.strain))")
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.strainAccent)
                }
            }
            plot.frame(height: 150)
            axis
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.85).delay(0.1)) {
                revealed = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var yTop: Double { max(target.upperBound + 3, (points.map(\.strain).max() ?? 0) + 2) }

    private var plot: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let span = max((points.last?.t ?? 1) - (points.first?.t ?? 0), 1)
            let xOf: (TimeInterval) -> CGFloat = { size.width * CGFloat(($0 - (points.first?.t ?? 0)) / span) }
            let yOf: (Double) -> CGFloat = { size.height - size.height * CGFloat(min(max($0 / yTop, 0), 1)) }
            let rendered = points.map { (xOf($0.t), yOf($0.strain)) }

            ZStack {
                targetZone(size: size, yOf: yOf)
                buildupLine(size: size, rendered: rendered)
                earnBadges(size: size, xOf: xOf, yOf: yOf)
                nowRule(size: size, rendered: rendered)
            }
        }
    }

    @ViewBuilder
    private func targetZone(size: CGSize, yOf: @escaping (Double) -> CGFloat) -> some View {
        let zoneTop = yOf(target.upperBound)
        let zoneBottom = yOf(target.lowerBound)
        Rectangle()
            .fill(StrandPalette.statusPositive.opacity(0.07))
            .frame(height: max(0, zoneBottom - zoneTop))
            .position(x: size.width / 2, y: (zoneTop + zoneBottom) / 2)
        ForEach([target.lowerBound, target.upperBound], id: \.self) { bound in
            let y = yOf(bound)
            Path { path in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            .stroke(
                StrandPalette.statusPositive.opacity(0.5),
                style: StrokeStyle(lineWidth: 0.7, dash: [3, 4])
            )
            Text("\(Int(bound))")
                .font(StrandFont.micro)
                .monospacedDigit()
                .foregroundStyle(StrandPalette.statusPositive.opacity(0.8))
                .position(x: 10, y: max(8, y - 8))
        }
    }

    @ViewBuilder
    private func buildupLine(size: CGSize, rendered: [(CGFloat, CGFloat)]) -> some View {
        if rendered.count >= 2 {
            areaPath(rendered, height: size.height)
                .fill(
                    LinearGradient(
                        colors: [StrandPalette.strainAccent.opacity(0.16), StrandPalette.strainAccent.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .opacity(revealed ? 1 : 0)
            linePath(rendered)
                .trim(from: 0, to: revealed ? 1 : 0)
                .stroke(
                    LinearGradient(
                        colors: [StrandPalette.strainAccent.opacity(0.55), StrandPalette.strainAccent],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                )
        }
    }

    @ViewBuilder
    private func earnBadges(
        size: CGSize, xOf: @escaping (TimeInterval) -> CGFloat, yOf: @escaping (Double) -> CGFloat
    ) -> some View {
        ForEach(earns) { earn in
            if let at = points.last(where: { $0.t <= earn.end }) {
                let x = min(max(xOf(at.t), 22), size.width - 22)
                let y = max(26, yOf(at.strain) - 22)
                VStack(spacing: 2) {
                    Image(systemName: earn.symbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(StrandPalette.surfaceRaised)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(StrandPalette.hairlineStrong, lineWidth: 1)
                        )
                    Text("+\(String(format: "%.1f", earn.earned))")
                        .font(StrandFont.micro.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(StrandPalette.strainAccent)
                }
                .position(x: x, y: y)
                .opacity(revealed ? 1 : 0)
            }
        }
    }

    @ViewBuilder
    private func nowRule(size: CGSize, rendered: [(CGFloat, CGFloat)]) -> some View {
        if revealed, let last = rendered.last {
            Path { path in
                path.move(to: CGPoint(x: last.0, y: last.1 + 6))
                path.addLine(to: CGPoint(x: last.0, y: size.height))
            }
            .stroke(StrandPalette.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            Circle()
                .fill(StrandPalette.strainAccent)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(StrandPalette.surfaceRaised, lineWidth: 1.5))
                .position(x: last.0, y: last.1)
                .transition(.opacity)
        }
    }

    private var axis: some View {
        HStack(spacing: 0) {
            Text(timeLabel(points.first?.t ?? 0)).frame(maxWidth: .infinity, alignment: .leading)
            Text(timeLabel(((points.first?.t ?? 0) + (points.last?.t ?? 0)) / 2)).frame(maxWidth: .infinity, alignment: .center)
            Text(timeLabel(points.last?.t ?? 0)).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(StrandFont.micro)
        .monospacedDigit()
        .foregroundStyle(StrandPalette.textTertiary)
        .accessibilityHidden(true)
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
        guard let last = points.last else { return "No strain yet today." }
        return "Strain build-up, now \(String(format: "%.1f", last.strain)) of 21, target \(Int(target.lowerBound)) to \(Int(target.upperBound)), \(earns.count) workouts."
    }
}

// MARK: - StrainSummaryStrip

/// Total / Active / Passive — the SleepWindowStrip three-column grammar.
public struct StrainSummaryStrip: View {
    let total: Double
    let active: Double
    let passive: Double

    public var body: some View {
        GeometryReader { proxy in
            let columnWidth = max(1, (proxy.size.width - 2) / 3)
            HStack(spacing: 0) {
                column("Total", value: total, alignment: .leading).frame(width: columnWidth)
                divider
                column("Active", value: active, alignment: .center).frame(width: columnWidth)
                divider
                column("Passive", value: passive, alignment: .trailing).frame(width: columnWidth)
            }
        }
        .frame(height: 46)
        .accessibilityElement(children: .combine)
    }

    private var divider: some View {
        Rectangle().fill(StrandPalette.hairline).frame(width: 1, height: 42)
    }

    private func column(_ label: LocalizedStringKey, value: Double, alignment: HorizontalAlignment) -> some View {
        let frameAlignment: Alignment = switch alignment {
        case .leading: .leading
        case .trailing: .trailing
        default: .center
        }
        return VStack(alignment: alignment, spacing: 4) {
            Text(label).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
            Text(String(format: "%.1f", value))
                .font(StrandFont.number(20))
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }
}

// MARK: - StrainActivityRow

public struct StrainActivityRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    /// e.g. "avg 152 bpm · 486 cal" — the context line under the share bar.
    let context: String
    let strain: Double
    /// This activity's share of the day's strain, 0…1.
    let share: Double

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.strainAccent)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(StrandPalette.strainAccent.opacity(0.12))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.uppercased())
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(subtitle)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 8)
                Text(String(format: "%.1f", strain))
                    .font(StrandFont.number(18, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            PipBar(
                value: min(max(share, 0), 1),
                range: 0...1,
                segments: 20,
                tint: StrandPalette.strainAccent,
                height: 6
            )
            HStack {
                Text(context)
                    .font(StrandFont.micro)
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                Text("\(Int((share * 100).rounded()))% of day")
                    .font(StrandFont.micro)
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(subtitle), strain \(String(format: "%.1f", strain)), \(context)")
    }
}

// MARK: - StrainZoneBar

public struct StrainZoneSlice: Identifiable, Equatable {
    public let id: Int
    public let name: String
    public let range: String
    public let minutes: Double
}

/// Time in heart-rate zones: one stacked bar plus a legend row per zone with duration.
public struct StrainZoneBar: View {
    let slices: [StrainZoneSlice]

    private static let colors = [
        StrandPalette.accent,
        StrandPalette.statusPositive,
        StrandPalette.statusWarning,
        StrandPalette.metricRose,
        StrandPalette.liveRed,
    ]

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                let total = max(slices.map(\.minutes).reduce(0, +), 0.0001)
                HStack(spacing: 2) {
                    ForEach(slices) { slice in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Self.colors[slice.id % 5].opacity(slice.minutes > 0 ? 1 : 0.15))
                            .frame(width: max(3, proxy.size.width * slice.minutes / total - 2))
                    }
                }
            }
            .frame(height: 10)
            .clipShape(Capsule(style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(slices) { slice in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Self.colors[slice.id % 5])
                            .frame(width: 10, height: 7)
                        Text("ZONE \(slice.id + 1)")
                            .font(StrandFont.micro.weight(.bold))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(slice.range)
                            .font(StrandFont.micro)
                            .monospacedDigit()
                            .foregroundStyle(StrandPalette.textTertiary)
                        Spacer(minLength: 8)
                        Text(minutesLabel(slice.minutes))
                            .font(StrandFont.captionNumber)
                            .monospacedDigit()
                            .foregroundStyle(slice.minutes > 0 ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Time in zones: " + slices.map { "\($0.name) \(minutesLabel($0.minutes))" }.joined(separator: ", ")
        )
    }

    private func minutesLabel(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        guard total > 0 else { return "—" }
        let hours = total / 60
        let rest = total % 60
        if hours > 0 && rest > 0 { return "\(hours)h \(rest)m" }
        return hours > 0 ? "\(hours)h" : "\(rest)m"
    }
}

// MARK: - StrainWeekStrip

/// The calendar week against the same target band: zone shading behind, bars in front,
/// and the selected anchor day ringed.
public struct StrainWeekStrip: View {
    let days: [CalendarMetricDay]
    let target: ClosedRange<Double>
    let anchorDate: Date
    let referenceDate: Date
    let calendar: Calendar

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    private static let labels = ["M", "T", "W", "T", "F", "S", "S"]
    private static let scale: Double = 21

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let height = proxy.size.height
                let count = max(days.count, 1)
                let slot = proxy.size.width / CGFloat(count)
                let barWidth = max(5, slot * 0.4)
                let yOf: (Double) -> CGFloat = { height - height * CGFloat(min(max($0 / Self.scale, 0), 1)) }

                ZStack(alignment: .topLeading) {
                    let zoneTop = yOf(target.upperBound)
                    let zoneBottom = yOf(target.lowerBound)
                    Rectangle()
                        .fill(StrandPalette.statusPositive.opacity(0.07))
                        .frame(height: max(0, zoneBottom - zoneTop))
                        .offset(y: zoneTop)
                    ForEach([target.lowerBound, target.upperBound], id: \.self) { bound in
                        let y = yOf(bound)
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                        }
                        .stroke(
                            StrandPalette.statusPositive.opacity(0.45),
                            style: StrokeStyle(lineWidth: 0.7, dash: [3, 4])
                        )
                    }
                    ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                        let strain = day.value
                        let barHeight = strain.map { max(4, height - yOf($0)) } ?? 4
                        let isAnchor = calendar.isDate(day.date, inSameDayAs: anchorDate)
                        let isFuture = calendar.startOfDay(for: day.date) > calendar.startOfDay(for: referenceDate)
                        Capsule(style: .continuous)
                            .fill(strain == nil ? StrandPalette.surfaceInset.opacity(isFuture ? 0.35 : 1)
                                : StrandPalette.strainAccent.opacity(isAnchor ? 1 : 0.6))
                            .frame(width: barWidth, height: revealed ? barHeight : 4)
                            .overlay {
                                if isAnchor {
                                    Capsule(style: .continuous)
                                        .stroke(StrandPalette.textPrimary.opacity(0.5), lineWidth: 1)
                                }
                            }
                            .position(
                                x: slot * CGFloat(index) + slot / 2,
                                y: height - (revealed ? barHeight : 4) / 2
                            )
                            .animation(
                                reduceMotion ? nil : StrandMotion.value.delay(Double(index) * 0.035),
                                value: revealed
                            )
                    }
                }
            }
            .frame(height: 64)
            HStack(spacing: 0) {
                ForEach(Array(Self.labels.enumerated()), id: \.offset) { index, label in
                    Text(label)
                        .font(StrandFont.micro)
                        .foregroundStyle(days.indices.contains(index)
                            && calendar.isDate(days[index].date, inSameDayAs: anchorDate)
                            ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear { revealed = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard !days.isEmpty else { return "No strain history yet." }
        let anchor = TrendCalendar.value(on: anchorDate, in: days, calendar: calendar)
        let anchorRead = anchor.map { String(format: "%.1f", $0) } ?? "missing"
        let inBand = days.compactMap(\.value).filter(target.contains).count
        let missing = days.filter { $0.value == nil }.count
        return "Monday through Sunday strain, selected day \(anchorRead), \(inBand) days inside the optimal band, \(missing) days missing."
    }
}
