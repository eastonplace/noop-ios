import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Training load page sections
//
// The parts of the Training load page that are not the chart: the headline and gauge, the three numbers explained,
// where tomorrow could land, the week-by-week bars, what drove the week, where the load came from, the comparison with
// the four weeks before, and the method. Each takes plain values from `TrainingLoadPageModel` (which holds every derived
// number) and only draws.

// MARK: Ink and words

/// The colours the page uses, all from the palette: the strain blue for recent load, the same blue at 45% for the fitness
/// base, a quiet slate for easing and the amber for a spike.
enum TrainingLoadInk {
    static let recent = StrandPalette.strainAccent
    static let base = StrandPalette.strainAccent.opacity(0.45)
    /// The base's value, a lighter blue so it reads on the dark canvas.
    static let baseText = StrandPalette.recoveryData
    static let easing = StrandPalette.sleepAccent
    static let spike = StrandPalette.metricAmber
    static let surface = StrandPalette.card

    /// The gauge track's three zones, in order.
    static let zones: [(range: ClosedRange<Double>, color: Color)] = [
        (0.5...0.8, easing.opacity(0.4)),
        (0.8...1.3, recent),
        (1.3...1.6, spike.opacity(0.85)),
    ]

    static func text(_ zone: TrainingLoadPageModel.Zone) -> Color {
        switch zone {
        case .easing: easing
        case .sweetSpot: baseText
        case .nearSpike: spike.opacity(0.8)
        case .spike: spike
        }
    }
}

enum TrainingLoadWords {
    static func headline(_ headline: TrainingLoadPageModel.Headline?) -> LocalizedStringKey {
        switch headline {
        case .easing?: "Easing off"
        case .holding?: "Holding steady"
        case .building?: "Building, in the sweet spot"
        case .spiking?: "Spiking above your base"
        case nil: "No base to compare yet"
        }
    }

    /// The sentence after the percentage: what that band describes, never what to do about it.
    static func bandSentence(_ headline: TrainingLoadPageModel.Headline?) -> AttributedString {
        switch headline {
        case .easing?: AttributedString(localized: "That is lighter than the load your body is used to.")
        case .holding?: AttributedString(localized: "That is close to the load your body is used to.")
        case .building?: AttributedString(localized: "That is a steady build.")
        case .spiking?: AttributedString(localized: "That is a sharper jump than your base is used to.")
        case nil: AttributedString(localized: "Your fitness base is too small to compare recent load against yet.")
        }
    }

    static func zone(_ zone: TrainingLoadPageModel.Zone) -> String {
        switch zone {
        case .easing: String(localized: "Easing")
        case .sweetSpot: String(localized: "Sweet spot")
        case .nearSpike: String(localized: "Near spike")
        case .spike: String(localized: "Spike")
        }
    }

    static func ratio(_ ratio: Double) -> String {
        ratio.formatted(.number.precision(.fractionLength(2))) + "×"
    }

    static func number(_ value: Double) -> String { DrillInFormat.number(value, fractionDigits: 1) }
    static func signed(_ value: Double) -> String { DrillInFormat.signed(value, fractionDigits: 1) }

    /// "1.7 this week", "1.7 vs 8 days ago", or "No change" when the move prints as nothing.
    static func changeText(_ change: TrainingLoadPageModel.Change) -> String {
        let magnitude = abs(change.delta)
        guard (magnitude * 10).rounded() > 0 else { return String(localized: "No change") }
        let value = number(magnitude)
        return change.isWeek
            ? String(localized: "\(value) this week")
            : String(localized: "\(value) vs \(change.daysAgo) days ago")
    }

    /// What VoiceOver says for a change: "up 1.7 this week".
    static func spokenChange(_ change: TrainingLoadPageModel.Change) -> String {
        let magnitude = abs(change.delta)
        guard (magnitude * 10).rounded() > 0 else { return String(localized: "no change") }
        let value = number(magnitude)
        switch (change.delta > 0, change.isWeek) {
        case (true, true): return String(localized: "up \(value) this week")
        case (false, true): return String(localized: "down \(value) this week")
        case (true, false): return String(localized: "up \(value) since \(change.daysAgo) days ago")
        case (false, false): return String(localized: "down \(value) since \(change.daysAgo) days ago")
        }
    }
}

// MARK: - Hero

/// The headline, its one-line meaning and the gauge. Descriptive only: it says where recent load sits against the base,
/// never what to do, and never that it moves Readiness.
struct TrainingLoadHero: View {
    let model: TrainingLoadPageModel
    @ScaledMetric(relativeTo: .largeTitle) private var headlineSize: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(TrainingLoadWords.headline(model.headline))
                .font(.system(size: min(headlineSize, 56), weight: .bold))
                .tracking(-0.8)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineSpacing(0)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 2)
            lede
                .font(Font.system(.callout, design: .default).weight(.regular))
                .foregroundStyle(StrandPalette.textSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            if let ratio = model.ratio {
                TrainingLoadGauge(ratio: ratio)
                    .padding(.top, 20)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("trends.trainingLoad.hero")
    }

    /// "Your recent load is **23% above** your fitness base. That is a steady build."
    private var lede: Text {
        guard let ratio = model.ratio else { return Text(TrainingLoadWords.bandSentence(nil)) }
        let percent = TrainingLoadPageModel.percentFromBase(ratio: ratio)
        let amount = abs(percent)
        var text: AttributedString
        if percent > 0 {
            text = AttributedString(localized: "Your recent load is **\(amount)% above** your fitness base.")
        } else if percent < 0 {
            text = AttributedString(localized: "Your recent load is **\(amount)% below** your fitness base.")
        } else {
            text = AttributedString(localized: "Your recent load is **level with** your fitness base.")
        }
        text.append(AttributedString(" "))
        text.append(TrainingLoadWords.bandSentence(model.headline))
        return Text(text)
    }
}

/// Where the ratio sits: three zones (easing, sweet spot, spike), a marker, and a "You · 1.20×" badge above it. The badge is
/// part of the layout, so it can never ride up over the lede, and it is held inside the row at either end.
struct TrainingLoadGauge: View {
    let ratio: Double
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .caption) private var badgeSize: CGFloat = 12

    private var fraction: Double { TrainingLoadPageModel.gaugeFraction(forRatio: ratio) }
    private static let gap: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TrainingLoadAnchoredRow(fraction: fraction) { badge }
                .padding(.bottom, 8)
            track
            labels.padding(.top, 9)
        }
        // One spoken element inside the hero's combined one: the ratio, the zone it falls in and where the zones cut.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
    }

    /// "Recent load is 1.20 times your fitness base, in the Sweet spot zone. Easing is under 0.8, ..."
    private var spoken: String {
        let times = ratio.formatted(.number.precision(.fractionLength(2)))
        let zone = TrainingLoadWords.zone(TrainingLoadPageModel.zone(forRatio: ratio))
        return String(localized: "Recent load is \(times) times your fitness base, in the \(zone) zone. Easing is under 0.8, sweet spot 0.8 to 1.3, spike above 1.3.")
    }

    private var badge: some View {
        Text("You · \(TrainingLoadWords.ratio(ratio))")
            .font(.system(size: min(badgeSize, 22), weight: .bold))
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(StrandPalette.inset))
    }

    private var track: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let usable = max(width - Self.gap * 2, 1)
            let span = TrainingLoadPageModel.gaugeRange.upperBound - TrainingLoadPageModel.gaugeRange.lowerBound
            ZStack(alignment: .leading) {
                HStack(spacing: Self.gap) {
                    ForEach(Array(TrainingLoadInk.zones.enumerated()), id: \.offset) { _, zone in
                        Capsule(style: .continuous)
                            .fill(zone.color)
                            .frame(width: usable * (zone.range.upperBound - zone.range.lowerBound) / span, height: 12)
                    }
                }
                .frame(height: 12)
                ZStack {
                    Capsule(style: .continuous).fill(StrandPalette.canvas).frame(width: 10, height: 36)
                    Capsule(style: .continuous).fill(StrandPalette.textPrimary).frame(width: 4, height: 30)
                }
                .position(x: min(max(width * fraction, 5), width - 5), y: 6)
            }
            .frame(height: 12)
        }
        .frame(height: 30)
        .padding(.vertical, 0)
    }

    @ViewBuilder private var labels: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                label("Easing, under 0.8×", color: StrandPalette.textTertiary)
                label("Sweet spot, 0.8–1.3×", color: TrainingLoadInk.baseText)
                label("Spike, above 1.3×", color: StrandPalette.textTertiary)
            }
        } else {
            let span = TrainingLoadPageModel.gaugeRange.upperBound - TrainingLoadPageModel.gaugeRange.lowerBound
            Text(verbatim: "Mg")
                .font(StrandFont.caption)
                .hidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay {
                    GeometryReader { proxy in
                        let usable = max(proxy.size.width - Self.gap * 2, 1)
                        let widths = TrainingLoadInk.zones.map { usable * ($0.range.upperBound - $0.range.lowerBound) / span }
                        HStack(spacing: Self.gap) {
                            label("Easing", color: StrandPalette.textTertiary)
                                .frame(width: widths[0], alignment: .leading)
                            label("Sweet spot 0.8–1.3×", color: TrainingLoadInk.baseText)
                                .frame(width: widths[1], alignment: .center)
                            label("Spike", color: StrandPalette.textTertiary)
                                .frame(width: widths[2], alignment: .trailing)
                        }
                    }
                }
        }
    }

    private func label(_ key: LocalizedStringKey, color: Color) -> some View {
        Text(key)
            .font(StrandFont.caption.weight(.medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// Puts its one child centred on a fraction of the row's width, held inside the row at both ends.
struct TrainingLoadAnchoredLayout: Layout {
    let fraction: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let child = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(width: proposal.width ?? child.width, height: child.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let size = subview.sizeThatFits(.unspecified)
        let center = bounds.minX + bounds.width * CGFloat(fraction)
        let x = min(max(center - size.width / 2, bounds.minX), max(bounds.maxX - size.width, bounds.minX))
        subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: .unspecified)
    }
}

struct TrainingLoadAnchoredRow<Content: View>: View {
    let fraction: Double
    @ViewBuilder let content: () -> Content

    var body: some View {
        TrainingLoadAnchoredLayout(fraction: fraction) { content() }
    }
}

// MARK: - Three numbers, explained

/// Recent load, fitness base and Form, each with a colour swatch, what it means in a line, its value and, for the first two,
/// how it moved since about a week ago. Stacks at the accessibility sizes.
struct TrainingLoadNumbers: View {
    let model: TrainingLoadPageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TrainingLoadNumberRow(
                swatch: TrainingLoadInk.recent, title: "Recent load · 7 days",
                meaning: "How hard you've trained lately. Reacts within days.",
                value: model.recent.map(TrainingLoadWords.number) ?? WidgetMetrics.missingValue,
                sub: model.recentChange.map { .change($0) },
                spoken: spoken(String(localized: "Recent load"), model.recent, change: model.recentChange))
                .accessibilityIdentifier("trends.trainingLoad.recent")
            FlatRowSeparator()
            TrainingLoadNumberRow(
                swatch: TrainingLoadInk.base, title: "Fitness base · 6 weeks",
                meaning: "The load your body is used to. Moves slowly.",
                value: model.base.map(TrainingLoadWords.number) ?? WidgetMetrics.missingValue,
                sub: model.baseChange.map { .change($0) },
                spoken: spoken(String(localized: "Fitness base"), model.base, change: model.baseChange))
                .accessibilityIdentifier("trends.trainingLoad.base")
            FlatRowSeparator()
            TrainingLoadNumberRow(
                swatch: StrandPalette.textSecondary, title: "Form · base minus recent",
                meaning: "Below zero: training above your base. Above zero: fresher.",
                value: model.form.map(TrainingLoadWords.signed) ?? WidgetMetrics.missingValue,
                sub: formSub.map { .text($0) },
                spoken: formSpoken)
                .accessibilityIdentifier("trends.trainingLoad.form")
        }
    }

    private var formSub: String? {
        switch model.formState {
        case .aboveBase?: String(localized: "training above base")
        case .fresher?: String(localized: "fresher than base")
        case .level?: String(localized: "level with base")
        case nil: nil
        }
    }

    private func spoken(_ name: String, _ value: Double?, change: TrainingLoadPageModel.Change?) -> String {
        guard let value else { return name }
        var parts = name + " " + TrainingLoadWords.number(value)
        if let change { parts += ", " + TrainingLoadWords.spokenChange(change) }
        return parts
    }

    private var formSpoken: String {
        let name = String(localized: "Form")
        guard let form = model.form else { return name }
        return [name + " " + TrainingLoadWords.signed(form), formSub].compactMap { $0 }.joined(separator: ", ")
    }
}

struct TrainingLoadNumberRow: View {
    enum Sub {
        case change(TrainingLoadPageModel.Change)
        case text(String)
    }

    let swatch: Color
    let title: LocalizedStringKey
    let meaning: LocalizedStringKey
    let value: String
    let sub: Sub?
    let spoken: String
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title) private var valueSize: CGFloat = 30

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    heading
                    valueBlock(alignment: .leading)
                    meaningText
                }
            } else {
                HStack(alignment: .center, spacing: NoopMetrics.space3) {
                    VStack(alignment: .leading, spacing: 3) {
                        heading
                        meaningText.frame(maxWidth: 240, alignment: .leading)
                    }
                    Spacer(minLength: NoopMetrics.space2)
                    valueBlock(alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
        .accessibilityHint(Text(meaning))
    }

    private var heading: some View {
        HStack(spacing: 7) {
            Capsule(style: .continuous).fill(swatch).frame(width: 14, height: 3)
            Text(title)
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var meaningText: some View {
        Text(meaning)
            .font(Font.system(.subheadline, design: .default).weight(.regular))
            .foregroundStyle(StrandPalette.textPrimary)
            .lineSpacing(1)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func valueBlock(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(verbatim: value)
                .font(.system(size: min(valueSize, 44), weight: .semibold).monospacedDigit())
                .tracking(-0.6)
                .foregroundStyle(value == WidgetMetrics.missingValue ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            subLabel
        }
    }

    @ViewBuilder private var subLabel: some View {
        switch sub {
        case .change(let change)?:
            HStack(spacing: 3) {
                if (abs(change.delta) * 10).rounded() > 0 {
                    Image(systemName: change.delta > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                        .font(.system(size: 8))
                        .accessibilityHidden(true)
                }
                Text(verbatim: TrainingLoadWords.changeText(change))
            }
            .font(StrandFont.caption.weight(.medium))
            .foregroundStyle(StrandPalette.textSecondary)
        case .text(let text)?:
            Text(verbatim: text)
                .font(StrandFont.caption.weight(.medium))
                .foregroundStyle(StrandPalette.textSecondary)
        case nil:
            EmptyView()
        }
    }
}

// MARK: - Tomorrow

/// Three imagined tomorrows (rest, a moderate session, all out) run through the engine's own next step: the recent load it
/// would leave, where that sits on the gauge, the ratio and the zone. Not a recommendation, and it says so.
struct TrainingLoadTomorrow: View {
    let projections: [TrainingLoadPageModel.Projection]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(projections.enumerated()), id: \.offset) { index, projection in
                if index > 0 { FlatRowSeparator() }
                TrainingLoadTomorrowRow(projection: projection)
            }
            Text("Same math as above, one day forward. Not a recommendation.")
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
    }
}

private struct TrainingLoadTomorrowRow: View {
    let projection: TrainingLoadPageModel.Projection
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var ratioSize: CGFloat = 17

    private var name: LocalizedStringKey {
        switch projection.scenario {
        case .rest: "Rest day"
        case .moderate: "Moderate session"
        case .allOut: "All out"
        }
    }

    private var effortText: String { DrillInFormat.number(projection.effort, fractionDigits: 0) }
    private var recentText: String { TrainingLoadWords.number(projection.recent) }
    private var meta: String { String(localized: "Effort \(effortText) → recent \(recentText)") }

    private var spoken: String {
        let scenario = switch projection.scenario {
        case .rest: String(localized: "Rest day")
        case .moderate: String(localized: "Moderate session")
        case .allOut: String(localized: "All out")
        }
        guard let ratio = projection.ratio, let zone = projection.zone else { return scenario }
        return String(localized: "\(scenario): Effort \(effortText), recent load \(recentText), ratio \(TrainingLoadWords.ratio(ratio)), \(TrainingLoadWords.zone(zone))")
    }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    title
                    outcome
                    if let ratio = projection.ratio { miniGauge(ratio) }
                }
            } else {
                HStack(spacing: NoopMetrics.space3) {
                    title.frame(maxWidth: .infinity, alignment: .leading)
                    if let ratio = projection.ratio { miniGauge(ratio).frame(width: 104) }
                    outcome.frame(width: 84, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(Font.system(.subheadline, design: .default).weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: meta)
                .font(StrandFont.caption.weight(.regular))
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var outcome: some View {
        if let ratio = projection.ratio, let zone = projection.zone {
            VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 0) {
                Text(verbatim: TrainingLoadWords.ratio(ratio))
                    .font(.system(size: min(ratioSize, 30), weight: .semibold).monospacedDigit())
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(verbatim: TrainingLoadWords.zone(zone))
                    .font(StrandFont.micro.weight(.semibold))
                    .foregroundStyle(TrainingLoadInk.text(zone))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        } else {
            Text(verbatim: WidgetMetrics.missingValue).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    /// The gauge's three zones in miniature with the projected ratio marked.
    private func miniGauge(_ ratio: Double) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let usable = max(width - 4, 1)
            let span = TrainingLoadPageModel.gaugeRange.upperBound - TrainingLoadPageModel.gaugeRange.lowerBound
            ZStack(alignment: .leading) {
                HStack(spacing: 2) {
                    ForEach(Array(TrainingLoadInk.zones.enumerated()), id: \.offset) { _, zone in
                        Capsule(style: .continuous).fill(zone.color)
                            .frame(width: usable * (zone.range.upperBound - zone.range.lowerBound) / span, height: 6)
                    }
                }
                ZStack {
                    Capsule(style: .continuous).fill(StrandPalette.canvas).frame(width: 7, height: 20)
                    Capsule(style: .continuous).fill(StrandPalette.textPrimary).frame(width: 3, height: 16)
                }
                .position(x: min(max(width * TrainingLoadPageModel.gaugeFraction(forRatio: ratio), 2), width - 2), y: 3)
            }
            .frame(height: 6)
        }
        .frame(height: 16)
        .accessibilityHidden(true)
    }
}

// MARK: - Week by week

/// The last six calendar weeks: a bar per week (its average daily Effort) and the fitness base at each week's end as a dashed
/// line with dots. The current week is solid and its label is right-aligned to the chart's edge so it is never clipped.
/// At the accessibility sizes it becomes a list, because six labelled columns cannot hold that type.
struct TrainingLoadWeeks: View {
    struct Entry: Identifiable {
        let id: Date
        let label: String
        let isCurrent: Bool
        let average: Double?
        let base: Double?
    }

    let entries: [Entry]
    @Environment(\.dynamicTypeSize) private var typeSize

    private var spoken: String {
        entries.map { entry in
            var parts = entry.isCurrent ? String(localized: "This week") : String(localized: "Week of \(entry.label)")
            if let average = entry.average { parts += ": " + String(localized: "average Effort \(TrainingLoadWords.number(average))") }
            else { parts += ": " + String(localized: "no Effort recorded") }
            if let base = entry.base { parts += ", " + String(localized: "fitness base \(TrainingLoadWords.number(base))") }
            return parts
        }.joined(separator: ". ")
    }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                list
            } else {
                TrainingLoadWeeksChart(entries: entries)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Average daily Effort by week")
                    .accessibilityValue(Text(verbatim: spoken))
            }
        }
        .accessibilityIdentifier("trends.trainingLoad.weeks")
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { FlatRowSeparator() }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: entry.isCurrent ? String(localized: "This week") : entry.label)
                        .font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(verbatim: entry.average.map { String(localized: "Average Effort \(TrainingLoadWords.number($0))") }
                         ?? String(localized: "No Effort recorded"))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                    if let base = entry.base {
                        Text(verbatim: String(localized: "Fitness base \(TrainingLoadWords.number(base))"))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .padding(.vertical, NoopMetrics.space2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct TrainingLoadWeeksChart: View {
    let entries: [TrainingLoadWeeks.Entry]
    @ScaledMetric(relativeTo: .caption) private var valueSize: CGFloat = 12
    @ScaledMetric(relativeTo: .caption2) private var labelSize: CGFloat = 11

    private let height: CGFloat = 150
    private let top: CGFloat = 32
    private let bottom: CGFloat = 22

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let count = max(entries.count, 1)
            let barWidth = min(34, (width - CGFloat(count - 1) * 8) / CGFloat(count))
            let gap = count > 1 ? (width - CGFloat(count) * barWidth) / CGFloat(count - 1) : 0
            let ceiling = max(entries.compactMap(\.average).max() ?? 1, entries.compactMap(\.base).max() ?? 1, 1) * 1.04
            let x = { (index: Int) -> CGFloat in CGFloat(index) * (barWidth + gap) }
            let y = { (value: Double) -> CGFloat in top + (1 - CGFloat(value / ceiling)) * (height - top - bottom) }
            let baseline = height - bottom

            ZStack(alignment: .topLeading) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if let average = entry.average {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(entry.isCurrent ? TrainingLoadInk.recent : TrainingLoadInk.recent.opacity(0.42))
                            .frame(width: barWidth, height: max(baseline - y(average), 2))
                            .offset(x: x(index), y: y(average))
                        Text(verbatim: TrainingLoadWords.number(average))
                            .font(.system(size: min(valueSize, 20), weight: .semibold))
                            .foregroundStyle(entry.isCurrent ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                            .fixedSize()
                            .frame(width: barWidth + gap, alignment: .center)
                            .offset(x: x(index) - gap / 2, y: y(average) - valueSize - 6)
                    }
                    label(entry, index: index, last: index == entries.count - 1, barWidth: barWidth, gap: gap, width: width)
                        .offset(y: baseline + 5)
                }
                baseLine(x: x, y: y, barWidth: barWidth)
                key.offset(x: 0, y: 0)
            }
        }
        .frame(height: height)
    }

    /// A week's label is centred under its bar. The current week's is right-aligned to the chart's trailing edge, so it
    /// is never clipped and never depends on how wide the text happens to be.
    @ViewBuilder
    private func label(_ entry: TrainingLoadWeeks.Entry, index: Int, last: Bool, barWidth: CGFloat, gap: CGFloat,
                       width: CGFloat) -> some View {
        let cell = barWidth + gap
        let text = Text(entry.isCurrent ? String(localized: "This wk") : entry.label)
            .font(.system(size: min(labelSize, 18), weight: entry.isCurrent ? .semibold : .regular))
            .foregroundStyle(entry.isCurrent ? StrandPalette.textPrimary : StrandPalette.textTertiary)
            .lineLimit(1)
            .fixedSize()
        if entry.isCurrent && last {
            let wide = cell + 16
            text.frame(width: wide, alignment: .trailing)
                .offset(x: width - wide)
        } else {
            text.frame(width: cell, alignment: .center)
                .offset(x: CGFloat(index) * cell - gap / 2)
        }
    }

    private func baseLine(x: (Int) -> CGFloat, y: (Double) -> CGFloat, barWidth: CGFloat) -> some View {
        let points: [(Int, CGPoint)] = entries.enumerated().compactMap { index, entry in
            entry.base.map { (index, CGPoint(x: x(index) + barWidth / 2, y: y($0))) }
        }
        return ZStack {
            if points.count >= 2 {
                Path { path in
                    path.move(to: points[0].1)
                    for point in points.dropFirst() { path.addLine(to: point.1) }
                }
                .stroke(StrandPalette.textSecondary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [4, 4]))
            }
            ForEach(points, id: \.0) { _, point in
                Circle()
                    .fill(StrandPalette.canvas)
                    .overlay(Circle().stroke(StrandPalette.textSecondary, lineWidth: 1.6))
                    .frame(width: 6, height: 6)
                    .position(point)
            }
        }
    }

    /// "- - fitness base", top trailing.
    private var key: some View {
        HStack(spacing: 5) {
            Spacer(minLength: 0)
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1))
                path.addLine(to: CGPoint(x: 14, y: 1))
            }
            .stroke(StrandPalette.textSecondary, style: StrokeStyle(lineWidth: 1.4, dash: [3, 3]))
            .frame(width: 14, height: 2)
            Text("Fitness base")
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

// MARK: - Drivers

/// The week's hardest workouts, each with a day badge, the sport, what it was, a bar against the 0...21 scale and its Effort.
struct TrainingLoadDrivers: View {
    struct Row: Identifiable {
        let id: Int
        let weekday: String
        let dayNumber: String
        let title: String
        let symbol: String
        let meta: String
        let fraction: Double
        let effort: Double
    }

    let rows: [Row]
    let trainingDaysText: String
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var badgeWidth: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var dayNumberSize: CGFloat = 17
    @ScaledMetric(relativeTo: .body) private var effortSize: CGFloat = 18
    @ScaledMetric(relativeTo: .caption2) private var weekdaySize: CGFloat = 11

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { FlatRowSeparator() }
                rowView(row)
            }
            Text(verbatim: trainingDaysText)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
    }

    private func rowView(_ row: Row) -> some View {
        let spoken = String(localized: "\(row.weekday) \(row.dayNumber), \(row.title), \(row.meta), Effort \(TrainingLoadWords.number(row.effort))")
        return Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: NoopMetrics.space2) {
                        dayBadge(row)
                        effortBlock(row, alignment: .leading)
                    }
                    detail(row)
                }
            } else {
                HStack(alignment: .center, spacing: NoopMetrics.space3) {
                    dayBadge(row)
                    detail(row)
                    effortBlock(row, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
    }

    private func dayBadge(_ row: Row) -> some View {
        VStack(spacing: 0) {
            Text(verbatim: row.weekday.uppercased())
                .font(.system(size: min(weekdaySize, 22), weight: .bold))
                .tracking(1)
                .foregroundStyle(StrandPalette.textTertiary)
            Text(verbatim: row.dayNumber)
                .font(.system(size: min(dayNumberSize, 28), weight: .semibold).monospacedDigit())
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(width: min(badgeWidth, 64))
    }

    private func detail(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: row.title)
                .font(Font.system(.body, design: .default).weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Image(systemName: row.symbol)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .accessibilityHidden(true)
                Text(verbatim: row.meta)
                    .font(StrandFont.caption.weight(.regular))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous).fill(StrandPalette.hairlineStrong)
                    Capsule(style: .continuous).fill(TrainingLoadInk.recent)
                        .frame(width: max(proxy.size.width * CGFloat(row.fraction), 3))
                }
            }
            .frame(height: 4)
            .padding(.top, 5)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func effortBlock(_ row: Row, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(verbatim: TrainingLoadWords.number(row.effort))
                .font(.system(size: min(effortSize, 30), weight: .semibold).monospacedDigit())
                .foregroundStyle(TrainingLoadInk.recent)
            Text("Effort")
                .font(StrandFont.micro.weight(.regular))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .fixedSize()
    }
}

// MARK: - Sport mix

/// The share of summed workout strain by sport: a segmented bar and a two-column legend.
struct TrainingLoadMix: View {
    struct Slice: Identifiable {
        let id: Int
        let name: String
        let fraction: Double
        let percent: Int
        let color: Color
    }

    let slices: [Slice]
    @Environment(\.dynamicTypeSize) private var typeSize

    static let colors: [Color] = [
        TrainingLoadInk.recent,
        StrandPalette.recoveryData,
        StrandPalette.metricPurple,
        StrandPalette.textTertiary.opacity(0.7),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GeometryReader { proxy in
                let usable = max(proxy.size.width - CGFloat(max(slices.count - 1, 0)) * 3, 1)
                HStack(spacing: 3) {
                    ForEach(slices) { slice in
                        Capsule(style: .continuous).fill(slice.color)
                            .frame(width: max(usable * CGFloat(slice.fraction), 3))
                    }
                }
            }
            .frame(height: 12)
            .accessibilityHidden(true)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(slices) { slice in
                    HStack(spacing: 8) {
                        Circle().fill(slice.color).frame(width: 9, height: 9).accessibilityHidden(true)
                        Text(verbatim: slice.name)
                            .font(Font.system(.subheadline, design: .default).weight(.regular))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        Text(verbatim: "\(slice.percent)%")
                            .font(Font.system(.subheadline, design: .default).weight(.semibold).monospacedDigit())
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: String(localized: "\(slice.name), \(slice.percent) percent")))
                }
            }
        }
        .accessibilityIdentifier("trends.trainingLoad.mix")
    }

    private var columns: [GridItem] {
        typeSize.isAccessibilitySize
            ? [GridItem(.flexible(), alignment: .leading)]
            : [GridItem(.flexible(), spacing: 16, alignment: .leading), GridItem(.flexible(), alignment: .leading)]
    }
}

// MARK: - Comparison

/// The last four weeks against the four before: average daily Effort, training days and the biggest day.
struct TrainingLoadComparisonStrip: View {
    struct Cell: Identifiable {
        let id: Int
        let label: String
        let value: String
        /// A change arrow with its text, or plain text, under the value.
        let delta: Delta?
        let spoken: String
    }

    enum Delta {
        case change(up: Bool, text: String)
        case plain(String)
    }

    let cells: [Cell]
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title3) private var valueSize: CGFloat = 19

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                        if index > 0 { FlatRowSeparator() }
                        column(cell)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                        if index > 0 {
                            Rectangle().fill(StrandPalette.hairline).frame(width: 1, height: 56)
                                .accessibilityHidden(true)
                        }
                        column(cell)
                            .padding(.leading, index == 0 ? 0 : NoopMetrics.space3)
                            .padding(.trailing, index == cells.count - 1 ? 0 : NoopMetrics.space2)
                    }
                }
            }
        }
        .accessibilityIdentifier("trends.trainingLoad.compare")
    }

    private func column(_ cell: Cell) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: cell.label)
                .font(StrandFont.caption.weight(.regular))
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Text(verbatim: cell.value)
                .font(.system(size: min(valueSize, 34), weight: .semibold).monospacedDigit())
                .foregroundStyle(cell.value == WidgetMetrics.missingValue ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            switch cell.delta {
            case .change(let up, let text)?:
                HStack(spacing: 3) {
                    Image(systemName: up ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                        .font(.system(size: 8))
                        .accessibilityHidden(true)
                    Text(verbatim: text)
                }
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(up ? TrainingLoadInk.baseText : StrandPalette.textSecondary)
            case .plain(let text)?:
                Text(verbatim: text)
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
            case nil:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: cell.spoken))
    }
}

// MARK: - Method

/// "How this is calculated", in plain words and checked against `TrainingLoadEngine`: both lines are exponentially
/// weighted averages of daily Effort whose weights fade over about a week and about six weeks (time constants, not
/// half-lives), seeded by the mean of the first recorded days; Form is base minus recent; a missing day counts as rest for a
/// short run and a longer gap starts the history over.
struct TrainingLoadMethod: View {
    let configuration: TrainingLoadEngine.Configuration
    let timeZoneIdentifier: String

    var body: some View {
        let maxGap = configuration.maxGapDays
        let prime = configuration.primeDays
        let minimum = configuration.minimumDays
        let established = configuration.establishedDays
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("Every day's **Effort** (the 0–21 score on Today) feeds two running averages. Recent days count more than older ones.")
            formula("Recent load", "= weighted average, about 1 week")
            formula("Fitness base", "= weighted average, about 6 weeks")
            HStack(spacing: 8) {
                Text("Form").font(StrandFont.footnote.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                Text(verbatim: "=").foregroundStyle(StrandPalette.textTertiary)
                Text("base").font(StrandFont.footnote.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                Text(verbatim: "−").foregroundStyle(StrandPalette.textTertiary)
                Text("recent").font(StrandFont.footnote.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(TrainingLoadInk.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(StrandPalette.hairline, lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Form equals base minus recent")
            Text("When recent load sits **0.8–1.3×** your base, you're building steadily. Well above that is a spike. Well below means you're easing off.")
            Text("A day with no Effort recorded counts as a rest day for up to \(maxGap) days in a row. Longer gaps restart the history.")
            Text("The first \(prime) recorded days are averaged to start both lines. Load appears after \(minimum) recorded days and is marked Established at \(established).")
            Text("Dates use the Trends source time zone: \(timeZoneIdentifier)")
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textSecondary)
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func formula(_ name: LocalizedStringKey, _ rest: LocalizedStringKey) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text(name).font(StrandFont.footnote.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                Text(rest).foregroundStyle(StrandPalette.textTertiary)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(StrandFont.footnote.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                Text(rest).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(TrainingLoadInk.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(StrandPalette.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}
