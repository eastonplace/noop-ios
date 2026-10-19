import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Workouts history pieces
//
// The day groups of the history feed, the "This week" section above it (the seven days' active time as the hero and
// as bars, then the week's sessions, Strain and calories), the disclosure row the hub uses, and the hub's loading
// skeleton. The grouping and the week arithmetic are `WorkoutTimelinePolicy`'s (Foundation-only and unit-tested); these
// only map rows in and draw.

extension WorkoutTimelineItem {
    /// A row as the timeline policy reads it: its list identity, its start and its known length (nil when it has none,
    /// so a missing duration is never counted as zero minutes).
    init(row: WorkoutRow) {
        self.init(id: row.listID, start: Date(timeIntervalSince1970: TimeInterval(row.startTs)),
                  seconds: WorkoutFacts.activeSeconds(row))
    }
}

/// One local start day of the history feed and its sessions, newest first.
struct WorkoutHistoryDay: Identifiable {
    let day: Date
    let rows: [WorkoutRow]
    var id: Date { day }

    /// The feed's groups, exactly as `WorkoutTimelinePolicy.groups` orders them (newest day first, newest session first
    /// within a day, each list identity once), mapped back to the rows.
    static func grouped(_ rows: [WorkoutRow], calendar: Calendar = .current) -> [Self] {
        var byID: [String: WorkoutRow] = [:]
        for row in rows where byID[row.listID] == nil { byID[row.listID] = row }
        return WorkoutTimelinePolicy.groups(items: rows.map(WorkoutTimelineItem.init(row:)), calendar: calendar)
            .map { group in Self(day: group.day, rows: group.ids.compactMap { byID[$0] }) }
    }
}

// MARK: Disclosure row

/// A row that shows or hides what follows it: a subhead-semibold title and a tertiary chevron that turns down when
/// open. The whole row is the 44pt tap target; the change animates unless Reduce Motion is on.
struct WorkoutsDisclosureRow: View {
    let title: LocalizedStringKey
    @Binding var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(NoopMotion.gated(StrandMotion.interactive, reduced: reduceMotion)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: NoopMetrics.space2) {
                Text(title)
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
    }
}

// MARK: This week

/// The seven days ending on `anchor`, from the rows the feed below shows: the week's known active time as the hero, a
/// bar for a day's known recorded minutes (the busiest labelled, today's day in the primary ink), a dot for a day with
/// no known minutes, then the week's sessions, average Strain and calories. A day whose sessions carry no duration is a
/// dot (and spoken as its session count), never a zero bar; an empty day is not called a rest day.
struct WorkoutHistoryChart: View {
    private let days: [WorkoutTimelineDay]
    private let interval: DateInterval?
    private let today: Date
    private let stats: WorkoutWeekStats
    @Binding private var showsDailyTotals: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 42

    /// `showsDailyTotals` opens the day-by-day list under the bars; the hub's menu owns it.
    init(rows: [WorkoutRow], anchor: Date, showsDailyTotals: Binding<Bool>, now: Date = Date(),
         calendar: Calendar = .current) {
        let interval = WorkoutTimelinePolicy.weekInterval(through: anchor, calendar: calendar)
        // Only the seven days are handed to the policy, so a long history is not sorted on every pass.
        let inWeek: [WorkoutRow] = interval.map { week in
            let lo = Int(week.start.timeIntervalSince1970), hi = Int(week.end.timeIntervalSince1970)
            return rows.filter { $0.startTs >= lo && $0.startTs < hi }
        } ?? []
        self.init(days: WorkoutTimelinePolicy.week(items: inWeek.map(WorkoutTimelineItem.init(row:)),
                                                   through: anchor, calendar: calendar),
                  interval: interval, today: calendar.startOfDay(for: now),
                  stats: WorkoutWeekStats.make(rows: inWeek), showsDailyTotals: showsDailyTotals)
    }

    private init(days: [WorkoutTimelineDay], interval: DateInterval?, today: Date, stats: WorkoutWeekStats,
                 showsDailyTotals: Binding<Bool>) {
        self.days = days
        self.interval = interval
        self.today = today
        self.stats = stats
        self._showsDailyTotals = showsDailyTotals
    }

    /// A plausible week for the loading skeleton: the section's real shape before any row is read. Drawn redacted and
    /// never read aloud.
    static func placeholder(now: Date = Date(), calendar: Calendar = .current) -> WorkoutHistoryChart {
        let sample: [Double] = [45, 60, 0, 90, 30, 50, 40]
        let week = WorkoutTimelinePolicy.week(items: [], through: now, calendar: calendar)
        let days = week.enumerated().map { index, day in
            WorkoutTimelineDay(day: day.day, minutes: sample[index % sample.count],
                               sessions: sample[index % sample.count] > 0 ? 1 : 0, missingDurations: 0)
        }
        return WorkoutHistoryChart(days: days, interval: WorkoutTimelinePolicy.weekInterval(through: now, calendar: calendar),
                                   today: calendar.startOfDay(for: now),
                                   stats: WorkoutWeekStats(sessions: 5, energyKcal: 1_900, averageStrainStored: 55),
                                   showsDailyTotals: .constant(false))
    }

    var body: some View {
        let totals = WorkoutTimelinePolicy.totals(days)
        FlatSection(endsToday ? "This week" : "7 days", systemImage: "flame.fill", tint: .strain,
                    trailing: trailing, contentSpacing: NoopMetrics.space2) {
            VStack(alignment: .leading, spacing: 0) {
                hero(totals)
                WorkoutWeekBars(days: bars)
                    .padding(.top, NoopMetrics.space4)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("workouts.historyChart")
                if totals.missingDurations > 0 {
                    Text("Sessions without a recorded duration aren't counted.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, NoopMetrics.space2)
                }
                WorkoutWeekStrip(facts: facts(totals))
                    .padding(.top, 14)
                if showsDailyTotals {
                    dailyTotals
                        .padding(.top, NoopMetrics.space2)
                        .transition(.softCard(reduced: reduceMotion))
                }
            }
        }
        .padding(.top, 14)
    }

    /// The span the seven days cover ("Oct 9 – 15"), so a week that does not end today says which it is.
    private var trailing: EyebrowTrailing {
        guard let interval else { return .none }
        return .custom(AnyView(
            Text(verbatim: WorkoutFormat.weekRange(interval))
                .font(StrandFont.sized(13.5))
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)))
    }

    /// Whether the seven days end today (rather than on an earlier day the hub is focused on, or the newest archived day).
    private var endsToday: Bool { days.last?.day == today }

    /// The week's known active time as the hero. A week with no session, or whose sessions carry no duration, reads "—",
    /// never a measured zero. One spoken element.
    @ViewBuilder private func hero(_ totals: WorkoutTimelineTotals) -> some View {
        let caption = endsToday ? String(localized: "Last 7 days") : String(localized: "7 days")
        if let minutes = totals.knownMinutes {
            let shown = Self.shownMinutes(minutes)
            Text(verbatim: shown > 0 ? WorkoutFormat.duration(shown * 60) : WorkoutFormat.grouped(shown))
                .font(StrandFont.number(heroSize, weight: .semibold))
                .tracking(-1)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Workout minutes, \(caption)"))
                .accessibilityValue(Text(verbatim: shown > 0
                    ? WorkoutFormat.spokenDuration(shown * 60) : WorkoutFormat.grouped(shown)))
                .accessibilityHint(Text("Recorded minutes from the sessions below. A day without sessions is not confirmed as a rest day."))
        } else {
            Text(verbatim: WidgetMetrics.missingValue)
                .font(StrandFont.number(heroSize, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Workout minutes, \(caption)"))
                .accessibilityValue(totals.sessions > 0 ? Text("Not recorded") : Text("No workouts"))
        }
    }

    /// Sessions, average Strain (NOOP's own scores only, so a week of imported WHOOP sessions has none) and calories.
    private func facts(_ totals: WorkoutTimelineTotals) -> [WorkoutWeekStrip.Fact] {
        [
            .init(label: "Sessions", value: totals.sessions.formatted()),
            .init(label: "Avg strain",
                  value: stats.averageStrainStored.map { StrainScale.formatted($0) } ?? WidgetMetrics.missingValue,
                  tint: DomainTint.strain.accent),
            .init(label: "Calories",
                  value: stats.energyKcal > 0 ? WorkoutFormat.grouped(stats.energyKcal) : WidgetMetrics.missingValue,
                  spokenValue: stats.energyKcal > 0 ? WorkoutFormat.spokenEnergy(stats.energyKcal) : nil),
        ]
    }

    /// Whole minutes as shown: a session under a minute still reads as one, never as zero.
    private static func shownMinutes(_ minutes: Double) -> Double {
        minutes > 0 ? max(1, minutes.rounded()) : 0
    }

    /// The days in the week bars' terms. Only known minutes make a bar.
    private var bars: [WorkoutWeekSummary.Day] {
        days.map { day in
            WorkoutWeekSummary.Day(start: day.day, sessions: day.sessions, activeSeconds: day.minutes * 60,
                                   isToday: day.day == today, isFuture: day.day > today)
        }
    }

    /// Each day's known minutes in words: "—" for no session, "Not recorded" for sessions without a duration.
    private var dailyTotals: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(days) { day in
                let label = WorkoutFormat.day(day.day)
                let value = dailyValue(day)
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    Text(verbatim: label)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: NoopMetrics.space2)
                    Text(verbatim: value.shown)
                        .font(StrandFont.footnote.monospacedDigit())
                        .foregroundStyle(value.isKnown ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                }
                .padding(.vertical, NoopMetrics.space2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: label))
                .accessibilityValue(Text(verbatim: value.spoken))
            }
        }
        .accessibilityIdentifier("workouts.dailyTotals")
    }

    private func dailyValue(_ day: WorkoutTimelineDay) -> (shown: String, spoken: String, isKnown: Bool) {
        if day.sessions == 0 { return (WidgetMetrics.missingValue, String(localized: "No workouts"), false) }
        guard let minutes = day.chartValue else {
            let text = String(localized: "Not recorded")
            return (text, text, false)
        }
        let shown = Self.shownMinutes(minutes)
        return (String(localized: "\(Int(shown)) min"),
                shown > 0 ? WorkoutFormat.spokenDuration(shown * 60) : String(localized: "\(Int(shown)) min"), true)
    }
}

// MARK: Loading

/// The hub before its rows have been read: the week section, the sport chips and a day of rows in their real shape, as
/// quiet placeholders. The header row above it is the real one.
struct WorkoutHistorySkeleton: View {
    private static let rows = (0..<3).map { _ in
        WorkoutRowPresentation(
            title: "Running", symbol: "figure.run", primary: "5.0 km", lines: [["7:10 AM", "30m", "Recorded"]],
            strain: .noop("10.0"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkoutHistoryChart.placeholder()
            HStack(spacing: NoopMetrics.space2) {
                ForEach([60, 110, 120, 100], id: \.self) { width in
                    Capsule(style: .continuous).fill(StrandPalette.chipFill).frame(width: CGFloat(width), height: 34)
                }
            }
            .padding(.top, 16)
            WorkoutDayHeader(title: "Today", sessions: 3)
            ForEach(Array(Self.rows.enumerated()), id: \.offset) { index, presentation in
                if index > 0 { WorkoutRowSeparator() }
                WorkoutRowContent(presentation: presentation)
            }
        }
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading your sessions…")
        .accessibilityIdentifier("workouts.historyLoading")
    }
}
