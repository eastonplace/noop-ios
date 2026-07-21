import SwiftUI

// MARK: - Metric detail

/// A dated value used by the promoted Metric Detail kit. Dates are deliberately
/// retained so sparse series never become a misleading evenly-spaced fixture.
public struct MetricDetailSample: Identifiable, Equatable, Sendable {
    public let date: Date
    public let value: Double

    public var id: Date { date }

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

public struct MetricDetailStat: Equatable, Sendable {
    public let value: String
    public let detail: String

    public init(value: String, detail: String) {
        self.value = value
        self.detail = detail
    }
}

public struct MetricDetailTypicalRange: Equatable, Sendable {
    public let range: ClosedRange<Double>
    public let label: String

    public init(range: ClosedRange<Double>, label: String) {
        self.range = range
        self.label = label
    }
}

/// Immutable display model for the promoted Metric Detail kit. Business logic,
/// storage and range selection stay in the host; every section is optional.
public struct MetricDetailConfig {
    public let id: String
    public let title: String
    public let subtitle: String
    public let icon: String
    public let tint: Color
    public let unit: String
    public let currentValue: Double
    public let asOf: Date
    public let delta: String?
    public let deltaPositive: Bool?
    public let stateWord: String?
    public let stateGood: Bool?
    public let typical: MetricDetailTypicalRange?
    public let samples: [MetricDetailSample]
    public let baseline: Double?
    public let stats: (low: MetricDetailStat, average: MetricDetailStat, high: MetricDetailStat)?
    public let about: String?
    public let format: (Double) -> String

    public init(
        id: String,
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        unit: String,
        currentValue: Double,
        asOf: Date,
        delta: String? = nil,
        deltaPositive: Bool? = nil,
        stateWord: String? = nil,
        stateGood: Bool? = nil,
        typical: MetricDetailTypicalRange? = nil,
        samples: [MetricDetailSample] = [],
        baseline: Double? = nil,
        stats: (low: MetricDetailStat, average: MetricDetailStat, high: MetricDetailStat)? = nil,
        about: String? = nil,
        format: @escaping (Double) -> String = { "\(Int($0.rounded()))" }
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
        self.unit = unit
        self.currentValue = currentValue
        self.asOf = asOf
        self.delta = delta
        self.deltaPositive = deltaPositive
        self.stateWord = stateWord
        self.stateGood = stateGood
        self.typical = typical
        self.samples = samples.sorted { $0.date < $1.date }
        self.baseline = baseline
        self.stats = stats
        self.about = about
        self.format = format
    }
}

public struct MetricDetailHeroCard: View {
    public let config: MetricDetailConfig

    public init(config: MetricDetailConfig) { self.config = config }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: config.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(config.tint)
                    .frame(width: 32, height: 32)
                    .background(config.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(config.title.uppercased())
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(config.subtitle)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 8)
                if let stateWord = config.stateWord {
                    Text(stateWord.uppercased())
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(stateColor)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(config.format(config.currentValue))
                    .font(StrandFont.number(40, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
                    .contentTransition(.numericText())
                if !config.unit.isEmpty {
                    Text(config.unit)
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                if let delta = config.delta {
                    Text(delta)
                        .font(StrandFont.captionNumber)
                        .monospacedDigit()
                        .foregroundStyle(deltaColor)
                        .padding(.leading, 4)
                }
                Spacer(minLength: 0)
            }

            Text("as of \(config.asOf.formatted(date: .abbreviated, time: .omitted))")
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)

            if let typical = config.typical {
                typicalRail(typical)
                Text(typical.label)
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(StrandPalette.surfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1)
                )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var stateColor: Color {
        guard let good = config.stateGood else { return StrandPalette.textTertiary }
        return good ? StrandPalette.statusPositive : StrandPalette.statusWarning
    }

    private var deltaColor: Color {
        guard let positive = config.deltaPositive else { return StrandPalette.textTertiary }
        return positive ? StrandPalette.statusPositive : StrandPalette.metricRose
    }

    private var accessibilitySummary: String {
        [config.title, config.format(config.currentValue), config.unit, config.stateWord, config.delta]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private func typicalRail(_ typical: MetricDetailTypicalRange) -> some View {
        GeometryReader { proxy in
            let allValues = config.samples.map(\.value) + [typical.range.lowerBound, typical.range.upperBound]
            let lo = allValues.min() ?? typical.range.lowerBound
            let hi = allValues.max() ?? typical.range.upperBound
            let span = max(hi - lo, 0.000_001)
            let lower = (typical.range.lowerBound - lo) / span
            let upper = (typical.range.upperBound - lo) / span
            let position = (config.currentValue - lo) / span
            ZStack(alignment: .leading) {
                Capsule().fill(StrandPalette.surfaceInset)
                DiagonalHatch(spacing: 5)
                    .stroke(config.tint.opacity(0.55), lineWidth: 1)
                    .frame(width: proxy.size.width * max(0, min(1, upper) - max(0, lower)))
                    .clipShape(Capsule())
                    .offset(x: proxy.size.width * max(0, min(1, lower)))
                Circle()
                    .fill(stateColor)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(StrandPalette.surfaceRaised, lineWidth: 1.5))
                    .position(x: proxy.size.width * max(0, min(1, position)), y: 6)
            }
        }
        .frame(height: 12)
    }
}

/// Promoted composition shell. The host supplies the existing range control and
/// optional dossier tools as real views, keeping the kit config-driven without
/// teaching StrandDesign about repositories or exports.
public struct MetricDetailTemplate<RangeControl: View, Extensions: View>: View {
    public let config: MetricDetailConfig
    private let rangeControl: RangeControl
    private let extensions: Extensions

    public init(
        config: MetricDetailConfig,
        @ViewBuilder rangeControl: () -> RangeControl,
        @ViewBuilder extensions: () -> Extensions
    ) {
        self.config = config
        self.rangeControl = rangeControl()
        self.extensions = extensions()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MetricDetailHeroCard(config: config)
            rangeControl
            if let baseline = config.baseline, let typical = config.typical, !config.samples.isEmpty {
                sectionLabel("Trend")
                let reference = config.samples.last?.date ?? config.asOf
                let days = config.samples.map { CalendarMetricDay(date: $0.date, value: $0.value) }
                TrendPanelChart(
                    days: days,
                    dateDomain: (config.samples.first?.date ?? reference)...reference,
                    referenceDate: reference,
                    baseline: baseline,
                    typical: typical.range,
                    tint: config.tint,
                    unit: config.unit,
                    valueFormat: config.format,
                    range: trendRange(for: config.samples.count)
                )
            }
            if let stats = config.stats {
                sectionLabel("Window stats")
                HRRangeStrip(
                    low: stats.low.value, lowDetail: stats.low.detail,
                    average: stats.average.value, averageDetail: stats.average.detail,
                    peak: stats.high.value, peakDetail: stats.high.detail
                )
            }
            if let about = config.about {
                sectionLabel("How this is computed")
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "function")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                    Text(about)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(StrandPalette.surfaceInset.opacity(0.7), in: RoundedRectangle(cornerRadius: 13))
            }
            extensions
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(StrandFont.overline)
            .tracking(StrandFont.overlineTracking)
            .foregroundStyle(StrandPalette.textTertiary)
    }

    private func trendRange(for count: Int) -> TrendRange {
        switch count {
        case ...7: return .week
        case ...30: return .month
        case ...90: return .quarter
        default: return .half
        }
    }
}

// MARK: - Sparse-window resolver

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

    public init(
        title: String,
        unit: String,
        tint: Color,
        points: [ComparePoint],
        format: @escaping (Double) -> String = { "\(Int($0.rounded()))" }
    ) {
        self.title = title
        self.unit = unit
        self.tint = tint
        self.points = points.sorted { $0.date < $1.date }
        self.format = format
    }

    fileprivate var values: [Double] { points.map(\.value) }
    fileprivate var minValue: Double { values.min() ?? 0 }
    fileprivate var maxValue: Double { values.max() ?? 0 }
    fileprivate func normalized(_ value: Double) -> Double {
        guard maxValue > minValue else { return 0.5 }
        return min(max((value - minValue) / (maxValue - minValue), 0), 1)
    }
}

public struct ComparePickerRow: View {
    public let seriesA: CompareSeries
    public let seriesB: CompareSeries
    public let onPickA: () -> Void
    public let onPickB: () -> Void
    public let onSwap: () -> Void

    public init(seriesA: CompareSeries, seriesB: CompareSeries,
                onPickA: @escaping () -> Void, onPickB: @escaping () -> Void,
                onSwap: @escaping () -> Void) {
        self.seriesA = seriesA
        self.seriesB = seriesB
        self.onPickA = onPickA
        self.onPickB = onPickB
        self.onSwap = onSwap
    }

    public var body: some View {
        HStack(spacing: 8) {
            picker(role: "A", series: seriesA, action: onPickA)
            Button(action: onSwap) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(StrandPalette.surfaceInset, in: Circle())
            }
            .buttonStyle(StressModulePressStyle())
            .accessibilityLabel("Swap comparison axes")
            picker(role: "B", series: seriesB, action: onPickB)
        }
    }

    private func picker(role: String, series: CompareSeries, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(role).font(StrandFont.micro).foregroundStyle(series.tint)
                Text(series.title).font(StrandFont.caption).foregroundStyle(StrandPalette.textPrimary).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(StrandPalette.hairlineStrong))
        }
        .buttonStyle(StressModulePressStyle())
        .accessibilityLabel("Metric \(role), \(series.title). Opens picker")
    }
}

public struct CompareLagOption: Identifiable, Hashable, Sendable {
    public let days: Int
    public let label: String
    public var id: Int { days }

    public init(days: Int, label: String) {
        self.days = days
        self.label = label
    }
}

public struct CompareLagChips: View {
    public let options: [CompareLagOption]
    @Binding public var selectedDays: Int

    public init(options: [CompareLagOption], selectedDays: Binding<Int>) {
        self.options = options
        self._selectedDays = selectedDays
    }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { option in
                Button {
                    withAnimation(StrandMotion.interactive) { selectedDays = option.days }
                    StrandHaptic.selection.play()
                } label: {
                    Text(option.label)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(selectedDays == option.days ? StrandPalette.surfaceRaised : StrandPalette.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(selectedDays == option.days ? StrandPalette.textPrimary : StrandPalette.surfaceInset, in: Capsule())
                }
                .buttonStyle(StressModulePressStyle())
                .accessibilityAddTraits(selectedDays == option.days ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }
}

public struct CompareDualChart: View {
    public let seriesA: CompareSeries
    public let seriesB: CompareSeries
    public let evidenceLabel: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    @State private var scrubIndex: Int?

    public init(seriesA: CompareSeries, seriesB: CompareSeries, evidenceLabel: String) {
        self.seriesA = seriesA
        self.seriesB = seriesB
        self.evidenceLabel = evidenceLabel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            readout
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    grid(in: proxy.size)
                    trace(seriesB, in: proxy.size)
                        .trim(from: 0, to: revealed ? 1 : 0)
                        .stroke(seriesB.tint.opacity(0.85), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [5, 4]))
                    trace(seriesA, in: proxy.size)
                        .trim(from: 0, to: revealed ? 1 : 0)
                        .stroke(seriesA.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    if let scrubIndex { scrub(index: scrubIndex, in: proxy.size) }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let count = min(seriesA.points.count, seriesB.points.count)
                    guard count > 0 else { return }
                    let fraction = min(1, max(0, value.location.x / max(1, proxy.size.width)))
                    scrubIndex = Int((fraction * Double(count - 1)).rounded())
                }.onEnded { _ in scrubIndex = nil })
            }
            .frame(height: 172)
            Text(evidenceLabel).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : StrandMotion.drawIn) { revealed = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(seriesA.title) versus \(seriesB.title), \(min(seriesA.points.count, seriesB.points.count)) paired days")
    }

    private var readout: some View {
        HStack(spacing: 12) {
            readout(seriesA)
            readout(seriesB)
            Spacer(minLength: 0)
        }
    }

    private func readout(_ series: CompareSeries) -> some View {
        let index = min(scrubIndex ?? max(0, series.points.count - 1), max(0, series.points.count - 1))
        let value = series.points.isEmpty ? nil : series.points[index].value
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Circle().fill(series.tint).frame(width: 7, height: 7)
            Text(value.map(series.format) ?? "—").font(StrandFont.captionNumber).monospacedDigit()
            Text(series.unit).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func trace(_ series: CompareSeries, in size: CGSize) -> Path {
        let allDates = seriesA.points.map(\.date) + seriesB.points.map(\.date)
        let firstDate = allDates.min() ?? Date()
        let lastDate = allDates.max() ?? firstDate
        let duration = max(lastDate.timeIntervalSince(firstDate), 1)
        let points = series.points.map { point in
            CGPoint(
                x: size.width * CGFloat(point.date.timeIntervalSince(firstDate) / duration),
                y: 12 + (size.height - 24) * (1 - CGFloat(series.normalized(point.value)))
            )
        }
        return Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            points.dropFirst().forEach { path.addLine(to: $0) }
        }
    }

    private func grid(in size: CGSize) -> some View {
        ZStack {
            ForEach(0..<4, id: \.self) { line in
                Path { path in
                    let y = size.height * CGFloat(line) / 3
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
                }
                .stroke(StrandPalette.hairline, style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            }
        }
    }

    private func scrub(index: Int, in size: CGSize) -> some View {
        let count = min(seriesA.points.count, seriesB.points.count)
        let x = size.width * CGFloat(index) / CGFloat(max(1, count - 1))
        return Rectangle().fill(StrandPalette.hairlineStrong).frame(width: 1, height: size.height).position(x: x, y: size.height / 2)
    }
}

public struct CompareCorrelationCard: View {
    public let correlation: Double
    public let headline: String
    public let sentence: String
    public let evidence: String

    public init(correlation: Double, headline: String, sentence: String, evidence: String) {
        self.correlation = correlation
        self.headline = headline
        self.sentence = sentence
        self.evidence = evidence
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(strength.uppercased()).font(StrandFont.overline).tracking(StrandFont.overlineTracking).foregroundStyle(tone)
                Spacer()
                ForEach(0..<5, id: \.self) { pip in
                    Capsule().fill(pip < filledPips ? tone : StrandPalette.surfaceInset).frame(width: 12, height: 5)
                }
                Image(systemName: correlation < 0 ? "arrow.down.right" : "arrow.up.right")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(tone)
            }
            Text(headline).font(StrandFont.caption.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
            Text(sentence).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            Text(evidence).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(13)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(StrandPalette.hairline))
        .accessibilityElement(children: .combine)
    }

    private var strength: String {
        switch abs(correlation) { case 0.7...: "Strongly linked"; case 0.4...: "Moderately linked"; case 0.2...: "Weakly linked"; default: "No clear link" }
    }
    private var filledPips: Int { Int((abs(correlation) * 5).rounded(.up)) }
    private var tone: Color {
        abs(correlation) >= 0.4 ? (correlation < 0 ? StrandPalette.metricRose : StrandPalette.chargeAccent) : StrandPalette.textSecondary
    }
}

public struct CompareStatDuo: View {
    public let leftTitle: String
    public let leftValue: String
    public let rightTitle: String
    public let rightValue: String
    public let unit: String
    public let tint: Color

    public init(leftTitle: String, leftValue: String, rightTitle: String, rightValue: String, unit: String, tint: Color) {
        self.leftTitle = leftTitle; self.leftValue = leftValue
        self.rightTitle = rightTitle; self.rightValue = rightValue
        self.unit = unit; self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 0) {
            cell(leftTitle, leftValue)
            Rectangle().fill(StrandPalette.hairline).frame(width: 1).padding(.vertical, 4)
            cell(rightTitle, rightValue)
        }
        .padding(.vertical, 11)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(StrandPalette.hairline))
    }

    private func cell(_ title: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(StrandFont.captionNumber).monospacedDigit()
                Text(unit).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
            }
            Text(title).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }
}
