import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

extension TrendsView {

    @ViewBuilder
    var paperScoresOverTime: some View {
        if let screenSnapshot = currentScreenSnapshot {
            paperScoresOverTime(screenSnapshot)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                rangeControls
                ProgressView("Preparing trends…")
                    .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
    }

    private func paperScoresOverTime(_ snapshot: TrendsScreenSnapshot) -> some View {
        let series = snapshot.currentSeries
        let previousSeries = snapshot.previousSeries

        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Selected range").strandOverline()
                Text("Last \(selectedRange.days) calendar days through today")
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textSecondary)
            }

            rangeControls

            if !snapshot.selectedPoints.isEmpty {
                TrendPanelChart(
                    days: snapshot.selectedCalendarDays,
                    dateDomain: snapshot.selectedDateDomain,
                    referenceDate: trendReferenceDate,
                    calendar: .current,
                    baseline: snapshot.baseline,
                    typical: snapshot.typical,
                    tint: selectedMetric.tint,
                    unit: selectedMetric.unit,
                    valueFormat: selectedMetric.format,
                    range: selectedRange,
                    direction: selectedMetric.chartDirection
                )
                .id("\(selectedMetric.rawValue)-\(selectedRange.rawValue)")

                if selectedRange != .week {
                    Text("Calendar heat · latest 35 days")
                        .font(StrandFont.micro)
                        .foregroundStyle(StrandPalette.textSecondary)
                    TrendMonthHeat(
                        days: snapshot.heatDays,
                        tint: selectedMetric.tint,
                        referenceDate: trendReferenceDate,
                        valueFormat: selectedMetric.format,
                        colorScale: selectedMetric == .recovery ? .recoveryBands : .intensity
                    )
                    .id("heat-\(selectedMetric.rawValue)-\(selectedRange.rawValue)")
                }
            }

            trendV2Row(
                "Recovery",
                points: series.recovery,
                previousPoints: previousSeries.recovery,
                goodDirection: .higher,
                tint: StrandPalette.recoveryData,
                format: { "\(Int($0.rounded()))" }
            )
            trendV2Row(
                "Strain",
                points: series.strain,
                previousPoints: previousSeries.strain,
                goodDirection: .neutral,
                tint: StrandPalette.strainAccent,
                format: StrainScale.formatted
            )
            trendV2Row(
                "Sleep",
                points: series.sleep,
                previousPoints: previousSeries.sleep,
                goodDirection: .higher,
                tint: StrandPalette.sleepAccent,
                format: { "\(Int($0.rounded()))%" }
            )
            trendV2Row(
                "HRV",
                points: series.hrv,
                previousPoints: previousSeries.hrv,
                goodDirection: .higher,
                tint: StrandPalette.metricPurple,
                format: { "\(Int($0.rounded())) ms" }
            )

            if !snapshot.weekdayAverages.compactMap({ $0 }).isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedRange.averageHeading).strandOverline()
                    Text("By weekday · \(selectedRange.days) calendar days")
                        .font(StrandFont.micro)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                TrendWeekdayBars(
                    values: snapshot.weekdayAverages,
                    tint: selectedMetric.tint,
                    referenceDate: trendReferenceDate,
                    calendar: .current,
                    valueFormat: selectedMetric.formatWithUnit
                )
                .frame(height: 150)
            }
        }
    }

    private var rangeControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) {
                metricDropdown
                Spacer(minLength: 8)
                ForEach(TrendRange.allCases) { range in rangeChip(range) }
            }
            VStack(alignment: .leading, spacing: 8) {
                metricDropdown
                HStack(spacing: 7) {
                    ForEach(TrendRange.allCases) { range in rangeChip(range) }
                }
            }
        }
    }

    private var metricDropdown: some View {
        Menu {
            ForEach(ProductionTrendMetric.allCases) { metric in
                Button {
                    selectedMetric = metric
                } label: {
                    if selectedMetric == metric {
                        Label(metric.rawValue, systemImage: "checkmark")
                    } else {
                        Text(metric.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(selectedMetric.tint).frame(width: 7, height: 7)
                Text(selectedMetric.rawValue)
                    .font(StrandFont.caption.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minHeight: 44)
            .background(StrandPalette.surfaceRaised, in: Capsule())
            .overlay(Capsule().stroke(StrandPalette.hairlineStrong, lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Metric: \(selectedMetric.rawValue). Opens the metric list")
    }

    private func rangeChip(_ range: TrendRange) -> some View {
        Button { selectedRange = range } label: {
            Text(range.rawValue)
                .font(StrandFont.micro.weight(.semibold))
                .fixedSize()
                .foregroundStyle(selectedRange == range
                    ? StrandPalette.appCanvas
                    : StrandPalette.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .frame(minHeight: 44)
                .background(
                    selectedRange == range
                        ? StrandPalette.textPrimary
                        : StrandPalette.surfaceRaised,
                    in: Capsule()
                )
                .overlay(
                    Capsule().stroke(
                        StrandPalette.hairlineStrong,
                        lineWidth: selectedRange == range ? 0 : 0.75
                    )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(range.days) days")
    }

    private func trendV2Row(
        _ label: String,
        points: [TrendPoint],
        previousPoints: [TrendPoint],
        goodDirection: TrendSummaryGoodDirection,
        tint: Color,
        format: (Double) -> String
    ) -> some View {
        let presentation = TrendSummaryPresentation(
            series: points,
            previousSeries: previousPoints,
            goodDirection: goodDirection,
            expectedCount: selectedRange.days
        )
        let tone: TrendDeltaTone
        switch presentation.deltaTone {
        case .positive: tone = .positive
        case .negative: tone = .negative
        case .neutral: tone = .neutral
        }
        let deltaText = !presentation.comparisonIsReliable
            ? "Early read · \(presentation.currentCount)/\(presentation.expectedCount) days"
            : presentation.delta.map { delta in
                "\(delta >= 0 ? "+" : "−")\(format(abs(delta))) avg"
            } ?? "Need prior data"

        return TrendDeltaRow(
            label: label,
            subtitle: selectedRange.summarySubtitle,
            values: presentation.spark.map(\.value),
            latest: presentation.latest.map(format) ?? "—",
            delta: deltaText,
            tone: tone,
            tint: tint
        )
    }
}
