import SwiftUI
import Charts
import StrandDesign

/// Selection only does a binary search. Sanitizing, sorting and decimating happen in the load task.
struct WorkoutHeartChart: View {
    let projection: WorkoutChartProjection
    var sourceLabel: String = "Strap heart rate, averaged into time buckets"
    @State private var selectedTime: Date?
    @State private var showsReadings = false
    @State private var zoomed = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private var selected: WorkoutChartSample? { selectedTime.flatMap { projection.nearest(to: $0) } }
    private var reading: WorkoutChartSample? { selectedTime == nil ? projection.readings.last : selected }
    private var selectedIndex: Int? {
        selectedTime.flatMap { projection.nearestIndex(to: $0) }
    }

    var body: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 16) {
                ExperienceSectionHeading(title: "Heart rate", detail: sourceLabel)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) { readout; Spacer(minLength: 12); selectionTime }
                    VStack(alignment: .leading, spacing: 5) { readout; selectionTime }
                }
                if projection.points.isEmpty {
                    Text("No heart-rate readings in this session.")
                        .font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    chart
                        .frame(height: typeSize.isAccessibilitySize ? 270 : 220)
                    selectionControls
                    if projection.timeRange.upperBound.timeIntervalSince(projection.timeRange.lowerBound) > 1800 {
                        Toggle("Zoom to 15 minutes", isOn: $zoomed)
                            .font(StrandFont.caption).tint(StrandPalette.accent)
                    }
                    Text(projection.gapCount > 0
                         ? "Gaps show where readings are missing. Drag to inspect a reading."
                         : "Drag to inspect a reading. The arrows also move through the data.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup("Plotted readings", isExpanded: $showsReadings) {
                        LazyVStack(spacing: 0) {
                            ForEach(projection.points) { point in
                                HStack {
                                    Text(point.sample.time, format: .dateTime.hour().minute().second())
                                    Spacer()
                                    Text("\(Int(point.sample.bpm.rounded())) bpm").monospacedDigit()
                                }
                                .font(StrandFont.footnote)
                                .padding(.vertical, 10)
                                .accessibilityElement(children: .combine)
                                Divider().overlay(StrandPalette.hairline)
                            }
                        }
                        .padding(.top, 8)
                    }
                    .font(StrandFont.caption).tint(StrandPalette.accent)
                }
            }
        }
    }

    private var readout: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(reading.map { String(Int($0.bpm.rounded())) } ?? "—")
                .font(StrandFont.metricValue).monospacedDigit().foregroundStyle(StrandPalette.liveRed)
            Text("bpm").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
    private var selectionTime: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(selectedTime == nil ? "Latest plotted reading" : reading == nil ? "No nearby reading" : "Selected reading")
                .font(StrandFont.micro).foregroundStyle(StrandPalette.textSecondary)
            if let reading {
                Text(reading.time, format: .dateTime.hour().minute().second())
                    .font(StrandFont.caption).monospacedDigit().foregroundStyle(StrandPalette.textPrimary)
            }
        }
    }

    @ViewBuilder private var chart: some View {
        #if os(iOS)
        if zoomed {
            baseChart
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: 900)
                .chartXSelection(value: $selectedTime)
        } else {
            baseChart.chartXSelection(value: $selectedTime)
        }
        #else
        baseChart
        #endif
    }

    private var baseChart: some View {
        Chart {
            ForEach(projection.points) { point in
                LineMark(x: .value("Time", point.sample.time), y: .value("Heart rate", point.sample.bpm),
                         series: .value("Recording segment", point.segment))
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(StrandPalette.liveRed)
                    .symbol(.circle)
                    .symbolSize(projection.points.count == 1 ? 42 : 7)
                    .accessibilityLabel(point.sample.time.formatted(date: .omitted, time: .standard))
                    .accessibilityValue("\(Int(point.sample.bpm.rounded())) beats per minute")
            }
            if let selected {
                RuleMark(x: .value("Selected time", selected.time))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .accessibilityLabel("Selected time")
                    .accessibilityValue(selected.time.formatted(date: .omitted, time: .standard))
                PointMark(x: .value("Selected time", selected.time), y: .value("Selected heart rate", selected.bpm))
                    .symbolSize(65).foregroundStyle(StrandPalette.textPrimary)
                    .accessibilityLabel("Selected heart-rate reading")
                    .accessibilityValue("\(Int(selected.bpm.rounded())) beats per minute")
            }
        }
        .chartXScale(domain: projection.timeRange)
        .chartYScale(domain: projection.bpmRange)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisTick()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline)
                AxisValueLabel()
            }
        }
        .chartLegend(.hidden)
        .accessibilityLabel("Session heart-rate chart. Horizontal axis: time. Vertical axis: beats per minute.")
    }

    private var selectionControls: some View {
        HStack(spacing: 12) {
            Button { moveSelection(by: -1) } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Previous heart-rate reading")
            .disabled((selectedIndex ?? projection.readings.count) <= 0)
            Button("Clear selection") { selectedTime = nil }
                .font(StrandFont.caption).frame(maxWidth: .infinity, minHeight: 44)
                .disabled(selectedTime == nil)
            Button { moveSelection(by: 1) } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Next heart-rate reading")
            .disabled(selectedIndex == projection.readings.count - 1)
        }
        .buttonStyle(.bordered).tint(StrandPalette.accent)
    }

    private func moveSelection(by delta: Int) {
        guard !projection.readings.isEmpty else { return }
        let initial = delta < 0 ? projection.readings.count : -1
        let next = min(projection.readings.count - 1, max(0, (selectedIndex ?? initial) + delta))
        selectedTime = projection.readings[next].time
    }
}
