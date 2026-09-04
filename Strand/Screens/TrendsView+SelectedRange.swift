import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

extension TrendsView {

    @ViewBuilder
    var trainingLoadCard: some View {
        if let snapshot = currentScreenSnapshot {
            let load = snapshot.trainingLoad
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                SectionHeader(
                    "Training load",
                    overline: "Effort",
                    trailing: load.map(trainingLoadStatus) ?? String(localized: "Loading")
                )
                PaperCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                        if let load, load.state == .unavailable {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "chart.line.uptrend.xyaxis")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(StrandPalette.strainAccent)
                                    .frame(width: 28, height: 28)
                                    .background(StrandPalette.strainAccent.opacity(0.10), in: Circle())
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(trainingLoadUnavailableTitle(load))
                                        .font(StrandFont.subhead.weight(.semibold))
                                        .foregroundStyle(StrandPalette.textPrimary)
                                    Text(trainingLoadUnavailableDetail(load))
                                        .font(StrandFont.micro)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                }
                            }
                        } else if let load {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 0) {
                                    trainingLoadMetric("Chronic", value: load.chronic, caption: "42-day")
                                    Divider().padding(.horizontal, NoopMetrics.space3)
                                    trainingLoadMetric("Acute", value: load.acute, caption: "7-day")
                                    Divider().padding(.horizontal, NoopMetrics.space3)
                                    trainingLoadBalance(load.balance)
                                }
                                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                                    HStack(spacing: 0) {
                                        trainingLoadMetric("Chronic", value: load.chronic, caption: "42-day")
                                        Divider().padding(.horizontal, NoopMetrics.space3)
                                        trainingLoadMetric("Acute", value: load.acute, caption: "7-day")
                                    }
                                    trainingLoadBalance(load.balance)
                                }
                            }

                            if load.chronicSpark.count > 1, load.acuteSpark.count > 1 {
                                VStack(spacing: NoopMetrics.space3) {
                                    trainingLoadSparkRow(
                                        "Chronic",
                                        values: load.chronicSpark,
                                        tint: StrandPalette.strainAccent.opacity(0.72)
                                    )
                                    trainingLoadSparkRow(
                                        "Acute",
                                        values: load.acuteSpark,
                                        tint: StrandPalette.strainAccent
                                    )
                                }
                                .padding(.top, NoopMetrics.space2)
                            }
                        } else {
                            HStack(alignment: .top, spacing: 12) {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Reading load history")
                                        .font(StrandFont.subhead.weight(.semibold))
                                        .foregroundStyle(StrandPalette.textPrimary)
                                    Text("NOOP is reading up to 180 days of daily Effort before showing your load.")
                                        .font(StrandFont.micro)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                }
                            }
                        }

                        Text("Based on daily Effort. Descriptive only; it does not change Readiness.")
                            .font(StrandFont.micro)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func trainingLoadMetric(_ title: String, value: Double?, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textTertiary)
            Text(value.map { String(format: "%.1f", $0) } ?? "—")
                .font(StrandFont.number(24, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textPrimary)
            Text(caption)
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trainingLoadBalance(_ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("BALANCE")
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textTertiary)
            Text(value.map { String(format: "%@%.1f", $0 > 0 ? "+" : "", $0) } ?? "—")
                .font(StrandFont.number(24, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textPrimary)
            Text("chronic − acute")
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trainingLoadSparkRow(_ label: String, values: [Double], tint: Color) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(StrandFont.micro.weight(.semibold))
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 54, alignment: .leading)
            PaperSparkline(bpm: values, tint: tint, height: 30, animated: false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) training load trend")
    }

    private func trainingLoadStatus(_ load: TrainingLoadSnapshot) -> String {
        switch load.state {
        case .established: return String(localized: "Established")
        case .building: return String(localized: "Building \(load.contiguousDays)/42")
        case .unavailable: return String(localized: "Building")
        }
    }

    private func trainingLoadUnavailableTitle(_ load: TrainingLoadSnapshot) -> String {
        switch load.unavailableReason {
        case .notEnoughContiguousDays:
            return String(localized: "Building your load history")
        case .missingTargetDay:
            return String(localized: "Today's Effort is not ready")
        default:
            return String(localized: "Training load is not ready")
        }
    }

    private func trainingLoadUnavailableDetail(_ load: TrainingLoadSnapshot) -> String {
        if load.unavailableReason == .notEnoughContiguousDays {
            let remaining = max(0, 14 - load.contiguousDays)
            return remaining == 1
                ? String(localized: "Need 1 more contiguous day with an Effort value.")
                : String(localized: "Need \(remaining) more contiguous days with Effort values.")
        }
        return String(localized: "NOOP needs a continuous run of daily Effort values to model acute and chronic load.")
    }

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
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
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
                    // Keep the secondary calendar detail below a clear fold; the custom tab bar owns the
                    // lower edge of the first viewport, so this gap prevents the heatmap from reading as
                    // clipped content instead of the next layer of the Trends story.
                    .padding(.top, NoopMetrics.space6)
                }
            }

            trendV2Row(
                "Recovery",
                points: series.recovery,
                previousPoints: previousSeries.recovery,
                goodDirection: .higher,
                tint: StrandPalette.recoveryData,
                format: ProductionTrendMetric.recovery.format
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
                format: ProductionTrendMetric.sleepPerformance.formatWithUnit
            )
            trendV2Row(
                "HRV",
                points: series.hrv,
                previousPoints: previousSeries.hrv,
                goodDirection: .higher,
                tint: StrandPalette.metricPurple,
                format: ProductionTrendMetric.hrv.formatWithUnit
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
                .frame(minWidth: 44, minHeight: 44)
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
