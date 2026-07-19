import SwiftUI

public struct FitnessAgeHero: View {
    public let fitnessAge: Double?
    public let chronologicalAge: Double
    public let railRange: ClosedRange<Double>
    public let uncertaintyYears: Double

    public init(fitnessAge: Double?, chronologicalAge: Double,
                railRange: ClosedRange<Double>, uncertaintyYears: Double) {
        self.fitnessAge = fitnessAge
        self.chronologicalAge = chronologicalAge
        self.railRange = railRange
        self.uncertaintyYears = uncertaintyYears
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Fitness age").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                if let delta {
                    Text(delta < 0 ? "YOUNGER" : delta > 0 ? "OLDER" : "EVEN")
                        .font(StrandFont.captionNumber).foregroundStyle(deltaColor)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(fitnessAge.map { String(format: "%.1f", $0) } ?? "—")
                    .font(StrandFont.number(44, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("yrs")
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Text(deltaText)
                .font(StrandFont.subhead)
                .foregroundStyle(deltaColor)
            FitnessAgeRail(fitnessAge: fitnessAge, chronologicalAge: chronologicalAge, range: railRange)
            Text("± \(Int(uncertaintyYears.rounded())) yr · a fitness comparison, not a biological age")
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(StrandPalette.surfaceRaised)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.16), StrandPalette.hairline],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var delta: Double? { fitnessAge.map { $0 - chronologicalAge } }
    private var deltaColor: Color {
        guard let delta else { return StrandPalette.textTertiary }
        return delta <= 0 ? StrandPalette.statusPositive : StrandPalette.statusWarning
    }
    private var deltaText: String {
        guard let delta else { return "Calibrating from your recent nights and activity." }
        if abs(delta) < 0.05 { return "About the same as your calendar age." }
        return String(format: "%.1f yrs %@ than your calendar age of %d.", abs(delta), delta < 0 ? "younger" : "older", Int(chronologicalAge))
    }
    private var accessibilityText: String {
        guard let fitnessAge else { return "Fitness Age calibrating." }
        return "Fitness Age \(String(format: "%.1f", fitnessAge)) years. \(deltaText)"
    }
}

private struct FitnessAgeRail: View {
    let fitnessAge: Double?
    let chronologicalAge: Double
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { proxy in
            let chronoX = x(chronologicalAge, width: proxy.size.width)
            ZStack(alignment: .leading) {
                Capsule().fill(StrandPalette.inset).frame(height: 5)
                if let fitnessAge {
                    let fitX = x(fitnessAge, width: proxy.size.width)
                    Capsule().fill((fitnessAge <= chronologicalAge
                        ? StrandPalette.statusPositive : StrandPalette.statusWarning).opacity(0.35))
                        .frame(width: abs(fitX - chronoX), height: 5)
                        .offset(x: min(fitX, chronoX))
                    Circle().fill(fitnessAge <= chronologicalAge
                        ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                        .frame(width: 11, height: 11).position(x: fitX, y: 11)
                }
                Rectangle().fill(StrandPalette.textPrimary).frame(width: 2, height: 14)
                    .position(x: chronoX, y: 11)
                Text("YOU · \(Int(chronologicalAge.rounded(.down)))")
                    .font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                    .position(x: min(max(chronoX, 30), proxy.size.width - 30), y: 30)
            }
        }
        .frame(height: 40)
        .accessibilityHidden(true)
    }

    private func x(_ value: Double, width: CGFloat) -> CGFloat {
        let span = max(0.001, range.upperBound - range.lowerBound)
        return width * CGFloat(min(1, max(0, (value - range.lowerBound) / span)))
    }
}

public struct FitnessAgePaceRow: View {
    public let pace: Double?
    public init(pace: Double?) { self.pace = pace }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pace of aging")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text(pace.map { String(format: "%.1f×", $0) } ?? "Calibrating")
                    .font(StrandFont.captionNumber).foregroundStyle(tint)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(StrandPalette.inset).frame(height: 5)
                    Rectangle().fill(StrandPalette.textSecondary).frame(width: 2, height: 12)
                        .position(x: proxy.size.width / 2, y: 7)
                    if let pace {
                        Circle().fill(tint).frame(width: 10, height: 10)
                            .position(x: proxy.size.width * CGFloat(min(1, max(0, (pace - 0.5)))), y: 7)
                    }
                }
            }.frame(height: 14)
            HStack { Text("slower"); Spacer(); Text("typical 1.0×"); Spacer(); Text("faster") }
                .font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
            Text(caption)
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        guard let pace else { return StrandPalette.textTertiary }
        if pace < 0.97 { return StrandPalette.statusPositive }
        if pace > 1.03 { return StrandPalette.metricRose }
        return StrandPalette.textSecondary
    }
    private var caption: String {
        guard let pace else { return "Needs 12 weekly readings spanning at least 90 days." }
        if pace < 0.97 { return "Your recent Fitness Age trend is moving slower than typical." }
        if pace > 1.03 { return "Your recent Fitness Age trend is moving faster than typical." }
        return "Right at a typical pace."
    }
}

public struct FitnessAgeDriverRow: View {
    public let title: String
    public let value: String
    public let impactYears: Double
    public let systemImage: String

    public init(title: String, value: String, impactYears: Double, systemImage: String) {
        self.title = title; self.value = value; self.impactYears = impactYears; self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(accent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased()).strandOverline()
                Text(value).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 8)
            impactBar
            Text(impactText).font(StrandFont.captionNumber).foregroundStyle(impactColor)
                .frame(width: 62, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var impactText: String {
        if abs(impactYears) < 0.05 { return "even" }
        return String(format: "%@%.1f yr", impactYears < 0 ? "−" : "+", abs(impactYears))
    }
    private var impactColor: Color {
        impactYears < -0.05 ? StrandPalette.statusPositive
            : impactYears > 0.05 ? StrandPalette.metricRose : StrandPalette.textTertiary
    }
    private var accent: Color { title.localizedCaseInsensitiveContains("heart") ? StrandPalette.metricRose : StrandPalette.strainAccent }
    private var impactBar: some View {
        let fraction = CGFloat(min(abs(impactYears) / 10, 1))
        return ZStack {
            Rectangle().fill(StrandPalette.hairlineStrong).frame(width: 1.5, height: 14)
            HStack(spacing: 0) {
                Capsule().fill(impactColor).frame(width: impactYears < -0.05 ? 24 * fraction : 0, height: 5).frame(width: 24, alignment: .trailing)
                Capsule().fill(impactColor).frame(width: impactYears > 0.05 ? 24 * fraction : 0, height: 5).frame(width: 24, alignment: .leading)
            }
        }.frame(width: 49).accessibilityHidden(true)
    }
}

public struct FitnessAgeTrendChart: View {
    public struct Point: Equatable, Sendable {
        public let time: TimeInterval
        public let fitnessAge: Double
        public let chronologicalAge: Double
        public init(time: TimeInterval, fitnessAge: Double, chronologicalAge: Double) {
            self.time = time; self.fitnessAge = fitnessAge; self.chronologicalAge = chronologicalAge
        }
    }

    public let points: [Point]
    public init(points: [Point]) { self.points = points }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Six months").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                if let first = points.first, let last = points.last {
                    let moved = last.fitnessAge - first.fitnessAge
                    Text("\(moved <= 0 ? "▼" : "▲") \(String(format: "%.1f", abs(moved))) yrs over the window")
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(moved <= 0 ? StrandPalette.statusPositive : StrandPalette.metricRose)
                }
            }
            GeometryReader { proxy in
                let fitness = positions(points.map { ($0.time, $0.fitnessAge) }, size: proxy.size)
                let calendar = positions(points.map { ($0.time, $0.chronologicalAge) }, size: proxy.size)
                ZStack {
                    path(calendar).stroke(StrandPalette.textTertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    path(fitness).stroke(StrandPalette.recoveryData, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(height: 120)
            HStack { Text("6mo ago"); Spacer(); Text("Today") }
                .font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
            HStack(spacing: 12) {
                legend(StrandPalette.recoveryData, "FITNESS AGE")
                legend(StrandPalette.textTertiary, "CALENDAR AGE", dashed: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func positions(_ values: [(TimeInterval, Double)], size: CGSize) -> [CGPoint] {
        guard let minT = values.map(\.0).min(), let maxT = values.map(\.0).max(),
              let minV = points.flatMap({ [$0.fitnessAge, $0.chronologicalAge] }).min(),
              let maxV = points.flatMap({ [$0.fitnessAge, $0.chronologicalAge] }).max() else { return [] }
        let dt = max(1, maxT - minT), dv = max(1, maxV - minV)
        return values.map { CGPoint(x: size.width * CGFloat(($0.0 - minT) / dt),
                                    y: size.height * CGFloat(1 - ($0.1 - minV) / dv)) }
    }
    private func path(_ points: [CGPoint]) -> Path {
        var result = Path()
        guard let first = points.first else { return result }
        result.move(to: first)
        for index in 1..<points.count {
            let previous = points[index - 1], point = points[index]
            let midpoint = (previous.x + point.x) / 2
            result.addCurve(to: point,
                            control1: CGPoint(x: midpoint, y: previous.y),
                            control2: CGPoint(x: midpoint, y: point.y))
        }
        return result
    }
    private func legend(_ color: Color, _ label: String, dashed: Bool = false) -> some View {
        HStack(spacing: 4) {
            if dashed {
                Rectangle().fill(color).frame(width: 3, height: 2)
                Rectangle().fill(color).frame(width: 3, height: 2)
            } else { Capsule().fill(color).frame(width: 10, height: 3) }
            Text(label).font(StrandFont.micro).foregroundStyle(StrandPalette.textSecondary)
        }.accessibilityHidden(true)
    }
    private var accessibilityText: String {
        guard let first = points.first, let last = points.last else { return "No Fitness Age trend yet." }
        return "Fitness Age changed from \(String(format: "%.1f", first.fitnessAge)) to \(String(format: "%.1f", last.fitnessAge)) over six months."
    }
}
