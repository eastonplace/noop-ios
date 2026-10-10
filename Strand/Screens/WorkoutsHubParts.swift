import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Workouts building blocks
//
// The pieces the Workouts hub, its history and the day view share, in the widget design language: a sport glyph
// on a quiet tinted disc, a Strain chip that says whose number it is, one workout row, the hairline between rows
// and the week's bars. They take plain values and never see the repository.

// MARK: Sport glyph

/// A sport's symbol on a quiet disc in the workout tint. The disc follows the text size up to a ceiling, so a very
/// large text size never gives the glyph more room than the words beside it.
struct WorkoutSportGlyph: View {
    let symbol: String
    @ScaledMetric(relativeTo: .body) private var scaledDiameter: CGFloat = 38

    /// The disc's diameter for a scaled 38pt: it grows with the text and stops at 48pt.
    static func diameter(scaled: CGFloat) -> CGFloat { min(scaled, 48) }

    private var diameter: CGFloat { Self.diameter(scaled: scaledDiameter) }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: diameter * 0.42, weight: .semibold))
            .foregroundStyle(DomainTint.workout.accent)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(DomainTint.workout.accent.opacity(0.14)))
            .accessibilityHidden(true)
    }
}

/// Which layout a row wears. From the largest standard text size up, the row stacks (glyph, title, facts, numbers),
/// because side by side it would cut its facts or break its title.
enum WorkoutRowLayout {
    static func stacks(_ size: DynamicTypeSize) -> Bool { size >= .xxxLarge }
}

// MARK: Strain chip

/// A workout's Strain on a capsule, in the state pill's chrome. NOOP's own score wears the Strain tint; a WHOOP
/// number is named and stays neutral, so it is never read as a NOOP score.
struct WorkoutStrainChip: View {
    let badge: WorkoutStrainBadge
    @ScaledMetric(relativeTo: .caption) private var valueSize: CGFloat = 13

    private var tint: Color { badge.isWhoop ? StrandPalette.textSecondary : DomainTint.strain.accent }

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: badge.text)
                .font(StrandFont.number(valueSize, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
            if badge.isWhoop {
                Text("WHOOP")
                    .font(StrandFont.micro.weight(.semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .lineLimit(1)
        .statePillChrome(tint: tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge.isWhoop
            ? String(localized: "WHOOP strain \(badge.text)")
            : String(localized: "Strain \(badge.text)"))
    }
}

// MARK: Row

/// One workout: its glyph, the sport over a quiet second line, and the lead metric over the Strain chip. The row
/// is one spoken element. At accessibility text sizes it stacks, so nothing is cut short.
struct WorkoutRowContent: View {
    let presentation: WorkoutRowPresentation
    /// A heart-rate trace to sketch between the text and the numbers, when the row has one.
    var heartRate: [Double] = []
    var showsChevron = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var leadSize: CGFloat = 17

    var body: some View {
        Group {
            if WorkoutRowLayout.stacks(typeSize) { stacked } else { inline }
        }
        .padding(.vertical, NoopMetrics.space3)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private var inline: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
            WorkoutSportGlyph(symbol: presentation.symbol)
            texts.layoutPriority(1)
            Spacer(minLength: NoopMetrics.space2)
            if heartRate.count > 1 { trace }
            numbers
            if showsChevron { chevron }
        }
    }

    /// The glyph on a line of its own, then the title, the facts and the numbers, each with the full width.
    private var stacked: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack {
                WorkoutSportGlyph(symbol: presentation.symbol)
                Spacer(minLength: 0)
                if showsChevron { chevron }
            }
            Text(verbatim: presentation.title).font(StrandFont.body.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(presentation.lines.enumerated()), id: \.offset) { _, facts in
                    Text(verbatim: WorkoutFormat.joined(facts)).font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: NoopMetrics.space3) {
                if let primary = presentation.primary {
                    Text(verbatim: primary).font(StrandFont.number(leadSize)).foregroundStyle(StrandPalette.textPrimary)
                }
                if let strain = presentation.strain { WorkoutStrainChip(badge: strain) }
            }
        }
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: presentation.title)
                .font(StrandFont.body.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(presentation.lines.enumerated()), id: \.offset) { _, facts in
                WorkoutFactLine(facts: facts)
            }
        }
    }

    private var trace: some View {
        Sparkline(values: heartRate, gradient: Gradient(colors: [StrandPalette.metricRose.opacity(0.55), StrandPalette.metricRose]),
                  lineWidth: 1.4, showsArea: false, showsHead: false, showsHover: false)
            .frame(width: 52, height: 24)
            .accessibilityHidden(true)
    }

    private var numbers: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let primary = presentation.primary {
                Text(verbatim: primary)
                    .font(StrandFont.number(leadSize))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
            }
            if let strain = presentation.strain { WorkoutStrainChip(badge: strain) }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(StrandPalette.textTertiary)
            .accessibilityHidden(true)
    }
}

/// One line of a row's text under its title: as many of its facts as fit on one line, the rest dropped from the end.
/// When not even the first fact fits, it wraps rather than being cut.
struct WorkoutFactLine: View {
    let facts: [String]

    var body: some View {
        if facts.count <= 1 {
            line(facts, wrapping: true)
        } else {
            ViewThatFits(in: .horizontal) {
                ForEach(Array((1...facts.count).reversed()), id: \.self) { count in
                    line(Array(facts.prefix(count)), wrapping: count == 1)
                }
            }
        }
    }

    private func line(_ shown: [String], wrapping: Bool) -> some View {
        Text(verbatim: WorkoutFormat.joined(shown))
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textSecondary)
            .lineLimit(wrapping ? 2 : 1)
            .fixedSize(horizontal: !wrapping, vertical: true)
    }
}

/// The hairline between two rows, starting under the row's text: after the glyph when the row is side by side, at
/// the edge when it is stacked. `leadingExtra` is whatever the list puts before the row (the selection column).
struct WorkoutRowSeparator: View {
    var leadingExtra: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var scaledGlyph: CGFloat = 38

    private var inset: CGFloat {
        let glyph = WorkoutRowLayout.stacks(typeSize) ? 0 : WorkoutSportGlyph.diameter(scaled: scaledGlyph) + NoopMetrics.space3
        return glyph + leadingExtra
    }

    var body: some View {
        Rectangle()
            .fill(StrandPalette.hairline)
            .frame(height: 1)
            .padding(.leading, inset)
            .accessibilityHidden(true)
    }
}

// MARK: Week bars

/// A week at a glance: one column per day, a bar as tall as the day's active time, today held on a quiet lane, a dot
/// where nothing happened. Each column is spoken as its day and its time.
struct WorkoutWeekBars: View {
    let days: [WorkoutWeekSummary.Day]
    var calendar: Calendar = .current
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.redactionReasons) private var redaction
    @ScaledMetric(relativeTo: .caption) private var fullHeight: CGFloat = 64
    @ScaledMetric(relativeTo: .caption) private var quietHeight: CGFloat = 18

    /// The tallest bar stands for the busiest day, but never for less than an hour, so a short walk does not fill
    /// the chart.
    private var scaleSeconds: Double {
        max(3_600, days.map(\.activeSeconds).max() ?? 0)
    }

    /// A week with nothing in it has no bars to give room to, only its days and their dots.
    private var chartHeight: CGFloat {
        days.contains(where: \.hasWorkouts) ? fullHeight : quietHeight
    }

    /// Placeholder bars are the neutral wash, not the workout colour.
    private var isPlaceholder: Bool { redaction.contains(.placeholder) }

    var body: some View {
        HStack(alignment: .bottom, spacing: NoopMetrics.space1) {
            ForEach(days) { day in column(day) }
        }
        .frame(maxWidth: .infinity)
    }

    private func column(_ day: WorkoutWeekSummary.Day) -> some View {
        VStack(spacing: NoopMetrics.space2) {
            ZStack(alignment: .bottom) {
                Color.clear.frame(height: chartHeight)
                if day.hasWorkouts {
                    UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 2,
                                           bottomTrailingRadius: 2, topTrailingRadius: 6, style: .continuous)
                        .fill(isPlaceholder ? StrandPalette.chipFill : DomainTint.workout.accent.opacity(day.isToday ? 1 : 0.7))
                        .frame(width: 20, height: max(6, chartHeight * CGFloat(day.activeSeconds / scaleSeconds)))
                } else {
                    Circle()
                        .fill(day.isFuture ? StrandPalette.hairline : StrandPalette.textTertiary.opacity(0.55))
                        .frame(width: 5, height: 5)
                        .padding(.bottom, 2)
                }
            }
            Text(verbatim: label(for: day))
                .font(StrandFont.micro.weight(day.isToday ? .semibold : .regular))
                .foregroundStyle(day.isToday ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, NoopMetrics.space2)
        .frame(maxWidth: .infinity)
        .background {
            if day.isToday {
                RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous)
                    .fill(StrandPalette.chipFill)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spokenDay(day)))
        .accessibilityValue(Text(verbatim: spokenValue(day)))
        .accessibilityAddTraits(day.isToday ? .isSelected : [])
    }

    /// What a day holds, in words: time when it has some, the count when the sessions carry no length, "Upcoming"
    /// for a day that has not come, else nothing happened.
    private func spokenValue(_ day: WorkoutWeekSummary.Day) -> String {
        if day.hasWorkouts { return WorkoutFormat.spokenDuration(day.activeSeconds) }
        if day.sessions > 0 { return String(localized: "\(day.sessions) sessions") }
        return day.isFuture ? String(localized: "Upcoming") : String(localized: "No workouts")
    }

    private func label(for day: WorkoutWeekSummary.Day) -> String {
        let weekday = calendar.component(.weekday, from: day.start) - 1
        let symbols = typeSize.isAccessibilitySize ? calendar.veryShortWeekdaySymbols : calendar.shortWeekdaySymbols
        return symbols.indices.contains(weekday) ? symbols[weekday] : ""
    }

    private func spokenDay(_ day: WorkoutWeekSummary.Day) -> String {
        let weekday = calendar.component(.weekday, from: day.start) - 1
        let name = calendar.weekdaySymbols.indices.contains(weekday) ? calendar.weekdaySymbols[weekday] : ""
        return day.isToday ? String(localized: "\(name), today") : name
    }
}

// MARK: Empty state

/// A calm note for a page or a day with nothing on it: a glyph on a quiet disc, a headline and one sentence.
struct WorkoutEmptyState: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    @ScaledMetric(relativeTo: .title) private var disc: CGFloat = 64

    var body: some View {
        VStack(spacing: NoopMetrics.space3) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(DomainTint.workout.accent)
                .frame(width: disc, height: disc)
                .background(Circle().fill(DomainTint.workout.accent.opacity(0.14)))
                .accessibilityHidden(true)
            VStack(spacing: NoopMetrics.space1) {
                Text(title)
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, NoopMetrics.space6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Page rhythm

extension FlatSectionSeparator {
    /// The hairline after a list of workout rows. A row pads its own bottom edge by `NoopMetrics.space3`, so the
    /// separator adds only a hair to reach the page's usual gap.
    static var afterRows: FlatSectionSeparator {
        FlatSectionSeparator(above: FlatSectionRhythm.airAbove - NoopMetrics.space3)
    }

    /// The hairline above a header that ends in a chip. The chip's capsule, not the caps title, is the row's top ink,
    /// so it takes a little more air to sit where a plain header's title does.
    static var beforeChipHeader: FlatSectionSeparator {
        FlatSectionSeparator(below: FlatSectionRhythm.airBelow + 1.5)
    }

    /// The hairline before a list of workout rows, whose first row pads its own top edge.
    static var beforeRows: FlatSectionSeparator {
        FlatSectionSeparator(below: FlatSectionRhythm.airBelow - NoopMetrics.space3)
    }
}
