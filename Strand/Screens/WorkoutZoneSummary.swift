import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign

// MARK: - Zones on the workout summary
//
// Time in each heart-rate zone as the shared distribution (one bar, one row per zone), and under it the session's heart
// rate as a timeline. Choosing a zone marks it in the bar and shows where it fell on the timeline; choosing it again, or
// Show all, clears the choice.

struct WorkoutZoneSummary: View {
    let minutes: [Double]
    let timeline: WorkoutZoneTimeline?
    /// True when the zone totals came from an import rather than from the strap's own readings.
    let imported: Bool
    let start: Int
    let end: Int
    /// The zones' bpm bands, from the person's max heart rate. nil leaves the ranges off.
    let zoneSet: HRZoneSet?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedZone: Int?

    var body: some View {
        FlatSection("Heart rate zones", systemImage: "heart.fill", tint: .heart) {
            VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
                HRZoneDistribution(
                    zones: WorkoutZoneRows.zones(minutes: minutes, zoneSet: zoneSet),
                    selection: $selectedZone,
                    rowHint: String(localized: "Shows where this zone fell on the timeline"))
                Text(imported
                     ? "Zone totals were imported. The timeline uses recorded readings and your current zone thresholds; exact imported intervals are unavailable."
                     : "Tap a zone to explore your effort.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                timelineBlock
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selectedZone)
        }
    }

    // MARK: Timeline

    @ViewBuilder private var timelineBlock: some View {
        if let timeline, !timeline.points.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    Group {
                        if let selectedZone {
                            Text("Zone \(selectedZone) on your timeline")
                        } else {
                            Text("Heart rate timeline")
                        }
                    }
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: NoopMetrics.space2)
                    Button("Show all") { selectedZone = nil }
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(minHeight: 44)
                        .opacity(selectedZone == nil ? 0 : 1)
                        .disabled(selectedZone == nil)
                        .accessibilityHidden(selectedZone == nil)
                }
                WorkoutZoneTimelineChart(timeline: timeline, start: start, end: end, selectedZone: selectedZone)
                if timeline.unobservedSeconds > 10 {
                    Text("\(WorkoutFormat.spokenDuration(timeline.unobservedSeconds)) without readings. Gaps are not counted as time in a zone.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if timeline.belowZoneMinutes > 0 {
                    Text("Below Zone 1: \(WorkoutFormat.spokenDuration(timeline.belowZoneMinutes * 60))")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        } else {
            Text("No recorded timeline is available for this workout.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Timeline chart

private struct WorkoutZoneTimelineChart: View {
    let timeline: WorkoutZoneTimeline
    let start: Int
    let end: Int
    let selectedZone: Int?

    private var ticks: [Date] {
        let length = max(1, end - start)
        return [start, start + length / 3, start + length * 2 / 3, start + length].map(date)
    }

    private func date(_ timestamp: Int) -> Date {
        Date(timeIntervalSince1970: Double(timestamp))
    }

    private func elapsedLabel(_ date: Date) -> String {
        WorkoutElapsed.text(max(0, date.timeIntervalSince1970 - Double(start)))
    }

    private func highlight(_ interval: WorkoutZoneTimeline.Interval) -> some ChartContent {
        RectangleMark(xStart: .value("Start", date(interval.start)),
                      xEnd: .value("End", date(interval.end)))
            .foregroundStyle(StrandPalette.hrZoneColor(interval.zone).opacity(0.28))
    }

    private func trace(_ point: WorkoutZoneTimeline.Point) -> some ChartContent {
        LineMark(x: .value("Time", date(point.ts)), y: .value("BPM", point.bpm),
                 series: .value("Recording segment", point.segment))
            .foregroundStyle(StrandPalette.metricRose)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }

    var body: some View {
        Chart {
            if let selectedZone {
                ForEach(timeline.intervals.filter { $0.zone == selectedZone }) { interval in
                    highlight(interval)
                }
            }
            ForEach(timeline.points) { point in trace(point) }
        }
        .chartXScale(domain: date(start)...date(max(start + 1, end)))
        .chartXAxis {
            AxisMarks(values: ticks) { value in
                AxisGridLine().foregroundStyle(StrandPalette.hairline)
                AxisValueLabel {
                    if let timestamp = value.as(Date.self) {
                        Text(verbatim: elapsedLabel(timestamp)).font(StrandFont.micro).monospacedDigit()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
                AxisGridLine().foregroundStyle(StrandPalette.hairline)
                AxisValueLabel().font(StrandFont.micro)
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 170)
        .accessibilityLabel(selectedZone.map { Text("Recorded heart rate. Zone \($0) intervals highlighted.") }
                            ?? Text("Recorded heart rate timeline"))
    }
}
