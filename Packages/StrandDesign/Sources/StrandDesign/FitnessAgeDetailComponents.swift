import SwiftUI

// MARK: - Fitness Age detail parts
//
// The pieces the Fitness Age detail adds to the widget language: the rail that sets the Fitness Age against the
// calendar age, the pace-of-aging scale, a factor row with its impact in years, and the six-month trend of both ages.
// Each is a flat section (an eyebrow over free content); none draws a card. They take plain values and know nothing
// about any screen's model: the screen passes the numbers and the words it has already said in the person's language.

// MARK: - Rail

/// The Fitness Age against the calendar age on one rail: a tick for the calendar age ("YOU"), a dot for the Fitness Age
/// and the gap between them washed green when the Fitness Age is the younger, amber when it is the older, and neither
/// (quiet ink, no wash) when the sentence beside it says "about the same". The screen passes the two ages as the whole
/// numbers it prints and the `reading` its sentence uses, so the dot's side and the rail's colour can never disagree
/// with the words next to it.
public struct FitnessAgeRail: View {
    /// How the sentence beside the rail reads the gap between the two ages.
    public enum Reading: Equatable, Sendable {
        case younger, older, same

        /// Read straight from the two ages: the Fitness Age before, after or at the calendar age.
        public init(fitnessAge: Double, chronologicalAge: Double) {
            self = fitnessAge < chronologicalAge ? .younger : (fitnessAge > chronologicalAge ? .older : .same)
        }
    }

    public let fitnessAge: Double?
    public let chronologicalAge: Double
    public let range: ClosedRange<Double>
    public let reading: Reading?

    /// The "YOU · N" band's height follows the label's type size.
    @ScaledMetric(relativeTo: .caption2) private var labelHeight: CGFloat = 14
    @Environment(\.dynamicTypeSize) private var typeSize

    /// `reading` is how the sentence next to the rail reads the gap; nil reads it from the two ages.
    public init(fitnessAge: Double?, chronologicalAge: Double, range: ClosedRange<Double>, reading: Reading? = nil) {
        self.fitnessAge = fitnessAge
        self.chronologicalAge = chronologicalAge
        self.range = range
        self.reading = reading
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            rail.frame(height: 22)
            label
        }
        .accessibilityHidden(true)
    }

    private var rail: some View {
        GeometryReader { proxy in
            let chronoX = x(chronologicalAge, width: proxy.size.width)
            ZStack(alignment: .leading) {
                Capsule().fill(StrandPalette.surfaceInset).frame(height: 5)
                if let fitnessAge {
                    let fitX = x(fitnessAge, width: proxy.size.width)
                    let resolved = reading ?? Reading(fitnessAge: fitnessAge, chronologicalAge: chronologicalAge)
                    if resolved != .same {
                        Capsule().fill(tone(resolved).opacity(0.35))
                            .frame(width: abs(fitX - chronoX), height: 5)
                            .offset(x: min(fitX, chronoX))
                    }
                    Circle().fill(tone(resolved))
                        .frame(width: 11, height: 11).position(x: fitX, y: 11)
                }
                Rectangle().fill(StrandPalette.textPrimary).frame(width: 2, height: 14)
                    .position(x: chronoX, y: 11)
            }
        }
    }

    /// "YOU · N" under the tick, kept on the rail by its measured width. At an accessibility size the label is far
    /// wider than the clamp the ordinary sizes assume, so it sits under the nearer end of the rail instead of being
    /// centred on a tick that can be near the screen edge.
    @ViewBuilder private var label: some View {
        let text = Text("YOU · \(Int(chronologicalAge.rounded(.down)))")
            .font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
            .lineLimit(1)
        if typeSize.isAccessibilitySize {
            text.frame(maxWidth: .infinity, alignment: unitChronoX < 0.5 ? .leading : .trailing)
        } else {
            GeometryReader { proxy in
                text.fixedSize()
                    .position(x: min(max(x(chronologicalAge, width: proxy.size.width), 34), proxy.size.width - 34),
                              y: labelHeight / 2)
            }
            .frame(height: labelHeight)
        }
    }

    private var unitChronoX: Double {
        let span = max(0.001, range.upperBound - range.lowerBound)
        return min(1, max(0, (chronologicalAge - range.lowerBound) / span))
    }

    private func tone(_ reading: Reading) -> Color {
        switch reading {
        case .younger: StrandPalette.statusPositive
        case .older: StrandPalette.statusWarning
        case .same: StrandPalette.textSecondary
        }
    }

    private func x(_ value: Double, width: CGFloat) -> CGFloat {
        let span = max(0.001, range.upperBound - range.lowerBound)
        return width * CGFloat(min(1, max(0, (value - range.lowerBound) / span)))
    }
}

// MARK: - Pace of aging

/// How fast the Fitness Age is moving against a calendar year: a scale from slower to faster with 1.0x at its middle, the
/// pace as a dot, and a sentence on what it means. With too little history it says "Calibrating" and what it needs.
///
/// The pace is the slope of the weekly Fitness Ages in years per calendar year, fitted over a window that may be only a
/// few months, so a steep stretch annualises to a number nobody can act on (8 years in under 4 months is "-29.2×").
/// Beyond `displayLimit` either way the row says "Much slower" or "Much faster" than typical instead of printing it.
public struct FitnessAgePaceRow: View {
    /// Where the number gives way to words: a pace beyond ±3× is not a reading a person can use.
    public static let displayLimit: Double = 3

    /// How a pace reads against 1.0× ("typical"), with the extremes named instead of quoted.
    public enum Band: Equatable, Sendable {
        case muchSlower, slower, typical, faster, muchFaster

        public init(pace: Double, limit: Double = FitnessAgePaceRow.displayLimit) {
            if pace < -limit { self = .muchSlower }
            else if pace > limit { self = .muchFaster }
            else if pace < 0.97 { self = .slower }
            else if pace > 1.03 { self = .faster }
            else { self = .typical }
        }
    }

    public let pace: Double?
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(pace: Double?) { self.pace = pace }

    public var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow("Pace of aging", systemImage: "speedometer", tint: .custom(tint),
                           trailing: .custom(AnyView(valueText)))
            scale
            ends
            Text(verbatim: caption)
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var band: Band? { pace.map { Band(pace: $0) } }

    private var valueString: String {
        switch band {
        case nil: String(localized: "Calibrating")
        case .muchSlower?: String(localized: "Much slower")
        case .muchFaster?: String(localized: "Much faster")
        default: (pace ?? 0).formatted(.number.precision(.fractionLength(1))) + "×"
        }
    }

    private var valueText: some View {
        Text(verbatim: valueString)
            .font(StrandFont.captionNumber).foregroundStyle(tint)
            .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
    }

    private var scale: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(StrandPalette.surfaceInset).frame(height: 5)
                Rectangle().fill(StrandPalette.textSecondary).frame(width: 2, height: 12)
                    .position(x: proxy.size.width / 2, y: 7)
                if let pace {
                    Circle().fill(tint).frame(width: 10, height: 10)
                        .position(x: proxy.size.width * CGFloat(min(1, max(0, pace - 0.5))), y: 7)
                }
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }

    /// The scale's three words. At an accessibility size they stack instead of squeezing one another.
    @ViewBuilder private var ends: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                Text("slower"); Text("typical 1.0×"); Text("faster")
            }
            .font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
        } else {
            HStack {
                Text("slower").frame(maxWidth: .infinity, alignment: .leading)
                Text("typical 1.0×").frame(maxWidth: .infinity, alignment: .center)
                Text("faster").frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
            .lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    private var tint: Color {
        switch band {
        case nil: StrandPalette.textTertiary
        case .muchSlower?, .slower?: StrandPalette.statusPositive
        case .muchFaster?, .faster?: StrandPalette.metricRose
        case .typical?: StrandPalette.textSecondary
        }
    }

    private var caption: String {
        switch band {
        case nil: String(localized: "Needs 12 weekly readings spanning at least 90 days.")
        case .muchSlower?: String(localized: "Your recent Fitness Age trend is moving much slower than typical.")
        case .slower?: String(localized: "Your recent Fitness Age trend is moving slower than typical.")
        case .muchFaster?: String(localized: "Your recent Fitness Age trend is moving much faster than typical.")
        case .faster?: String(localized: "Your recent Fitness Age trend is moving faster than typical.")
        case .typical?: String(localized: "Right at a typical pace.")
        }
    }
}

// MARK: - Factor row

/// One input to the Fitness Age with its impact in years: the factor's glyph, its name and value, and a centred bar that
/// grows left (younger) or right (older) beside the number of years. At an accessibility size the impact drops under the
/// name.
public struct FitnessAgeDriverRow: View {
    public let title: String
    public let value: String
    public let impactYears: Double
    public let systemImage: String
    public let tint: DomainTint

    @Environment(\.dynamicTypeSize) private var typeSize

    public init(title: String, value: String, impactYears: Double, systemImage: String, tint: DomainTint) {
        self.title = title; self.value = value; self.impactYears = impactYears
        self.systemImage = systemImage; self.tint = tint
    }

    public var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    label
                    HStack(spacing: NoopMetrics.space3) {
                        impactBar
                        impact
                    }
                    .padding(.leading, GlyphDisc.diameter(scaled: 38) + NoopMetrics.space3)
                }
            } else {
                HStack(alignment: .center, spacing: NoopMetrics.space3) {
                    label
                    Spacer(minLength: NoopMetrics.space2)
                    impactBar
                    impact.frame(minWidth: 62, alignment: .trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(title), \(value), \(impactText)"))
    }

    private var label: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
            GlyphDisc(systemImage, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: value).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var impact: some View {
        Text(verbatim: impactText).font(StrandFont.captionNumber).foregroundStyle(impactColor).lineLimit(1)
    }

    private var impactText: String {
        if abs(impactYears) < 0.05 { return String(localized: "even") }
        let number = abs(impactYears).formatted(.number.precision(.fractionLength(1)))
        return (impactYears < 0 ? "−" : "+") + number + " " + String(localized: "yr")
    }

    private var impactColor: Color {
        impactYears < -0.05 ? StrandPalette.statusPositive
            : impactYears > 0.05 ? StrandPalette.metricRose : StrandPalette.textTertiary
    }

    private var impactBar: some View {
        let fraction = CGFloat(min(abs(impactYears) / 10, 1))
        return ZStack {
            Rectangle().fill(StrandPalette.hairlineStrong).frame(width: 1.5, height: 14)
            HStack(spacing: 0) {
                Capsule().fill(impactColor)
                    .frame(width: impactYears < -0.05 ? 24 * fraction : 0, height: 5)
                    .frame(width: 24, alignment: .trailing)
                Capsule().fill(impactColor)
                    .frame(width: impactYears > 0.05 ? 24 * fraction : 0, height: 5)
                    .frame(width: 24, alignment: .leading)
            }
        }
        .frame(width: 49)
        .accessibilityHidden(true)
    }
}

// MARK: - Six-month trend

/// The Fitness Age and the calendar age over the last six months: a tinted line over a 14% wash for the Fitness Age, a
/// dashed line for the calendar age, the age scale's two ends and the two dates (four labels), and touch-and-hold-then-drag
/// to read one week. The page keeps scrolling under a moving finger.
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
    public let tint: Color

    @State private var selection: Int?

    public init(points: [Point], tint: Color = StrandPalette.recoveryData) {
        self.points = points
        self.tint = tint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow("Six months", systemImage: "chart.xyaxis.line", tint: .custom(tint))
            readout
            plot.frame(height: WidgetMetrics.chartHeight)
            dateLabels
            legend
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
    }

    // MARK: Readout

    /// While the finger is down: that week's date and both ages. Otherwise how far the Fitness Age moved over the window.
    @ViewBuilder private var readout: some View {
        if let selection, points.indices.contains(selection) {
            let point = points[selection]
            Text(verbatim: String(localized: "\(dayText(point.time)) · Fitness Age \(oneDecimal(point.fitnessAge)) · Calendar age \(oneDecimal(point.chronologicalAge))"))
                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let first = points.first, let last = points.last {
            let moved = last.fitnessAge - first.fitnessAge
            Text(verbatim: String(localized: "\(moved <= 0 ? "▼" : "▲") \(oneDecimal(abs(moved))) yrs over the window"))
                .font(StrandFont.captionNumber)
                .foregroundStyle(moved <= 0 ? StrandPalette.statusPositive : StrandPalette.metricRose)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Plot

    private var yRange: ClosedRange<Double> {
        let all = points.flatMap { [$0.fitnessAge, $0.chronologicalAge] }
        guard let lo = all.min(), let hi = all.max() else { return 0...1 }
        let pad = max((hi - lo) * 0.12, 0.5)
        return (lo - pad)...(hi + pad)
    }

    private var timeRange: ClosedRange<TimeInterval> {
        let first = points.first?.time ?? 0
        return first...max(points.last?.time ?? first, first + 1)
    }

    private func position(time: TimeInterval, value: Double, size: CGSize) -> CGPoint {
        let range = yRange
        let times = timeRange
        // Room at the top for the head's ring, at the bottom for the line's stroke.
        let top: CGFloat = 8, bottom: CGFloat = 4, inset: CGFloat = 5
        let usable = max(size.height - top - bottom, 1)
        let unitX = (time - times.lowerBound) / (times.upperBound - times.lowerBound)
        let unitY = (value - range.lowerBound) / max(range.upperBound - range.lowerBound, 0.0001)
        return CGPoint(x: inset + (size.width - inset * 2) * CGFloat(unitX), y: top + usable * CGFloat(1 - unitY))
    }

    private var plot: some View {
        GeometryReader { proxy in
            let fitness = points.map { position(time: $0.time, value: $0.fitnessAge, size: proxy.size) }
            let calendar = points.map { position(time: $0.time, value: $0.chronologicalAge, size: proxy.size) }
            layers(fitness: fitness, calendar: calendar, size: proxy.size)
                .contentShape(Rectangle())
                .holdToScrub(
                    onScrub: { location in
                        var best = 0
                        var distance = CGFloat.greatestFiniteMagnitude
                        for (index, point) in fitness.enumerated() where abs(point.x - location.x) < distance {
                            best = index
                            distance = abs(point.x - location.x)
                        }
                        if best != selection { selection = best }
                    },
                    onEnd: { selection = nil })
        }
    }

    private func layers(fitness: [CGPoint], calendar: [CGPoint], size: CGSize) -> some View {
        let range = yRange
        return ZStack {
            area(fitness, height: size.height)
                .fill(LinearGradient(colors: [tint.opacity(0.14), .clear], startPoint: .top, endPoint: .bottom))
            line(calendar)
                .stroke(StrandPalette.textTertiary, style: StrokeStyle(lineWidth: 1.2, dash: [3, 4]))
            line(fitness)
                .stroke(tint, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            railLabel(Int(range.upperBound.rounded()), y: 7, width: size.width)
            railLabel(Int(range.lowerBound.rounded()), y: size.height - 7, width: size.width)
            if let selection, fitness.indices.contains(selection) {
                let spot = fitness[selection]
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(StrandPalette.hairlineStrong)
                    .frame(width: 1, height: size.height)
                    .position(x: spot.x, y: size.height / 2)
                Circle()
                    .fill(StrandPalette.appCanvas)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(StrandPalette.textTertiary, lineWidth: 1.5))
                    .position(calendar[selection])
                Circle()
                    .fill(tint)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(StrandPalette.appCanvas, lineWidth: 1.5))
                    .position(spot)
            } else if let end = fitness.last {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(StrandPalette.appCanvas, lineWidth: 1.5))
                    .position(end)
            }
        }
    }

    /// The age scale's end, inset so the head's ring never touches it, with a canvas knock-out so a line passing under it
    /// stays legible.
    private func railLabel(_ value: Int, y: CGFloat, width: CGFloat) -> some View {
        Text(verbatim: "\(value)")
            .font(StrandFont.micro).monospacedDigit()
            .foregroundStyle(StrandPalette.textTertiary)
            // One line at any size: the digits grow past the 28 pt column at accessibility sizes, so the label keeps
            // its trailing edge and grows leftward instead of wrapping a digit per line.
            .lineLimit(1).fixedSize()
            .background {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(StrandPalette.appCanvas.opacity(0.88))
                    .padding(.horizontal, -3)
                    .padding(.vertical, -1)
            }
            .frame(width: 28, alignment: .trailing)
            .position(x: width - 16 - 14, y: y)
    }

    private func line(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for index in 1..<max(points.count, 1) {
            let previous = points[index - 1]
            let current = points[index]
            let midpoint = (previous.x + current.x) / 2
            path.addCurve(to: current,
                          control1: CGPoint(x: midpoint, y: previous.y),
                          control2: CGPoint(x: midpoint, y: current.y))
        }
        return path
    }

    private func area(_ points: [CGPoint], height: CGFloat) -> Path {
        var path = line(points)
        if let first = points.first, let last = points.last {
            path.addLine(to: CGPoint(x: last.x, y: height))
            path.addLine(to: CGPoint(x: first.x, y: height))
            path.closeSubpath()
        }
        return path
    }

    // MARK: Labels

    private var dateLabels: some View {
        HStack {
            if let first = points.first { Text(verbatim: dayText(first.time)) }
            Spacer(minLength: NoopMetrics.space2)
            if let last = points.last { Text(verbatim: dayText(last.time)) }
        }
        .font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
        .lineLimit(1).minimumScaleFactor(0.7)
        .accessibilityHidden(true)
    }

    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NoopMetrics.space3) { legendItems }
            VStack(alignment: .leading, spacing: 4) { legendItems }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var legendItems: some View {
        legendItem(Text("Fitness Age"), color: tint, dashed: false)
        legendItem(Text("Calendar age"), color: StrandPalette.textTertiary, dashed: true)
    }

    private func legendItem(_ label: Text, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 4) {
            if dashed {
                Rectangle().fill(color).frame(width: 3, height: 2)
                Rectangle().fill(color).frame(width: 3, height: 2)
            } else {
                Capsule().fill(color).frame(width: 10, height: 3)
            }
            label.font(StrandFont.micro).foregroundStyle(StrandPalette.textSecondary).textCase(.uppercase)
        }
    }

    private func dayText(_ time: TimeInterval) -> String {
        Date(timeIntervalSince1970: time).formatted(.dateTime.month(.abbreviated).day())
    }

    private func oneDecimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    private var accessibilityText: String {
        guard let first = points.first, let last = points.last else {
            return String(localized: "No Fitness Age trend yet.")
        }
        return String(localized: "Fitness Age changed from \(oneDecimal(first.fitnessAge)) to \(oneDecimal(last.fitnessAge)) over six months.")
    }
}
