import SwiftUI
import Charts
import StrandDesign

struct WorkoutZoneSummary: View {
    let minutes: [Double]
    let timeline: WorkoutZoneTimeline?
    let imported: Bool
    let start: Int
    let end: Int
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedZone: Int?
    @State private var selectedAngle: Double?
    private var values: [Double] { Array((minutes + Array(repeating: 0, count: 5)).prefix(5)).map { max(0, $0) } }

    private var zoneShareLabel: String {
        guard let selectedZone else { return "Time in zones" }
        let total = max(0.001, values.reduce(0, +))
        let percent = Int((values[selectedZone - 1] / total * 100).rounded())
        return "\(percent)% of zone time"
    }

    var body: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("HEART RATE ZONES").font(StrandFont.sectionOverline)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Text("Tap a zone to explore your effort.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                Chart(Array(values.enumerated()), id: \.offset) { index, value in
                    SectorMark(angle: .value("Minutes", value), innerRadius: .ratio(0.72), angularInset: 2)
                        .foregroundStyle(StrandPalette.hrZoneColor(index + 1))
                        .opacity(selectedZone == nil || selectedZone == index + 1 ? 1 : 0.25)
                }
                .frame(height: 180)
                .chartAngleSelection(value: $selectedAngle)
                .chartBackground { _ in
                    if typeSize.isAccessibilitySize {
                        Text(duration(selectedZone.map { values[$0 - 1] } ?? values.reduce(0, +)))
                            .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                    } else {
                        VStack(spacing: 4) {
                            Text(selectedZone.map { "Zone \($0)" } ?? "Recorded zones")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                            Text(duration(selectedZone.map { values[$0 - 1] } ?? values.reduce(0, +)))
                                .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                            Text(zoneShareLabel)
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                }
                .accessibilityLabel("Time in heart rate zones. Select a zone using the buttons below.")
                .onChange(of: selectedAngle) { _, angle in
                    guard let angle else { return }
                    var cumulative = 0.0
                    for (index, value) in values.enumerated() where value > 0 {
                        cumulative += value
                        if angle <= cumulative { selectedZone = index + 1; break }
                    }
                }
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedZone.map { "Zone \($0)" } ?? "Recorded zones")
                            .font(StrandFont.headline)
                        Text(zoneShareLabel).font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 6))) {
                    ForEach(1...5, id: \.self) { zone in
                        Button {
                            selectedZone = selectedZone == zone ? nil : zone
                        } label: {
                            VStack(spacing: 6) {
                                HStack(spacing: 4) {
                                    Circle().fill(StrandPalette.hrZoneColor(zone)).frame(width: 7, height: 7)
                                    Text("Z\(zone)")
                                }
                                Text(duration(values[zone - 1])).monospacedDigit()
                            }
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(selectedZone == zone ? StrandPalette.hrZoneColor(zone).opacity(0.18) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Zone \(zone), \(duration(values[zone - 1]))")
                        .accessibilityAddTraits(selectedZone == zone ? .isSelected : [])
                    }
                }
                if imported {
                    Text("Zone totals were imported. The timeline uses recorded readings and your current zone thresholds; exact imported intervals are unavailable.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
                if let timeline, !timeline.points.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Text(selectedZone.map { "Zone \($0) on your timeline" } ?? "Heart rate timeline")
                            .font(StrandFont.headline)
                        Spacer(minLength: 8)
                        Button("Show all") { selectedZone = nil; selectedAngle = nil }
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                            .frame(minHeight: 44)
                            .opacity(selectedZone == nil ? 0 : 1)
                            .disabled(selectedZone == nil)
                            .accessibilityHidden(selectedZone == nil)
                    }
                    Text("BPM").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    WorkoutZoneTimelineChart(timeline: timeline, start: start, end: end, selectedZone: selectedZone)
                    if timeline.unobservedSeconds > 10 {
                        Text("\(duration(timeline.unobservedSeconds / 60)) without readings. Gaps are not counted as time in a zone.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    }
                    if timeline.belowZoneMinutes > 0 {
                        Text("Below Zone 1: \(duration(timeline.belowZoneMinutes))")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    }
                } else {
                    Text("No recorded timeline is available for this workout.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selectedZone)
        }
    }
    private func duration(_ minutes: Double) -> String {
        let seconds = max(0, Int((minutes * 60).rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

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
        let seconds = max(0, Int(date.timeIntervalSince1970) - start)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    private func highlight(_ interval: WorkoutZoneTimeline.Interval) -> some ChartContent {
        RectangleMark(xStart: .value("Start", date(interval.start)),
                      xEnd: .value("End", date(interval.end)))
            .foregroundStyle(StrandPalette.hrZoneColor(interval.zone).opacity(0.2))
    }
    private func trace(_ point: WorkoutZoneTimeline.Point) -> some ChartContent {
        LineMark(x: .value("Time", date(point.ts)), y: .value("BPM", point.bpm),
                 series: .value("Recording segment", point.segment))
            .foregroundStyle(StrandPalette.liveRed)
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
                AxisGridLine().foregroundStyle(StrandPalette.textTertiary.opacity(0.12))
                AxisValueLabel {
                    if let timestamp = value.as(Date.self) {
                        Text(elapsedLabel(timestamp)).monospacedDigit()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
                AxisGridLine().foregroundStyle(StrandPalette.textTertiary.opacity(0.12))
                AxisValueLabel()
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 170)
        .accessibilityLabel(selectedZone.map { "Recorded heart rate. Zone \($0) intervals highlighted." } ?? "Recorded heart rate timeline")
    }
}
