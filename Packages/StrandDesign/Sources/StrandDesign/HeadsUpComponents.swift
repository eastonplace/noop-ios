import SwiftUI

// MARK: - Heads-Up
//
// The illness early-warning surfaces: the card that sits under Health Monitor on Today and the drawing parts of its
// detail page (the signal-strength meter, a signal's two-week line with its normal band, the daily history bars).
// They take plain, already-worded values: the app decides the read and the words, these only draw it in Today's flat
// language (a 16pt title, a neutral pill with the state's dot, Health Monitor's grid of signals with hairlines).

/// One signal in the card's strip.
public struct HeadsUpSignalCell: Equatable, Identifiable {
    public let id: String
    public let icon: String
    public let tint: Color
    public let label: String
    /// The change against the person's usual ("+6", "−22%"), or a dash.
    public let delta: String
    public let unit: String?
    /// "Up", "Down", "Normal" or a no-data word. Not drawn (the signed value and its colour say it); VoiceOver
    /// reads it.
    public let state: String
    /// The colour the delta takes when the signal is up against the person's usual; nil reads as normal.
    public let emphasis: Color?
    /// Where the last 2 nights sit on a rail whose middle 40% is the person's normal range; nil = no reading.
    public let position: Double?

    public init(id: String, icon: String, tint: Color, label: String, delta: String, unit: String?, state: String,
                emphasis: Color?, position: Double?) {
        self.id = id; self.icon = icon; self.tint = tint; self.label = label; self.delta = delta; self.unit = unit
        self.state = state; self.emphasis = emphasis; self.position = position
    }
}

/// Everything the Today card shows, worded by the app.
public struct HeadsUpCardModel: Equatable {
    public enum Content: Equatable {
        /// Heads-Up is off: the line and a Turn on button.
        case turnOn
        /// The baseline is still building: the bar only. The count lives in the line above it, once.
        case progress(fraction: Double)
        /// A read: the four signals.
        case signals([HeadsUpSignalCell])
    }

    /// A logged cause or a logged "feeling sick", shown under the signals.
    public struct Chip: Equatable {
        public let icon: String
        public let tint: Color
        public let text: String
        public init(icon: String, tint: Color, text: String) {
            self.icon = icon; self.tint = tint; self.text = text
        }
    }

    public let pill: String
    /// The state's colour: the pill's dot and the progress fill.
    public let tone: Color
    public let line: String
    /// The line in primary ink (a read that asks for something) rather than secondary (a calm one).
    public let lineIsPrimary: Bool
    public let content: Content
    public let chip: Chip?

    public init(pill: String, tone: Color, line: String, lineIsPrimary: Bool, content: Content, chip: Chip? = nil) {
        self.pill = pill; self.tone = tone; self.line = line; self.lineIsPrimary = lineIsPrimary
        self.content = content; self.chip = chip
    }
}

/// The Heads-Up card under Health Monitor. The whole card opens the detail page; when Heads-Up is off it is not a
/// button, only its Turn on action is.
public struct HeadsUpTodayCard: View {
    private let model: HeadsUpCardModel
    private let onOpen: () -> Void
    private let onTurnOn: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .headline) private var titleSize: CGFloat = 16
    @ScaledMetric(relativeTo: .subheadline) private var lineSize: CGFloat = 14
    @ScaledMetric(relativeTo: .caption) private var labelSize: CGFloat = 11
    @ScaledMetric(relativeTo: .title3) private var deltaSize: CGFloat = 18

    public init(model: HeadsUpCardModel, onOpen: @escaping () -> Void, onTurnOn: @escaping () -> Void = {}) {
        self.model = model
        self.onOpen = onOpen
        self.onTurnOn = onTurnOn
    }

    public var body: some View {
        Group {
            if case .turnOn = model.content {
                offCard
            } else {
                Button(action: onOpen) {
                    readCard.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: accessibilitySummary))
                .accessibilityHint(Text("Opens Heads-Up", bundle: .module))
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("today.headsUp.card")
            }
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Parts

    private func header(chevron: Bool) -> some View {
        let title = HStack(spacing: 6) {
            Text("Heads-Up", bundle: .module)
                .font(StrandFont.sized(titleSize, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        return Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    title
                    ValuePill(model.pill, tint: model.tone)
                }
            } else {
                // Centred, so the title and the pill's dot and text sit on one line however tall each is.
                HStack(alignment: .center, spacing: 8) {
                    title
                    Spacer(minLength: 8)
                    ValuePill(model.pill, tint: model.tone)
                }
            }
        }
    }

    private var line: some View {
        Text(verbatim: model.line)
            .font(StrandFont.sized(lineSize, weight: .medium))
            .foregroundStyle(model.lineIsPrimary ? StrandPalette.textPrimary : StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var offCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            header(chevron: false)
            line
            HStack(spacing: 12) {
                HeadsUpTextButton(action: onTurnOn) { Text("Turn on", bundle: .module) }
                    .accessibilityIdentifier("today.headsUp.turnOn")
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                    Text("Runs on your phone", bundle: .module)
                        .font(StrandFont.sized(labelSize))
                }
                .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.headsUp.off")
    }

    private var readCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(chevron: true)
            line
            switch model.content {
            case .turnOn:
                EmptyView()
            case let .progress(fraction):
                progress(fraction: fraction)
                    .padding(.top, 6)
            case let .signals(cells):
                strip(cells)
                    .padding(.top, 2)
            }
            if let chip = model.chip {
                chipView(chip).padding(.top, 4)
            }
        }
    }

    private func progress(fraction: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(StrandPalette.hairlineStrong.opacity(0.6))
                Capsule(style: .continuous).fill(model.tone)
                    .frame(width: proxy.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    private var columnCount: Int {
        if typeSize >= .accessibility3 { return 1 }
        return typeSize.isAccessibilitySize ? 2 : 4
    }

    private func strip(_ cells: [HeadsUpSignalCell]) -> some View {
        let columns = max(1, min(columnCount, max(1, cells.count)))
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: columns),
                         alignment: .leading, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                signalCell(cell)
                    .padding(.leading, index % columns == 0 ? 0 : 8)
                    .padding(.trailing, index % columns == columns - 1 ? 0 : 8)
                    .overlay(alignment: .leading) {
                        if index % columns != 0 {
                            Rectangle().fill(StrandPalette.hairline)
                                .frame(width: 1)
                                .padding(.vertical, 8)
                                .accessibilityHidden(true)
                        }
                    }
            }
        }
    }

    /// One column: the signal's name, its signed change in tabular digits and the normal-range rail. Every column
    /// is built the same and pinned to the top, so the names, the numbers' baselines and the rails line up across
    /// the four. A signal that is up takes the warning colour on its number; a normal one stays primary.
    private func signalCell(_ cell: HeadsUpSignalCell) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: cell.icon)
                    .font(.system(size: labelSize, weight: .medium))
                    .foregroundStyle(cell.tint)
                    .accessibilityHidden(true)
                Text(verbatim: cell.label)
                    .font(StrandFont.sized(labelSize))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    .minimumScaleFactor(0.8)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(verbatim: cell.delta)
                    .font(StrandFont.number(deltaSize, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(cell.emphasis ?? StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit = cell.unit, !unit.isEmpty {
                    Text(verbatim: unit)
                        .font(StrandFont.sized(labelSize))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.top, 8)
            HeadsUpRail(position: cell.position, dot: cell.emphasis ?? StrandPalette.textPrimary)
                .padding(.top, 10)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A logged fact under the signals: a bare symbol and a line of text, no capsule behind them.
    private func chipView(_ chip: HeadsUpCardModel.Chip) -> some View {
        HStack(spacing: 7) {
            Image(systemName: chip.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(chip.tint)
                .accessibilityHidden(true)
            Text(verbatim: chip.text)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accessibilitySummary: String {
        var parts = ["Heads-Up", model.pill, model.line]
        if case let .signals(cells) = model.content {
            parts += cells.map { cell in
                [cell.label, cell.delta + (cell.unit.map { " \($0)" } ?? ""), cell.state].joined(separator: " ")
            }
        }
        if let chip = model.chip { parts.append(chip.text) }
        return parts.filter { !$0.isEmpty }.joined(separator: ". ")
    }
}

/// A short rail whose middle 40% is the person's normal range, with a dot where the last 2 nights sit.
struct HeadsUpRail: View {
    let position: Double?
    let dot: Color

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(StrandPalette.hairline)
                    .frame(height: 4)
                Capsule(style: .continuous).fill(StrandPalette.hairlineStrong)
                    .frame(width: width * 0.4, height: 4)
                    .offset(x: width * 0.3)
                if let position {
                    Circle().fill(dot)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(StrandPalette.appCanvas, lineWidth: 1.5))
                        .offset(x: min(max(0, width * position - 4), max(0, width - 8)))
                }
            }
            .frame(width: width, height: 8)
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

// MARK: - Detail page parts

/// The 0–100 signal strength with its quiet / mild / heads-up zones at 25 and 50. `rawScore`, when the read was
/// softened by a logged cause, draws a thin marker where the score would have been.
public struct HeadsUpStrengthMeter: View {
    private let score: Double
    private let rawScore: Double?
    private let tone: Color
    private let note: String?
    @ScaledMetric(relativeTo: .title2) private var valueSize: CGFloat = 24

    public init(score: Double, rawScore: Double? = nil, tone: Color, note: String? = nil) {
        self.score = score
        self.rawScore = rawScore
        self.tone = tone
        self.note = note
    }

    private static func fraction(_ value: Double) -> Double { min(1, max(0, value / 100)) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Signal strength", bundle: .module).strandOverline()
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(verbatim: "\(Int(score.rounded()))")
                        .font(StrandFont.number(valueSize, weight: .bold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(verbatim: "/ 100")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(StrandPalette.hairline)
                        Rectangle().fill(StrandPalette.statusWarning.opacity(0.09))
                            .frame(width: width * 0.25)
                            .offset(x: width * 0.25)
                        Rectangle().fill(StrandPalette.statusWarning.opacity(0.16))
                            .frame(width: width * 0.5)
                            .offset(x: width * 0.5)
                    }
                    .frame(width: width, height: 8)
                    .clipShape(Capsule(style: .continuous))
                    if let rawScore {
                        Capsule(style: .continuous).fill(StrandPalette.textSecondary)
                            .frame(width: 2, height: 18)
                            .offset(x: width * Self.fraction(rawScore) - 1)
                    }
                    Capsule(style: .continuous).fill(tone)
                        .frame(width: max(8, width * Self.fraction(score)), height: 8)
                    Circle().fill(tone)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(StrandPalette.appCanvas, lineWidth: 3))
                        .offset(x: min(max(0, width * Self.fraction(score) - 7), max(0, width - 14)))
                }
                .frame(width: width, height: 18)
            }
            .frame(height: 18)
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    Text("Quiet", bundle: .module)
                    Text("Mild", bundle: .module).offset(x: proxy.size.width * 0.25)
                    Text("Heads-up", bundle: .module).offset(x: proxy.size.width * 0.5)
                }
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
            }
            .frame(height: 16)
            if let note {
                Text(verbatim: note)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Signal strength \(Int(score.rounded())) of 100" + (note.map { ". \($0)" } ?? "")))
    }
}

/// A signal's last two weeks: the normal band shaded, the older nights in quiet ink and the last
/// `highlightCount` nights in `highlight`, ending on a dot. Gaps where nothing was recorded stay gaps.
public struct HeadsUpSparkline: View {
    private let values: [Double?]
    private let band: ClosedRange<Double>?
    private let highlight: Color
    private let highlightCount: Int

    public init(values: [Double?], band: ClosedRange<Double>?, highlight: Color, highlightCount: Int = 2) {
        self.values = values
        self.band = band
        self.highlight = highlight
        self.highlightCount = max(1, highlightCount)
    }

    /// The vertical range drawn: every value and the band, padded so neither touches the edge.
    static func domain(values: [Double?], band: ClosedRange<Double>?) -> ClosedRange<Double> {
        var points = values.compactMap { $0 }
        if let band { points += [band.lowerBound, band.upperBound] }
        guard let low = points.min(), let high = points.max() else { return 0...1 }
        let span = max(high - low, max(abs(high), 1) * 0.02)
        return (low - span * 0.15)...(high + span * 0.15)
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let domain = Self.domain(values: values, band: band)
            let inset: CGFloat = 4
            let step = values.count > 1 ? (size.width - inset * 2) / CGFloat(values.count - 1) : 0
            let y: (Double) -> CGFloat = { value in
                let unit = (value - domain.lowerBound) / max(domain.upperBound - domain.lowerBound, 1e-9)
                return inset + (size.height - inset * 2) * CGFloat(1 - unit)
            }
            let split = max(0, values.count - highlightCount - 1)
            ZStack(alignment: .topLeading) {
                if let band {
                    let top = y(band.upperBound)
                    let bottom = y(band.lowerBound)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(StrandPalette.chipFill)
                        .frame(width: size.width, height: max(2, bottom - top))
                        .offset(y: top)
                    Path { path in
                        let middle = y((band.lowerBound + band.upperBound) / 2)
                        path.move(to: CGPoint(x: 0, y: middle))
                        path.addLine(to: CGPoint(x: size.width, y: middle))
                    }
                    .stroke(StrandPalette.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                }
                Self.line(values, from: 0, through: split, step: step, inset: inset, y: y)
                    .stroke(StrandPalette.textTertiary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                Self.line(values, from: split, through: values.count - 1, step: step, inset: inset, y: y)
                    .stroke(highlight, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                if let last = values.last, let value = last {
                    Circle().fill(highlight)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(StrandPalette.appCanvas, lineWidth: 2))
                        .offset(x: inset + step * CGFloat(values.count - 1) - 4, y: y(value) - 4)
                }
            }
        }
        .frame(height: 44)
        .accessibilityHidden(true)
    }

    private static func line(_ values: [Double?], from start: Int, through end: Int, step: CGFloat, inset: CGFloat,
                             y: (Double) -> CGFloat) -> Path {
        var path = Path()
        guard start <= end, values.indices.contains(start), values.indices.contains(end) else { return path }
        var drawing = false
        for index in start...end {
            guard let value = values[index] else {
                drawing = false
                continue
            }
            let point = CGPoint(x: inset + step * CGFloat(index), y: y(value))
            if drawing { path.addLine(to: point) } else { path.move(to: point) }
            drawing = true
        }
        return path
    }
}

/// One morning in the history chart.
public struct HeadsUpHistoryBar: Equatable, Identifiable {
    public let id: String
    public let score: Double
    public let color: Color
    /// A dashed outline to this height (the score before a logged cause softened it).
    public let outline: Double?

    public init(id: String, score: Double, color: Color, outline: Double? = nil) {
        self.id = id; self.score = score; self.color = color; self.outline = outline
    }
}

/// The last two weeks of mornings as bars, with the mild (25) and heads-up (50) lines. The scale tops out just above
/// the tallest bar (never below 64, so the heads-up line and its label always fit), so the bars and both lines use
/// the whole height instead of leaving it empty above a quiet fortnight.
public struct HeadsUpHistoryChart: View {
    private let bars: [HeadsUpHistoryBar]
    private let leadingLabel: String
    private let middleLabel: String
    private let trailingLabel: String

    public init(bars: [HeadsUpHistoryBar], leadingLabel: String, middleLabel: String, trailingLabel: String) {
        self.bars = bars
        self.leadingLabel = leadingLabel
        self.middleLabel = middleLabel
        self.trailingLabel = trailingLabel
    }

    /// The top of the vertical scale: 10% above the tallest bar or dashed outline, at least 64 and at most 100.
    /// Plain arithmetic, so it is callable off the main actor (tests, layout helpers) though the chart is a View.
    nonisolated public static func scaleTop(_ bars: [HeadsUpHistoryBar]) -> Double {
        let peak = bars.map { max($0.score, $0.outline ?? 0) }.max() ?? 0
        return min(100, max(64, (peak * 1.1).rounded(.up)))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let size = proxy.size
                let top = Self.scaleTop(bars)
                let height: (Double) -> CGFloat = { size.height * CGFloat(min(max($0, 0), top) / top) }
                ZStack(alignment: .topLeading) {
                    threshold(size: size, height: height(50), color: StrandPalette.statusWarning.opacity(0.5))
                    threshold(size: size, height: height(25), color: StrandPalette.statusWarning.opacity(0.3))
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(bars) { bar in
                            ZStack(alignment: .bottom) {
                                if let outline = bar.outline {
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .strokeBorder(StrandPalette.textSecondary,
                                                      style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                        .frame(height: max(2, height(outline)))
                                }
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(bar.color)
                                    .frame(height: max(2, height(bar.score)))
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                    .frame(width: size.width, height: size.height, alignment: .bottom)
                    // The labels sit over the bars so a tall bar never hides them.
                    thresholdLabel(Text("Heads-up · 50", bundle: .module), size: size, height: height(50))
                    thresholdLabel(Text("Mild · 25", bundle: .module), size: size, height: height(25))
                }
            }
            .frame(height: 88)
            HStack {
                Text(verbatim: leadingLabel)
                Spacer(minLength: 8)
                Text(verbatim: middleLabel)
                Spacer(minLength: 8)
                Text(verbatim: trailingLabel)
            }
            .font(StrandFont.micro)
            .foregroundStyle(StrandPalette.textTertiary)
            .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilitySummary))
    }

    private func threshold(size: CGSize, height: CGFloat, color: Color) -> some View {
        Path { path in
            let y = size.height - height
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        .stroke(color, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func thresholdLabel(_ label: Text, size: CGSize, height: CGFloat) -> some View {
        label
            .font(StrandFont.micro)
            .foregroundStyle(StrandPalette.textSecondary)
            .offset(y: size.height - height - 15)
    }

    private var accessibilitySummary: String {
        let latest = bars.last.map { Int($0.score.rounded()) } ?? 0
        let peak = bars.map(\.score).max().map { Int($0.rounded()) } ?? 0
        return "Signal strength over the last \(bars.count) days. Highest \(peak), latest \(latest)."
    }
}

// MARK: - Plain text action

/// A secondary action in the house style: accent text, no capsule, border or fill, with a 44pt tap area. The
/// package's twin of the app's Coach text button (which lives in the iOS target and so cannot be used here).
public struct HeadsUpTextButton<Label: View>: View {
    private let tint: Color
    private let action: () -> Void
    private let label: Label

    public init(tint: Color = StrandPalette.accent, action: @escaping () -> Void,
                @ViewBuilder label: () -> Label) {
        self.tint = tint
        self.action = action
        self.label = label()
    }

    public var body: some View {
        Button(action: action) {
            label
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
