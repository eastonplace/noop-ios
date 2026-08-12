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
            paperWeekReview(screenSnapshot)
        } else {
            EmptyView()
        }
    }

    private func paperWeekReview(_ snapshot: TrendsScreenSnapshot) -> some View {
        let digest = snapshot.weeklyDigest
        let reviewLines = paperReviewLines(digest)
        let movers = paperMoverRows(digest)
        let insight = paperInsightText(digest, reviewLines: reviewLines)

        return PaperCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Button { stepWeek(-1) } label: {
                        Image(systemName: "chevron.left").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(weekOffset <= minWeekOffset
                        ? StrandPalette.textTertiary
                        : StrandPalette.link)
                    .disabled(weekOffset <= minWeekOffset)
                    .accessibilityLabel("Previous week")

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Weekly readout").strandOverline()
                        Text(weekOffsetLabel)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }

                    Spacer()

                    Text("\(digest.daysWithData)/7 days")
                        .font(StrandFont.micro.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(StrandPalette.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(StrandPalette.surfaceInset, in: Capsule())

                    Button { stepWeek(1) } label: {
                        Image(systemName: "chevron.right").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(weekOffset >= 0
                        ? StrandPalette.textTertiary
                        : StrandPalette.link)
                    .disabled(weekOffset >= 0)
                    .accessibilityLabel("Next week")
                }

                paperScoreTiles(digest)

                if !movers.isEmpty {
                    Text("Biggest changes").strandOverline()
                    VStack(spacing: 9) {
                        ForEach(movers, id: \.metric.rawValue) { summary in
                            HStack(spacing: 9) {
                                Circle()
                                    .fill(paperMoverAccent(summary.metric))
                                    .frame(width: 7, height: 7)
                                Text(summary.metric.label)
                                    .font(StrandFont.caption.weight(.semibold))
                                    .foregroundStyle(StrandPalette.textPrimary)
                                if summary.isRoughComparison {
                                    Text("early read")
                                        .font(StrandFont.micro)
                                        .foregroundStyle(StrandPalette.textTertiary)
                                }
                                Spacer(minLength: 8)
                                Text(paperMoverValue(summary))
                                    .font(StrandFont.captionNumber.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text(paperMoverDelta(summary))
                                    .font(StrandFont.micro.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(paperMoverTone(summary))
                                    .frame(minWidth: 50, alignment: .trailing)
                            }
                        }
                    }
                }

                if let consistency = digest.sleepConsistencySD {
                    Label(
                        "Sleep score variability ±\(ProductionTrendMetric.sleepPerformance.format(consistency)) points",
                        systemImage: "moon.zzz"
                    )
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                }

                Divider().overlay(StrandPalette.hairline)

                ForEach(Array(reviewLines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 9) {
                        Circle()
                            .fill(reviewDotColor(for: line))
                            .frame(width: 7, height: 7)
                            .padding(.top, 6)
                        Text(line)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.link)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Insight").strandOverline()
                        Text(insight)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .background(
                    StrandPalette.surfaceInset,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }
        }
    }

    private func paperScoreTiles(_ digest: WeeklyDigest) -> some View {
        HStack(alignment: .top, spacing: 8) {
            paperScoreTile(
                .charge,
                digest: digest,
                accent: digest.summary(.charge).flatMap { summary in
                    summary.thisWeek.n > 0
                        ? RecoveryBands.color(for: summary.thisWeek.mean)
                        : nil
                } ?? StrandPalette.recoveryData
            )
            paperScoreTile(.effort, digest: digest, accent: StrandPalette.strainAccent)
            paperScoreTile(.rest, digest: digest, accent: StrandPalette.sleepAccent)
        }
    }

    private func paperScoreTile(
        _ metric: WeeklyMetric,
        digest: WeeklyDigest,
        accent: Color
    ) -> some View {
        let summary = digest.summary(metric)
        let hasValue = (summary?.thisWeek.n ?? 0) > 0
        let mean = summary?.thisWeek.mean ?? 0
        let value: String = hasValue
            ? weeklyMetricValue(metric, value: mean)
            : "—"
        let delta = summary?.wowDelta ?? 0
        let sign = delta >= 0 ? "+" : "−"

        return PaperCard(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(metric.label))
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(accent)
                Text(value)
                    .font(StrandFont.statValue)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(hasValue
                    ? "\(sign)\(weeklyMetricDelta(metric, value: abs(delta))) vs last week"
                    : "No data this week")
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
        }
    }

    private func paperReviewLines(_ digest: WeeklyDigest) -> [String] {
        let lines = Array(digest.focalPoints.prefix(3))
        return lines.isEmpty ? [digest.balance.sentence] : lines
    }

    private func paperInsightText(_ digest: WeeklyDigest, reviewLines: [String]) -> String {
        let candidates = [digest.balance.sentence] + digest.focalPoints
        return candidates.first(where: { !reviewLines.contains($0) })
            ?? String(localized: "Keep logging this week. The next distinct pattern will appear as soon as it clears the weekly signal threshold.")
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

    private func paperMoverAccent(_ metric: WeeklyMetric) -> Color {
        switch metric {
        case .charge: StrandPalette.recoveryData
        case .effort: StrandPalette.strainAccent
        case .rest: StrandPalette.sleepAccent
        case .rhr: StrandPalette.metricRose
        case .hrv: StrandPalette.metricPurple
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

    private func paperMoverDelta(_ summary: WeeklyMetricSummary) -> String {
        let delta = summary.wowDelta
        let magnitude: String
        switch summary.metric {
        case .effort: magnitude = StrainScale.formattedDelta(abs(delta))
        case .rhr: magnitude = ProductionTrendMetric.restingHR.formatWithUnit(abs(delta))
        case .hrv: magnitude = ProductionTrendMetric.hrv.formatWithUnit(abs(delta))
        case .charge: magnitude = ProductionTrendMetric.recovery.format(abs(delta))
        case .rest: magnitude = ProductionTrendMetric.sleepPerformance.format(abs(delta))
        }
        return "\(delta >= 0 ? "+" : "−")\(magnitude)"
    }

    private func paperMoverTone(_ summary: WeeklyMetricSummary) -> Color {
        guard !summary.isRoughComparison else { return StrandPalette.textTertiary }
        switch summary.wowGoodness {
        case 1: return StrandPalette.statusPositive
        case -1: return StrandPalette.statusCritical
        default: return StrandPalette.textSecondary
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
