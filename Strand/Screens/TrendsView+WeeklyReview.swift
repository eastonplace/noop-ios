import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

extension TrendsView {

    @ViewBuilder
    var paperWeekReview: some View {
        if let screenSnapshot = currentScreenSnapshot {
            trendsSeparator
            paperWeekReview(screenSnapshot)
        } else {
            EmptyView()
        }
    }

    private func paperWeekReview(_ snapshot: TrendsScreenSnapshot) -> some View {
        let digest = snapshot.weeklyDigest
        let reviewLines = paperReviewLines(digest)
        let movers = paperMoverRows(digest)
        let insight = paperInsight(digest, reviewLines: reviewLines)

        return VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow(
                title: String(localized: "Weekly readout"),
                systemImage: "chart.bar.doc.horizontal",
                tint: .accent,
                trailing: .pill("\(digest.daysWithData)/7 days", tone: .neutral)
            )

            weekStepper

            TrendsWeekColumns(items: [
                paperWeekItem(.charge, digest: digest),
                paperWeekItem(.effort, digest: digest),
                paperWeekItem(.rest, digest: digest),
            ])

            if !movers.isEmpty {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Text("Biggest changes")
                        .font(StrandFont.micro)
                        .foregroundStyle(StrandPalette.textTertiary)
                    VStack(spacing: NoopMetrics.space2) {
                        ForEach(movers, id: \.metric.rawValue) { summary in
                            TrendsMoverRow(
                                systemImage: paperMoverSymbol(summary.metric),
                                label: summary.metric.label,
                                isEarlyRead: summary.isRoughComparison,
                                value: paperMoverValue(summary),
                                delta: paperMoverDelta(summary),
                                tone: paperMoverTone(summary),
                                tint: paperMoverTint(summary)
                            )
                        }
                    }
                }
                .padding(.top, NoopMetrics.space1)
            }

            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("Highlights")
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                ForEach(Array(reviewLines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                        Circle()
                            .fill(reviewDotColor(for: line))
                            .frame(width: 6, height: 6)
                            .alignmentGuide(.firstTextBaseline) { dimensions in dimensions[VerticalAlignment.center] + 4 }
                            .accessibilityHidden(true)
                        Text(line)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let consistency = digest.sleepConsistencySD {
                    Label(
                        "Sleep score variability ±\(ProductionTrendMetric.sleepPerformance.format(consistency)) points",
                        systemImage: "moon.zzz"
                    )
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .padding(.top, NoopMetrics.space1)
                }
            }
            .padding(.top, NoopMetrics.space1)

            WidgetCard(
                title: insight.fromCoach ? String(localized: "Coach insight") : String(localized: "Insight"),
                systemImage: "sparkles",
                tint: .accent
            ) {
                Text(insight.text)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, NoopMetrics.space1)
        }
    }

    /// Previous / next week as two chip chevrons around the week's name.
    private var weekStepper: some View {
        HStack(spacing: 0) {
            Button { stepWeek(-1) } label: {
                TrendsStepChipLabel(systemImage: "chevron.left", isEnabled: weekOffset > minWeekOffset)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(weekOffset <= minWeekOffset)
            .accessibilityLabel("Previous week")

            Text(weekOffsetLabel)
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)

            Button { stepWeek(1) } label: {
                TrendsStepChipLabel(systemImage: "chevron.right", isEnabled: weekOffset < 0)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(weekOffset >= 0)
            .accessibilityLabel("Next week")
        }
        .padding(.vertical, -9)
    }

    private func paperWeekItem(_ metric: WeeklyMetric, digest: WeeklyDigest) -> TrendsWeekColumns.Item {
        let summary = digest.summary(metric)
        let hasValue = (summary?.thisWeek.n ?? 0) > 0
        let mean = summary?.thisWeek.mean ?? 0
        let delta = summary?.wowDelta ?? 0
        let sign = delta >= 0 ? "+" : "−"
        let deltaMagnitude = weeklyMetricDelta(metric, value: abs(delta))
        // With no readings last week the engine reports this week's mean as the "change". That is not a change.
        let hasPrior = (summary?.weekOverWeek.previous.n ?? 0) > 0
        let unchanged = hasValue && hasPrior && trendsDeltaIsZero(deltaMagnitude)
        let tone: TrendDeltaTone
        if hasValue, hasPrior, !unchanged, let summary, !summary.isRoughComparison, metric != .effort {
            switch summary.wowGoodness {
            case 1: tone = .positive
            case -1: tone = .negative
            default: tone = .neutral
            }
        } else {
            tone = .neutral
        }
        let tint: DomainTint
        let symbol: String
        switch metric {
        case .charge:
            tint = .recovery(score: hasValue ? mean : nil)
            symbol = "heart.fill"
        case .effort:
            tint = .strain
            symbol = "flame.fill"
        case .rest:
            tint = .sleep
            symbol = "moon.stars.fill"
        case .rhr:
            tint = .heart
            symbol = "heart.fill"
        case .hrv:
            tint = .hrv
            symbol = "waveform.path.ecg"
        }
        return TrendsWeekColumns.Item(
            id: metric.rawValue,
            systemImage: symbol,
            label: metric.label,
            value: hasValue ? weeklyMetricValue(metric, value: mean) : WidgetMetrics.missingValue,
            delta: !hasValue
                ? String(localized: "No data this week")
                : !hasPrior ? String(localized: "No prior week")
                : unchanged ? String(localized: "Flat vs last week")
                : String(localized: "\(sign + deltaMagnitude) vs last week"),
            tone: tone,
            tint: tint
        )
    }

    private func paperReviewLines(_ digest: WeeklyDigest) -> [String] {
        WeeklyDigestEngine.highlightLines(
            for: digest, effortDisplayFactor: UnitPrefs.currentEffortDisplayFactor())
    }

    /// The on-device Coach's takeaway for the displayed week when it has written one, else a deterministic
    /// rule-based line. Never empty.
    private func paperInsight(_ digest: WeeklyDigest, reviewLines: [String]) -> (text: String, fromCoach: Bool) {
        if let stored = coachInsight, stored.weekStart == digest.weekStart, !stored.text.isEmpty {
            return (stored.text, true)
        }
        return (WeeklyDigestEngine.insightLine(
            for: digest, highlights: reviewLines,
            effortDisplayFactor: UnitPrefs.currentEffortDisplayFactor()), false)
    }

    private func reviewDotColor(for line: String) -> Color {
        let lowered = line.lowercased()
        if lowered.contains("recovery") || lowered.contains("hrv") {
            return StrandPalette.recoveryData
        }
        if lowered.contains("strain") { return StrandPalette.strainAccent }
        if lowered.contains("sleep") { return StrandPalette.sleepAccent }
        if lowered.contains("stress") { return StrandPalette.stressAccent }
        return StrandPalette.textTertiary
    }

    private func paperMoverRows(_ digest: WeeklyDigest) -> [WeeklyMetricSummary] {
        Array(
            digest.metrics
                .filter { $0.weekOverWeek.current.n > 0 && $0.weekOverWeek.previous.n > 0 }
                .sorted { abs($0.normalisedMove) > abs($1.normalisedMove) }
                .prefix(3)
        )
    }

    private func paperMoverSymbol(_ metric: WeeklyMetric) -> String {
        switch metric {
        case .charge: "heart.fill"
        case .effort: "flame.fill"
        case .rest: "moon.stars.fill"
        case .rhr: "heart.fill"
        case .hrv: "waveform.path.ecg"
        }
    }

    private func paperMoverTint(_ summary: WeeklyMetricSummary) -> DomainTint {
        switch summary.metric {
        case .charge: .recovery(score: summary.thisWeek.n > 0 ? summary.thisWeek.mean : nil)
        case .effort: .strain
        case .rest: .sleep
        case .rhr: .heart
        case .hrv: .hrv
        }
    }

    private func paperMoverValue(_ summary: WeeklyMetricSummary) -> String {
        let value = summary.thisWeek.mean
        switch summary.metric {
        case .effort: return StrainScale.formatted(value)
        case .rhr: return ProductionTrendMetric.restingHR.formatWithUnit(value)
        case .hrv: return ProductionTrendMetric.hrv.formatWithUnit(value)
        case .charge: return ProductionTrendMetric.recovery.format(value)
        case .rest: return ProductionTrendMetric.sleepPerformance.format(value)
        }
    }

    private func paperMoverMagnitude(_ summary: WeeklyMetricSummary) -> String {
        let delta = abs(summary.wowDelta)
        switch summary.metric {
        case .effort: return StrainScale.formattedDelta(delta)
        case .rhr: return ProductionTrendMetric.restingHR.formatWithUnit(delta)
        case .hrv: return ProductionTrendMetric.hrv.formatWithUnit(delta)
        case .charge: return ProductionTrendMetric.recovery.format(delta)
        case .rest: return ProductionTrendMetric.sleepPerformance.format(delta)
        }
    }

    private func paperMoverDelta(_ summary: WeeklyMetricSummary) -> String {
        let magnitude = paperMoverMagnitude(summary)
        if trendsDeltaIsZero(magnitude) { return String(localized: "No change") }
        return (summary.wowDelta >= 0 ? "+" : "−") + magnitude
    }

    /// A move that rounds to nothing carries no colour: "No change" is neither good nor bad.
    private func paperMoverTone(_ summary: WeeklyMetricSummary) -> StrandTone {
        guard !summary.isRoughComparison, summary.metric != .effort, !trendsDeltaIsZero(paperMoverMagnitude(summary)) else { return .neutral }
        switch summary.wowGoodness {
        case 1: return .positive
        case -1: return .critical
        default: return .neutral
        }
    }

    private func weeklyMetricValue(_ metric: WeeklyMetric, value: Double) -> String {
        switch metric {
        case .effort: return StrainScale.formatted(value)
        case .rhr: return ProductionTrendMetric.restingHR.formatWithUnit(value)
        case .hrv: return ProductionTrendMetric.hrv.formatWithUnit(value)
        case .charge: return ProductionTrendMetric.recovery.format(value)
        case .rest: return ProductionTrendMetric.sleepPerformance.format(value)
        }
    }

    private func weeklyMetricDelta(_ metric: WeeklyMetric, value: Double) -> String {
        switch metric {
        case .effort: return StrainScale.formattedDelta(value)
        case .rhr: return ProductionTrendMetric.restingHR.formatWithUnit(value)
        case .hrv: return ProductionTrendMetric.hrv.formatWithUnit(value)
        case .charge: return ProductionTrendMetric.recovery.format(value)
        case .rest: return ProductionTrendMetric.sleepPerformance.format(value)
        }
    }

    private var minWeekOffset: Int {
        TrendsBounds.clampWeekOffset(currentScreenSnapshot?.minimumWeekOffset ?? 0)
    }

    private func stepWeek(_ delta: Int) {
        let current = TrendsBounds.clampWeekOffset(weekOffset)
        let (candidate, overflow) = current.addingReportingOverflow(delta)
        let safeCandidate = overflow ? (delta < 0 ? Int.min : Int.max) : candidate
        weekOffset = max(minWeekOffset, TrendsBounds.clampWeekOffset(safeCandidate))
    }

    private var weekOffsetLabel: String {
        let weeksAgo = -TrendsBounds.clampWeekOffset(weekOffset)
        if weeksAgo == 0 { return String(localized: "This week") }
        if weeksAgo == 1 { return String(localized: "Last week") }
        return String(localized: "\(weeksAgo) weeks ago")
    }
}
