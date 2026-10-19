import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Workouts building blocks
//
// The pieces the Workouts hub, its history and the day view share, in the widget design language: the header row, a
// sport mark in the Strain colour, one workout row (two lines, a Strain value, the heart-rate zone bar), the hairline
// between rows, the week's bars and stat strip, and the sport filter chips. They take plain values and never see the
// repository.

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

/// Which layout a row wears. From the largest standard text size up, the row stacks (mark, title, facts, numbers),
/// because side by side it would cut its facts or break its title.
enum WorkoutRowLayout {
    static func stacks(_ size: DynamicTypeSize) -> Bool { size >= .xxxLarge }
}

// MARK: Sport mark

/// A sport's symbol in the Strain colour, with no disc behind it: the leading mark of a row. It sits in a column that
/// grows with the text size up to a ceiling, so a very large text size never gives the mark more room than the words
/// beside it.
struct WorkoutSportMark: View {
    let symbol: String
    @ScaledMetric(relativeTo: .body) private var scaledSize: CGFloat = 26
    @ScaledMetric(relativeTo: .body) private var scaledColumn: CGFloat = 34

    /// The column's width for a scaled 34pt: it grows with the text and stops at 48pt.
    static func column(scaled: CGFloat) -> CGFloat { min(scaled, 48) }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: min(scaledSize, 34), weight: .regular))
            .foregroundStyle(DomainTint.strain.accent)
            .frame(width: Self.column(scaled: scaledColumn), alignment: .leading)
            .accessibilityHidden(true)
    }
}

// MARK: Strain value

/// A workout's Strain as a small flame and its number. NOOP's own score wears the Strain colour; a WHOOP number stays
/// neutral (the row's source names it), so it is never read as a NOOP score.
struct WorkoutStrainValue: View {
    let badge: WorkoutStrainBadge
    @ScaledMetric(relativeTo: .footnote) private var valueSize: CGFloat = 13.5

    private var tint: Color { badge.isWhoop ? StrandPalette.textSecondary : DomainTint.strain.accent }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "flame.fill")
                .font(.system(size: valueSize * 0.8, weight: .semibold))
                .accessibilityHidden(true)
            Text(verbatim: badge.text)
                .font(StrandFont.number(valueSize, weight: .bold))
        }
        .foregroundStyle(tint)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge.isWhoop
            ? String(localized: "WHOOP strain \(badge.text)")
            : String(localized: "Strain \(badge.text)"))
    }
}

// MARK: Zone bar

/// How a session's time divided between the heart-rate zones, as one 4pt bar of six segments: below zone 1, then the
/// five zones in their own colours. Decoration for the row that already says everything in words, so it is hidden from
/// VoiceOver.
struct WorkoutZoneBar: View {
    let zones: WorkoutZoneShares

    private func color(for zone: Int) -> Color {
        zone == 0 ? StrandPalette.textTertiary.opacity(0.5) : StrandPalette.hrZoneColor(zone)
    }

    var body: some View {
        GeometryReader { proxy in
            let segments = zones.segments
            let gap: CGFloat = 2
            let total = segments.reduce(0) { $0 + $1.share }
            let usable = max(0, proxy.size.width - gap * CGFloat(max(0, segments.count - 1)))
            HStack(spacing: gap) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Capsule(style: .continuous)
                        .fill(color(for: segment.zone))
                        .frame(width: total > 0 ? usable * segment.share / total : 0)
                }
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

// MARK: Row

/// One workout in two lines. The sport mark leads; the first line is the sport with the lead metric (how far, else how
/// long, else how much energy) right-aligned; the second is when, how long and where it came from, with the Strain
/// value right-aligned; a 4pt zone bar closes it when the session carries a zone split. The row is one spoken element.
/// At large text sizes it stacks, so nothing is cut short.
struct WorkoutRowContent: View {
    let presentation: WorkoutRowPresentation
    var showsChevron = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var leadSize: CGFloat = 17
    @ScaledMetric(relativeTo: .body) private var scaledColumn: CGFloat = 34

    var body: some View {
        Group {
            if WorkoutRowLayout.stacks(typeSize) { stacked } else { inline }
        }
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private var inline: some View {
        HStack(alignment: .top, spacing: NoopMetrics.space3) {
            WorkoutSportMark(symbol: presentation.symbol)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    title
                    Spacer(minLength: NoopMetrics.space2)
                    lead
                    if showsChevron { chevron }
                }
                detailLines
                if let zones = presentation.zones { WorkoutZoneBar(zones: zones).padding(.top, 10) }
            }
        }
    }

    /// The mark on a line of its own, then the title, the facts and the numbers, each with the full width.
    private var stacked: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack {
                WorkoutSportMark(symbol: presentation.symbol)
                Spacer(minLength: 0)
                if showsChevron { chevron }
            }
            title
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(presentation.lines.enumerated()), id: \.offset) { _, facts in
                    Text(verbatim: WorkoutFormat.joined(facts)).font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: NoopMetrics.space3) {
                lead
                if let strain = presentation.strain { WorkoutStrainValue(badge: strain) }
            }
            if let zones = presentation.zones { WorkoutZoneBar(zones: zones).padding(.top, 2) }
        }
    }

    private var title: some View {
        Text(verbatim: presentation.title)
            .font(StrandFont.sized(leadSize, weight: .semibold))
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var lead: some View {
        if let primary = presentation.primary {
            Text(verbatim: primary)
                .font(StrandFont.number(leadSize, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// The facts lines under the title; the first shares its line with the Strain value.
    @ViewBuilder private var detailLines: some View {
        if presentation.lines.isEmpty {
            if let strain = presentation.strain {
                HStack { Spacer(minLength: 0); WorkoutStrainValue(badge: strain) }
            }
        } else {
            ForEach(Array(presentation.lines.enumerated()), id: \.offset) { index, facts in
                if index == 0 {
                    HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                        WorkoutFactLine(facts: facts).layoutPriority(1)
                        Spacer(minLength: NoopMetrics.space2)
                        if let strain = presentation.strain { WorkoutStrainValue(badge: strain) }
                    }
                } else {
                    WorkoutFactLine(facts: facts)
                }
            }
        }
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
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 13.5

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
            .font(StrandFont.sized(size))
            .foregroundStyle(StrandPalette.textSecondary)
            .lineLimit(wrapping ? 2 : 1)
            .fixedSize(horizontal: !wrapping, vertical: true)
    }
}

/// The hairline between two rows, starting under the row's text: after the mark when the row is side by side, at the
/// edge when it is stacked. `leadingExtra` is whatever the list puts before the row (the selection column).
struct WorkoutRowSeparator: View {
    var leadingExtra: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var scaledColumn: CGFloat = 34

    private var inset: CGFloat {
        let mark = WorkoutRowLayout.stacks(typeSize) ? 0 : WorkoutSportMark.column(scaled: scaledColumn) + NoopMetrics.space3
        return mark + leadingExtra
    }

    var body: some View {
        Rectangle()
            .fill(StrandPalette.hairline)
            .frame(height: 1)
            .padding(.leading, inset)
            .accessibilityHidden(true)
    }
}

// MARK: Day header

/// A day of the history feed: the day in the one format rows and sections use, and how many sessions it holds. One
/// spoken heading.
struct WorkoutDayHeader: View {
    let title: String
    let sessions: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
            Text(verbatim: title)
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: NoopMetrics.space2)
            Text("\(sessions) sessions")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.top, 18)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: Header row

/// The Workouts header: a round back (or close) button on a raised surface, the tracked caps title, the date in the
/// secondary ink, and the one primary action on the trailing edge. At large text sizes the date drops out first, and
/// then the action keeps only its glyph, so the title is never squeezed.
struct WorkoutsHeaderRow<Action: View>: View {
    let title: LocalizedStringKey
    let date: String
    let leadingSymbol: String
    let leadingLabel: LocalizedStringKey
    let onLeading: () -> Void
    @ViewBuilder let action: (_ compact: Bool) -> Action
    @ScaledMetric(relativeTo: .caption) private var titleSize: CGFloat = 13
    @ScaledMetric(relativeTo: .subheadline) private var dateSize: CGFloat = 14

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(showsDate: true, compact: false)
            row(showsDate: false, compact: false)
            row(showsDate: false, compact: true)
        }
        .padding(.leading, 14)
        .padding(.trailing, NoopMetrics.space4)
        .frame(minHeight: 56)
    }

    private func row(showsDate: Bool, compact: Bool) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            Button(action: onLeading) {
                Image(systemName: leadingSymbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(StrandPalette.surfaceRaised))
                    .contentShape(Rectangle().inset(by: -3))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(leadingLabel)
            Text(title)
                .font(StrandFont.sized(titleSize, weight: .bold))
                .tracking(2.4)
                .textCase(.uppercase)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            if showsDate {
                Text(verbatim: date)
                    .font(StrandFont.sized(dateSize))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            action(compact)
        }
    }
}

/// The header's one primary action: a solid brand-ink capsule with a dark label, 34pt tall. Compact it is only the
/// glyph, in a 38pt circle.
struct WorkoutStartPillStyle: ButtonStyle {
    let compact: Bool
    @ScaledMetric(relativeTo: .subheadline) private var textSize: CGFloat = 15

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: textSize, weight: .bold))
            .foregroundStyle(StrandPalette.onInk)
            .padding(.leading, compact ? 0 : 12)
            .padding(.trailing, compact ? 0 : 14)
            .frame(width: compact ? 38 : nil, height: compact ? 38 : 34)
            .background(Capsule(style: .continuous).fill(StrandPalette.ink))
            // The capsule is 34pt tall; the tap area still reaches 44pt.
            .contentShape(Rectangle().inset(by: -5))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

// MARK: Sport filter chip

/// One choice of the sport filter row: selected it is a solid capsule in the primary ink with dark text; otherwise a
/// hairline capsule with a secondary label and the sport's glyph. The tap area reaches 44pt without growing the row.
struct WorkoutSportFilterChip: View {
    let title: String
    /// The sport's symbol, or nil for the "All" chip.
    var symbol: String?
    let isSelected: Bool
    let action: () -> Void
    @ScaledMetric(relativeTo: .subheadline) private var textSize: CGFloat = 14

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: textSize + 1, weight: .medium))
                        .accessibilityHidden(true)
                }
                Text(verbatim: title)
                    .font(StrandFont.sized(textSize, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(isSelected ? StrandPalette.appCanvas : StrandPalette.textSecondary)
            .padding(.horizontal, 13)
            .frame(minHeight: 34)
            .background(Capsule(style: .continuous).fill(isSelected ? StrandPalette.textPrimary : Color.clear))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(isSelected ? Color.clear : StrandPalette.hairlineStrong, lineWidth: 1))
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: Week bars

/// A week at a glance: one column per day, a Strain-blue bar as tall as the day's active time, the busiest day's time
/// above its bar, today's label in the primary ink, a small dot where nothing happened. Each column is spoken as its
/// day and its time.
struct WorkoutWeekBars: View {
    let days: [WorkoutWeekSummary.Day]
    var calendar: Calendar = .current
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.redactionReasons) private var redaction
    @ScaledMetric(relativeTo: .caption) private var fullHeight: CGFloat = 80
    @ScaledMetric(relativeTo: .caption) private var quietHeight: CGFloat = 18
    @ScaledMetric(relativeTo: .caption) private var labelRoom: CGFloat = 18

    private static let barWidth: CGFloat = 26
    private static let columnWidth: CGFloat = 38

    /// The tallest bar stands for the busiest day, but never for less than an hour, so a short walk does not fill
    /// the chart.
    private var scaleSeconds: Double {
        max(3_600, days.map(\.activeSeconds).max() ?? 0)
    }

    /// The day whose time is written above its bar: the busiest one, the earliest of any tie.
    private var peakID: Date? {
        let peak = days.filter(\.hasWorkouts).max { $0.activeSeconds < $1.activeSeconds }
        guard let peak else { return nil }
        return days.first(where: { $0.hasWorkouts && $0.activeSeconds == peak.activeSeconds })?.id
    }

    /// A week with nothing in it has no bars to give room to, only its days and their dots.
    private var chartHeight: CGFloat {
        days.contains(where: \.hasWorkouts) ? fullHeight + labelRoom : quietHeight
    }

    /// Placeholder bars are the neutral wash, not the workout colour.
    private var isPlaceholder: Bool { redaction.contains(.placeholder) }

    var body: some View {
        let peak = peakID
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                if index > 0 { Spacer(minLength: 0) }
                column(day, isPeak: day.id == peak)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func column(_ day: WorkoutWeekSummary.Day, isPeak: Bool) -> some View {
        VStack(spacing: NoopMetrics.space2) {
            ZStack(alignment: .bottom) {
                Color.clear.frame(height: chartHeight)
                if day.hasWorkouts {
                    VStack(spacing: 4) {
                        if isPeak {
                            Text(verbatim: WorkoutFormat.duration(day.activeSeconds))
                                .font(StrandFont.sized(12, weight: .medium))
                                .foregroundStyle(StrandPalette.textSecondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        bar(height: max(8, fullHeight * CGFloat(min(1, day.activeSeconds / scaleSeconds))))
                    }
                } else {
                    Circle()
                        .fill(day.isFuture ? StrandPalette.hairline : StrandPalette.textTertiary.opacity(0.55))
                        .frame(width: 5, height: 5)
                        .padding(.bottom, 4)
                }
            }
            Text(verbatim: label(for: day))
                .font(StrandFont.sized(12, weight: .medium))
                .foregroundStyle(day.isToday ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(minWidth: Self.columnWidth)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spokenDay(day)))
        .accessibilityValue(Text(verbatim: spokenValue(day)))
    }

    /// The bar: the Strain colour, a little lighter at the top and deeper at the foot.
    private func bar(height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return shape
            .fill(isPlaceholder ? StrandPalette.chipFill : DomainTint.strain.accent)
            .overlay {
                if !isPlaceholder {
                    LinearGradient(colors: [Color.white.opacity(0.24), .clear, Color.black.opacity(0.14)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .clipShape(shape)
            .frame(width: Self.barWidth, height: height)
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

// MARK: Week strip

/// Three facts under a hairline, label over value, a hairline between the columns: the week's sessions, average Strain
/// (in the Strain colour) and calories. At accessibility sizes the facts stack as label and value rows.
struct WorkoutWeekStrip: View {
    struct Fact {
        let label: LocalizedStringKey
        let value: String
        /// The value's colour; nil is the primary ink.
        var tint: Color?
        /// What VoiceOver reads for the value when the text on screen would be misread.
        var spokenValue: String?
    }

    let facts: [Fact]
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var valueSize: CGFloat = 17
    @ScaledMetric(relativeTo: .caption) private var labelSize: CGFloat = 12

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize { stacked } else { columns }
        }
        .padding(.top, 11)
        .overlay(alignment: .top) { Rectangle().fill(StrandPalette.hairline).frame(height: 1) }
    }

    private func value(_ fact: Fact) -> some View {
        Text(verbatim: fact.value)
            .font(StrandFont.number(valueSize, weight: .semibold))
            .foregroundStyle(fact.value == WidgetMetrics.missingValue ? StrandPalette.textTertiary
                             : fact.tint ?? StrandPalette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func label(_ fact: Fact) -> some View {
        Text(fact.label)
            .font(StrandFont.sized(labelSize))
            .foregroundStyle(StrandPalette.textTertiary)
            .lineLimit(1)
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                VStack(alignment: .leading, spacing: 2) {
                    label(fact)
                    value(fact)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, index == 0 ? 0 : NoopMetrics.space3)
                .overlay(alignment: .leading) {
                    if index > 0 { Rectangle().fill(StrandPalette.hairline).frame(width: 1) }
                }
                .modifier(SpokenFact(fact: fact))
            }
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    label(fact)
                    Spacer(minLength: NoopMetrics.space2)
                    value(fact)
                }
                .modifier(SpokenFact(fact: fact))
            }
        }
    }

    private struct SpokenFact: ViewModifier {
        let fact: Fact
        @ViewBuilder func body(content: Content) -> some View {
            if let spoken = fact.spokenValue {
                content.accessibilityElement(children: .ignore)
                    .accessibilityLabel(fact.label)
                    .accessibilityValue(Text(verbatim: spoken))
            } else {
                content.accessibilityElement(children: .combine)
            }
        }
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
