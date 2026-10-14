import SwiftUI
import Charts
import StrandDesign
import WhoopStore

struct WorkoutHistoryDay: Identifiable {
    let day: Date
    let rows: [WorkoutRow]
    var id: Date { day }

    static func grouped(_ rows: [WorkoutRow], calendar: Calendar = .autoupdatingCurrent) -> [Self] {
        let ordered = rows.sorted { $0.startTs == $1.startTs ? $0.listID < $1.listID : $0.startTs > $1.startTs }
        let groups = Dictionary(grouping: ordered) { calendar.startOfDay(for: Date(timeIntervalSince1970: Double($0.startTs))) }
        return groups.keys.sorted(by: >).map { Self(day: $0, rows: groups[$0] ?? []) }
    }

    static func title(for day: Date, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return String(localized: "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        return day.formatted(date: .abbreviated, time: .omitted)
    }
}

/// One seven-day projection of the exact filtered rows supplied to the feed. No detail traces or additional reads.
struct WorkoutHistoryChart: View {
    let rows: [WorkoutRow]
    let anchor: Date
    @State private var selection: Date?
    @State private var showDailyValues = false

    private var days: [WorkoutTimelineDay] {
        WorkoutTimelinePolicy.week(items: rows.map {
            WorkoutTimelineItem(id: $0.listID, start: Date(timeIntervalSince1970: Double($0.startTs)),
                                seconds: WorkoutFacts.activeSeconds($0))
        }, through: anchor)
    }

    var body: some View {
        let values = days
        let selected = selection.flatMap { day in values.first { Calendar.autoupdatingCurrent.isDate($0.day, inSameDayAs: day) } }
        let minutes = values.reduce(0) { $0 + $1.minutes }
        let missing = values.reduce(0) { $0 + $1.missingDurations }
        let sessions = values.reduce(0) { $0 + $1.sessions }
        let selectedIsMissing = selected.map { $0.chartValue == nil } ?? false
        let totalIsMissing = selected == nil && sessions > 0 && sessions == missing
        let totalText = selectedIsMissing || totalIsMissing ? "—"
            : (selected?.minutes ?? minutes).formatted(.number.precision(.fractionLength(0)))
        let dateDomain = (values.first?.day ?? anchor)...(values.last?.day ?? anchor)
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            SectionEyebrow("Workout minutes", systemImage: "chart.xyaxis.line", tint: .workout,
                           trailing: .text("7 days"))
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(totalText)
                    .font(StrandFont.title1).monospacedDigit()
                Text("min").font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
                Spacer(minLength: 4)
                Text(selected.map { $0.day.formatted(date: .abbreviated, time: .omitted) } ?? "Recorded in this week")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.trailing)
            }
            Chart {
                ForEach(Array(values.enumerated()), id: \.element.id) { index, value in
                    if let minutes = value.chartValue {
                        // A different series after a missing duration prevents a line through an unknown day.
                        let segment = values.prefix(index + 1).filter { $0.chartValue == nil }.count
                        LineMark(x: .value("Day", value.day), y: .value("Recorded minutes", minutes),
                                 series: .value("Observed segment", segment))
                            .foregroundStyle(StrandPalette.strainAccent).lineStyle(StrokeStyle(lineWidth: 2.5))
                            .interpolationMethod(.linear)
                        PointMark(x: .value("Day", value.day), y: .value("Recorded minutes", minutes))
                            .foregroundStyle(StrandPalette.strainAccent).symbolSize(18)
                    }
                }
                if let selected {
                    RuleMark(x: .value("Selected day", selected.day))
                        .foregroundStyle(StrandPalette.textTertiary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartXSelection(value: $selection)
            .chartLegend(.hidden)
            .chartXScale(domain: dateDomain)
            .chartYScale(domain: 0...max(10, values.map(\.minutes).max() ?? 0))
            .chartXAxis { AxisMarks(values: values.map(\.day)) { value in
                AxisValueLabel(format: .dateTime.weekday(.narrow))
                AxisTick().foregroundStyle(StrandPalette.hairline)
            } }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
            .frame(height: 136)
            .accessibilityLabel("Recorded workout minutes over seven calendar days")
            .accessibilityIdentifier("workouts.historyChart")
            if let first = values.first, let last = values.last {
                Text(first.day.formatted(date: .abbreviated, time: .omitted) + " – " + last.day.formatted(date: .abbreviated, time: .omitted))
                    .font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
            }
            if let selected, selected.chartValue == nil {
                Text("Duration is missing for this day's recorded sessions.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            } else if missing > 0 {
                Text("Known duration only. \(missing) sessions have no valid duration.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            }
            DisclosureGroup("Daily totals", isExpanded: $showDailyValues) {
                VStack(spacing: 0) {
                    ForEach(values) { value in
                        HStack(alignment: .firstTextBaseline) {
                            Text(value.day.formatted(date: .abbreviated, time: .omitted))
                            Spacer()
                            Text(value.chartValue.map { $0.formatted(.number.precision(.fractionLength(0))) + " min" } ?? "Duration missing")
                                .monospacedDigit()
                        }
                        .font(StrandFont.footnote).frame(minHeight: 44)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            Text("Only the recorded sessions in the current filters contribute. An empty day does not establish a rest day.")
                .font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, NoopMetrics.space3)
        .onChange(of: anchor) { _, _ in selection = nil }
    }
}

/// Matches the new above-the-fold layout without displaying invented workout totals.
struct WorkoutHistorySkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            RoundedRectangle(cornerRadius: 18).fill(StrandPalette.inset).frame(width: 158, height: 40)
            RoundedRectangle(cornerRadius: 6).fill(StrandPalette.inset).frame(width: 115, height: 16)
            RoundedRectangle(cornerRadius: 10).fill(StrandPalette.inset).frame(height: 180)
            RoundedRectangle(cornerRadius: 16).fill(StrandPalette.inset).frame(width: 185, height: 32)
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 14) {
                    Circle().fill(StrandPalette.inset).frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 4).fill(StrandPalette.inset).frame(width: 135, height: 14)
                        RoundedRectangle(cornerRadius: 4).fill(StrandPalette.inset).frame(width: 185, height: 10)
                    }
                }.frame(height: 64)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading workout history")
        .accessibilityIdentifier("workouts.historyLoading")
    }
}
