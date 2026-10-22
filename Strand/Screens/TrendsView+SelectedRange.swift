import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

extension TrendsView {

    // MARK: - Rhythm

    /// The one hairline between two Trends sections: the same 1pt hairline Today draws, with even air on
    /// both sides (the sections' ink, not their layout boxes, sets the visible gap).
    var trendsSeparator: some View {
        TodaySectionSeparator(above: 10, below: 12)
    }

    // MARK: - Training load

    /// The whole section opens the training load detail, the way a #55 tappable section does: the eyebrow's chevron
    /// says so, with no extra footer row to break the hairline rhythm. VoiceOver hears one heading with a short summary
    /// rather than every figure in the section.
    @ViewBuilder
    var trainingLoadCard: some View {
        if let snapshot = currentScreenSnapshot {
            trendsSeparator
            TrainingLoadDetailLink(key: snapshot.key, rangeDays: selectedRange.days,
                                   voiceOverSummary: trainingLoadVoiceOverSummary(snapshot.trainingLoad)) {
                trainingLoadSection(snapshot.trainingLoad)
            }
        }
    }

    private func trainingLoadSection(_ load: TrainingLoadSnapshot?) -> some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow(
                title: String(localized: "Training load"),
                systemImage: "flame.fill",
                tint: .strain,
                trailing: .pill(
                    LocalizedStringKey(load.map(trainingLoadStatus) ?? "Loading"),
                    tone: load.map { TrainingLoadCopy.tone($0.state) } ?? .neutral
                ),
                showsChevron: true
            )
            trainingLoadBody(load)
            Text("Based on daily Strain. Descriptive only; it does not change Readiness.")
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func trainingLoadBody(_ load: TrainingLoadSnapshot?) -> some View {
        if let load, load.state == .unavailable {
            VStack(alignment: .leading, spacing: 4) {
                Text(TrainingLoadCopy.unavailableTitle(load.gap))
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(TrainingLoadCopy.unavailableDetail(load.gap))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let load {
            VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
                StatFooter(
                    items: [
                        (String(localized: "Recent load"), trainingLoadNumber(load.acute)),
                        (String(localized: "Fitness base"), trainingLoadNumber(load.chronic)),
                        (String(localized: "Form"), trainingLoadBalance(load.balance)),
                    ],
                    style: .prominent
                )
                if load.chronicSpark.count > 1, load.acuteSpark.count > 1 {
                    TrendsLoadChart(
                        chronic: load.chronicSpark,
                        acute: load.acuteSpark,
                        tint: .strain,
                        startLabel: String(localized: "\(load.sparkSpanDays) days ago"),
                        endLabel: String(localized: "Today")
                    )
                }
                if let loadFocus {
                    LoadFocusCardRow(summary: loadFocus)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reading load history")
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("NOOP is reading up to 180 days of daily Strain before showing your load.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func trainingLoadNumber(_ value: Double?) -> String {
        value.map { DrillInFormat.number($0, fractionDigits: 1) } ?? WidgetMetrics.missingValue
    }

    private func trainingLoadBalance(_ value: Double?) -> String {
        value.map { DrillInFormat.signed($0, fractionDigits: 1) } ?? WidgetMetrics.missingValue
    }

    /// The same pill the detail page shows, from the same words.
    private func trainingLoadStatus(_ load: TrainingLoadSnapshot) -> String {
        TrainingLoadCopy.status(state: load.state, gap: load.gap, observedDays: load.contiguousDays)
    }

    /// One short VoiceOver label for the whole tappable section.
    /// Built only from keys the catalog already translates, so every locale hears its own words.
    private func trainingLoadVoiceOverSummary(_ load: TrainingLoadSnapshot?) -> String {
        let title = String(localized: "Training load")
        guard let load else { return [title, String(localized: "Loading")].joined(separator: ", ") }
        let status = trainingLoadStatus(load)
        guard load.state != .unavailable else {
            return [title, status, TrainingLoadCopy.unavailableTitle(load.gap)].joined(separator: ", ")
        }
        return [title, status,
                String(localized: "Recent load") + " " + trainingLoadNumber(load.acute),
                String(localized: "Fitness base") + " " + trainingLoadNumber(load.chronic),
                String(localized: "Form") + " " + trainingLoadBalance(load.balance)]
            .joined(separator: ", ") + (loadFocus.map { ". " + LoadFocusCardRow.spoken($0) } ?? "")
    }

    // MARK: - Selected range

    @ViewBuilder
    var paperScoresOverTime: some View {
        if let screenSnapshot = currentScreenSnapshot {
            paperScoresOverTime(screenSnapshot)
        } else {
            preparingSection
        }
    }

    /// Controls first, so the layout does not jump when the snapshot lands, with a quiet rail where the chart
    /// will be.
    private var preparingSection: some View {
        let tint = selectedMetric.domainTint(latest: nil)
        return VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            selectedRangeHeader(tint: tint)
            HeroValue(
                value: WidgetMetrics.missingValue,
                caption: String(localized: "Preparing trends…"),
                captionPlacement: .below
            )
            TrendsGhostRail(height: 148)
        }
    }

    private func paperScoresOverTime(_ snapshot: TrendsScreenSnapshot) -> some View {
        let series = snapshot.currentSeries
        let previousSeries = snapshot.previousSeries
        let hasSelectedData = !snapshot.selectedPoints.isEmpty
        let showsCalendar = hasSelectedData && selectedRange != .week && !snapshot.heatDays.isEmpty
        let showsWeekdays = !snapshot.weekdayAverages.compactMap({ $0 }).isEmpty

        return VStack(alignment: .leading, spacing: 0) {
            selectedRangeSection(snapshot)
            if showsCalendar {
                trendsSeparator
                calendarSection(snapshot)
            }
            if showsWeekdays {
                trendsSeparator
                weekdaySection(snapshot)
            }
            trendsSeparator
            scoresSection(series: series, previousSeries: previousSeries)
        }
    }

    private func selectedRangeSection(_ snapshot: TrendsScreenSnapshot) -> some View {
        let tint = selectedMetric.domainTint(latest: snapshot.selectedPoints.last?.value)
        return VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            selectedRangeHeader(tint: tint)

            if snapshot.selectedPoints.isEmpty {
                HeroValue(
                    value: WidgetMetrics.missingValue,
                    caption: String(localized: "No \(selectedMetric.rawValue) data in this range"),
                    captionPlacement: .below
                )
                TrendsGhostRail(height: 148)
            } else {
                TrendsHeroChart(
                    days: snapshot.selectedCalendarDays,
                    dateDomain: snapshot.selectedDateDomain,
                    referenceDate: trendReferenceDate,
                    calendar: .current,
                    baseline: snapshot.baseline,
                    typical: snapshot.typical,
                    tint: tint,
                    colorsLineByBand: selectedMetric == .recovery,
                    unit: selectedMetric.unit,
                    valueFormat: selectedMetric.format,
                    valueBounds: selectedMetric.valueBounds,
                    direction: selectedMetric.chartDirection,
                    metricName: selectedMetric.rawValue
                )
                .id("\(selectedMetric.rawValue)-\(selectedRange.rawValue)")

                let values = snapshot.selectedPoints.map(\.value)
                StatFooter(items: [
                    (String(localized: "Low"), selectedMetric.formatWithUnit(values.min() ?? .nan)),
                    (String(localized: "Average"), selectedMetric.formatWithUnit(snapshot.baseline)),
                    (String(localized: "High"), selectedMetric.formatWithUnit(values.max() ?? .nan)),
                ])
            }
        }
    }

    /// Eyebrow, then the metric menu and the range control tight beneath it.
    private func selectedRangeHeader(tint: DomainTint) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            SectionEyebrow(
                title: String(localized: "Selected range"),
                systemImage: selectedMetric.symbol,
                tint: tint,
                trailing: .text(String(localized: "Last \(selectedRange.days) days"))
            )
            rangeControls
        }
    }

    // MARK: - Calendar

    private func calendarSection(_ snapshot: TrendsScreenSnapshot) -> some View {
        let tint = selectedMetric.domainTint(latest: snapshot.selectedPoints.last?.value)
        return VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow(
                title: String(localized: "Calendar"),
                systemImage: "calendar",
                tint: tint,
                trailing: .text(String(localized: "Last 5 weeks"))
            )
            TrendsCalendarHeat(
                days: snapshot.heatDays,
                tint: tint,
                referenceDate: trendReferenceDate,
                calendar: .current,
                valueFormat: selectedMetric.format,
                colorScale: selectedMetric == .recovery ? .recoveryBands : .intensity
            )
            .id("heat-\(selectedMetric.rawValue)-\(selectedRange.rawValue)")
        }
    }

    // MARK: - Weekday

    private func weekdaySection(_ snapshot: TrendsScreenSnapshot) -> some View {
        let tint = selectedMetric.domainTint(latest: snapshot.selectedPoints.last?.value)
        return VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow(
                title: String(localized: "By weekday"),
                systemImage: "chart.bar.xaxis",
                tint: tint,
                trailing: .text(String(localized: "Average · last \(selectedRange.days) days"))
            )
            TrendsWeekdayBars(
                values: snapshot.weekdayAverages,
                tint: tint,
                referenceDate: trendReferenceDate,
                calendar: .current,
                barColor: selectedMetric == .recovery ? { RecoveryBands.color(for: $0) } : nil,
                valueFormat: selectedMetric.formatWithUnit
            )
            .frame(height: 124)
        }
    }

    // MARK: - Scores

    private func scoresSection(series: PaperTrendSeries, previousSeries: PaperTrendSeries) -> some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow(
                title: String(localized: "Scores"),
                systemImage: "chart.line.uptrend.xyaxis",
                tint: .neutral,
                trailing: .text(selectedRange.summarySubtitle)
            )
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                trendSummaryRow(
                    String(localized: "Recovery"),
                    metric: .recovery,
                    points: series.recovery,
                    previousPoints: previousSeries.recovery,
                    goodDirection: .higher,
                    tint: ProductionTrendMetric.recovery.domainTint(latest: series.recovery.last?.value)
                )
                trendSummaryRow(
                    String(localized: "Strain"),
                    metric: .strain,
                    points: series.strain,
                    previousPoints: previousSeries.strain,
                    goodDirection: .neutral,
                    tint: .strain
                )
                trendSummaryRow(
                    String(localized: "Sleep"),
                    metric: .sleepPerformance,
                    points: series.sleep,
                    previousPoints: previousSeries.sleep,
                    goodDirection: .higher,
                    tint: .sleep
                )
                trendSummaryRow(
                    String(localized: "HRV"),
                    metric: .hrv,
                    points: series.hrv,
                    previousPoints: previousSeries.hrv,
                    goodDirection: .higher,
                    tint: .hrv
                )
            }
        }
    }

    private func trendSummaryRow(
        _ label: String,
        metric: ProductionTrendMetric,
        points: [TrendPoint],
        previousPoints: [TrendPoint],
        goodDirection: TrendSummaryGoodDirection,
        tint: DomainTint
    ) -> some View {
        let presentation = TrendSummaryPresentation(
            series: points,
            previousSeries: previousPoints,
            goodDirection: goodDirection,
            expectedCount: selectedRange.days
        )
        let text = TrendsSummaryRowText(metric: metric, presentation: presentation)
        let tone: TrendDeltaTone
        switch text.tone {
        case .positive: tone = .positive
        case .negative: tone = .negative
        case .neutral: tone = .neutral
        }

        return TrendsSummaryRow(
            systemImage: metric.symbol,
            label: label,
            values: presentation.spark.map(\.value),
            latest: text.latest,
            delta: text.delta,
            tone: tone,
            tint: tint
        )
    }

    // MARK: - Controls

    private var rangeControls: some View {
        TrendsControlRow(
            leading: { isCompact in metricMenu(isCompact: isCompact) },
            trailing: { rangePicker }
        )
    }

    private func metricMenu(isCompact: Bool) -> some View {
        let tint = selectedMetric.domainTint(latest: currentScreenSnapshot?.selectedPoints.last?.value)
        return Menu {
            Picker("Metric", selection: $selectedMetric) {
                ForEach(ProductionTrendMetric.allCases) { metric in
                    Label(metric.rawValue, systemImage: metric.symbol).tag(metric)
                }
            }
        } label: {
            TrendsMenuChipLabel(
                title: selectedMetric.rawValue,
                systemImage: selectedMetric.symbol,
                tint: tint.accent,
                isCompact: isCompact
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Metric: \(selectedMetric.rawValue). Opens the metric list")
    }

    /// The canonical segmented pill, announced as one adjustable "Range" control so VoiceOver reads "30 days"
    /// instead of the bare "M".
    private var rangePicker: some View {
        SegmentedPillControl(TrendRange.allCases, selection: $selectedRange) { $0.rawValue }
            .segmentedPillSelectionStyle(.quiet)
            // The selected tab takes the metric's colour, the one the metric chip beside it wears (stable for Recovery:
            // a red band is a state, not a selection).
            .segmentedPillTint(domain: selectedMetric.domainTint(latest: currentScreenSnapshot?.selectedPoints.last?.value))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Range")
            .accessibilityValue("\(selectedRange.days) days")
            .accessibilityAdjustableAction { direction in
                let all = TrendRange.allCases
                guard let index = all.firstIndex(of: selectedRange) else { return }
                switch direction {
                case .increment: selectedRange = all[min(index + 1, all.count - 1)]
                case .decrement: selectedRange = all[max(index - 1, 0)]
                default: break
                }
            }
            // Direct choices for Voice Control and Switch Control, which cannot swipe an adjustable.
            .accessibilityActions {
                ForEach(TrendRange.allCases) { range in
                    Button(String(localized: "Last \(range.days) days")) { selectedRange = range }
                }
            }
    }
}

/// True when a formatted change reads as nothing (every digit is a zero), so it can say "No change" instead of
/// "+0%".
func trendsDeltaIsZero(_ formatted: String) -> Bool {
    let digits = formatted.filter(\.isNumber)
    return !digits.isEmpty && digits.allSatisfy { $0 == "0" }
}
