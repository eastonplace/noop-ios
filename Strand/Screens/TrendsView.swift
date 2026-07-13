import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Trends
//
// The weekly longitudinal view, rendered only through the canonical Paper score tiles,
// over-time chart, Week in Review card, and distinct insight.

struct TrendsView: View {
    @EnvironmentObject var repo: Repository
    // NOTE: deliberately does NOT observe LiveState — Trends shows historical data only, and
    // observing it forced a full re-render of this subtree on every ~1 Hz live-HR tick.

    // #436 — shareable offline trends report (PDF over a date range). The sheet owns its
    // own range picker; this just presents it with the loaded history.
    @State private var showingReport = false

    /// Sleep's per-day series, keyed by "yyyy-MM-dd". Sleep is the sleep_performance COMPOSITE (the same
    /// number the Today Sleep score + the Sleep Sleep-detail plot, #614 follow-up) — NOT raw efficiency,
    /// which read differently under the same "Sleep" label and made the Trends Sleep graph disagree with
    /// the Today Sleep score (#732). sleep_performance is a metricSeries, not a DailyMetric field, so load
    /// it once (mirroring TodayView's restScore source) and key by day for `resolve` below.
    @State private var sleepPerfByDay: [String: Double] = [:]
    // Original #710 wiring restored by E6: the Paper review card browses the same engine-backed
    // Mon-Sun digests as the pre-reskin screen; 0 is the current week and negatives step backward.
    @State private var weekOffset: Int

    init(initialWeekOffset: Int = 0) {
        _weekOffset = State(initialValue: min(0, initialWeekOffset))
    }

    // yyyy-MM-dd → Date (en_US_POSIX, UTC), per task spec.
    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private func date(_ day: String) -> Date? { Self.dayParser.date(from: day) }

    var body: some View {
        // The liquid metric cards now tap through to their MetricDetailView (matching Today's card
        // taps + Explore's rows). On iOS each tab already supplies a NavigationStack, so those pushes
        // land in the ambient stack. On macOS the .trends detail pane has NO enclosing NavigationStack
        // (RootView), so — exactly like MetricExplorerView (#753) — wrap the scaffold in one here so the
        // pushes get Back chrome instead of hanging. The SAME shared scaffold renders on both.
        #if os(macOS)
        NavigationStack { scaffold }
        #else
        scaffold
        #endif
    }

    private var scaffold: some View {
        ScreenScaffold(title: LocalizedStringKey(weekOffsetLabel), subtitle: LocalizedStringKey(paperWeekRangeLabel),
                       // PERF (scroll): lazy column — byte-identical layout (LazyVStack == eager VStack
                       // alignment/spacing/header). The content is one inner eager VStack, so the staggered
                       // section reveal is unchanged; this only defers building that stack until it scrolls in.
                       onRefresh: { await repo.refresh() },
                       lazy: true,
                       topBackground: nil,
                       trailing: {
                           HStack(spacing: 12) {
                               Image(systemName: "calendar")
                               Button { showingReport = true } label: { Image(systemName: "square.and.arrow.up") }
                                   .buttonStyle(.plain)
                           }
                           .font(.system(size: 15, weight: .medium))
                           .foregroundStyle(StrandPalette.textPrimary)
                       }) {
            if repo.days.isEmpty {
                ComingSoon(what: repo.loaded
                    ? "Trends need history to draw. Import your WHOOP export in Data Sources to see weeks, months and years instantly."
                    : "Loading your history…")
            } else {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                    paperScoreTiles
                    paperScoresOverTime
                    paperWeekReview
                    paperInsight
                }
            }
        }
        // #436 — present the offline trends-report exporter (range picker + PDF export).
        .sheet(isPresented: $showingReport) {
            TrendsReportSheet(days: repo.days)
        }
        // #732 — load the resolved sleep_performance series so Sleep plots the SAME composite the Today
        // Sleep score uses (not raw efficiency). Mirrors TodayView's restScore read. Keyed on the day
        // count so a newly-banked/-scored night refreshes Sleep reactively, like the other metrics that
        // read `repo.days` directly (and like the Android LaunchedEffect(days) twin).
        .task(id: repo.days.count) {
            let s = await repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
            sleepPerfByDay = Dictionary(s.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        }
    }

    // MARK: - Paper Trends (S2)

    private var paperDigest: WeeklyDigest {
        WeeklyDigestSource.digest(from: repo.days, anchorDay: weekAnchorDay)
    }

    private var paperWeekDays: [DailyMetric] {
        let digest = paperDigest
        return repo.days.filter { $0.day >= digest.weekStart && $0.day <= digest.weekEnd }
    }

    private var paperWeekDates: [Date] { paperWeekDays.compactMap { date($0.day) } }

    private var paperWeekRangeLabel: String {
        let digest = paperDigest
        guard let start = date(digest.weekStart), let end = date(digest.weekEnd) else { return "" }
        let f = DateFormatter(); f.locale = Locale.current; f.setLocalizedDateFormatFromTemplate("MMM d")
        return "\(f.string(from: start)) — \(f.string(from: end))"
    }

    private var paperScoreTiles: some View {
        HStack(alignment: .top, spacing: 8) {
            paperScoreTile(
                .charge,
                accent: paperDigest.summary(.charge).flatMap { summary in
                    summary.thisWeek.n > 0 ? RecoveryBands.color(for: summary.thisWeek.mean) : nil
                } ?? StrandPalette.recoveryData
            )
            paperScoreTile(.effort, accent: StrandPalette.strainAccent)
            paperScoreTile(.rest, accent: StrandPalette.sleepAccent)
        }
    }

    private func paperScoreTile(_ metric: WeeklyMetric, accent: Color) -> some View {
        let summary = paperDigest.summary(metric)
        let hasValue = (summary?.thisWeek.n ?? 0) > 0
        let mean = summary?.thisWeek.mean ?? 0
        let value: String = hasValue
            ? (metric == .effort ? StrainScale.formatted(mean) : "\(Int(mean.rounded()))")
            : "—"
        let delta = summary?.wowDelta ?? 0
        let sign = delta >= 0 ? "+" : "−"
        return PaperCard(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(metric.label))
                    .font(StrandFont.caption.weight(.semibold)).foregroundStyle(accent)
                Text(value).font(StrandFont.statValue).foregroundStyle(StrandPalette.textPrimary)
                Text(hasValue
                     ? "\(sign)\(metric == .effort ? StrainScale.formattedDelta(abs(delta)) : "\(Int(abs(delta).rounded()))") vs last week"
                     : "No data this week")
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
        }
    }

    private var paperScoresOverTime: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Scores Over Time").strandOverline()
                HStack(spacing: 12) {
                    paperLegend("Recovery", color: StrandPalette.recoveryData)
                    paperLegend("Strain", color: StrandPalette.strainAccent)
                    paperLegend("Sleep", color: StrandPalette.sleepAccent)
                }
                ZStack {
                    Chart {
                        ForEach(paperWeekDays, id: \.day) { day in
                            if let value = day.recovery, let date = date(day.day) {
                                LineMark(x: .value("Day", date), y: .value("Recovery", value))
                                    .lineStyle(StrokeStyle(lineWidth: NoopMetrics.chartLineWidth,
                                                           lineCap: .round, lineJoin: .round))
                                    .foregroundStyle(by: .value("Series", "Recovery"))
                                PointMark(x: .value("Day", date), y: .value("Recovery", value))
                                    .foregroundStyle(RecoveryBands.color(for: value)).symbolSize(12)
                            }
                            if let value = sleepPerfByDay[day.day], let date = date(day.day) {
                                LineMark(x: .value("Day", date), y: .value("Sleep", value))
                                    .lineStyle(StrokeStyle(lineWidth: NoopMetrics.chartLineWidth,
                                                           lineCap: .round, lineJoin: .round))
                                    .foregroundStyle(by: .value("Series", "Sleep"))
                                PointMark(x: .value("Day", date), y: .value("Sleep", value))
                                    .foregroundStyle(StrandPalette.sleepAccent).symbolSize(12)
                            }
                        }
                    }
                    .chartForegroundStyleScale(domain: ["Recovery", "Sleep"],
                                               range: [StrandPalette.recoveryData,
                                                       StrandPalette.sleepAccent])
                    .chartLegend(.hidden)
                    .chartYScale(domain: 0...100)
                    .chartXAxis {
                        AxisMarks(values: paperWeekDates) { _ in
                            AxisValueLabel(format: .dateTime.weekday(.narrow).day())
                                .font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: [0, 50, 100]) { _ in
                            AxisGridLine().foregroundStyle(StrandPalette.hairline)
                            AxisValueLabel().font(StrandFont.micro)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        AxisMarks(position: .trailing, values: [0, 7, 14, 21]) { value in
                            AxisValueLabel {
                                Text(value.as(Int.self).map(String.init) ?? "")
                            }
                            .font(StrandFont.micro).foregroundStyle(Color.clear)
                        }
                    }

                    Chart {
                        ForEach(paperWeekDays, id: \.day) { day in
                            if let stored = day.strain, let date = date(day.day) {
                                let value = StrainScale.displayValue(fromStored: stored)
                                LineMark(x: .value("Day", date), y: .value("Strain", value))
                                    .lineStyle(StrokeStyle(lineWidth: NoopMetrics.chartLineWidth,
                                                           lineCap: .round, lineJoin: .round))
                                    .foregroundStyle(StrandPalette.strainAccent)
                                PointMark(x: .value("Day", date), y: .value("Strain", value))
                                    .foregroundStyle(StrandPalette.strainAccent).symbolSize(12)
                            }
                        }
                    }
                    .chartYScale(domain: StrainScale.displayRange)
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                            AxisValueLabel {
                                Text(value.as(Int.self).map(String.init) ?? "")
                            }
                            .font(StrandFont.micro).foregroundStyle(Color.clear)
                        }
                        AxisMarks(position: .trailing, values: [0, 7, 14, 21]) { _ in
                            AxisValueLabel().font(StrandFont.micro)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                }
                .frame(height: NoopMetrics.chartHeight)
            }
        }
    }

    private func paperLegend(_ title: LocalizedStringKey, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(StrandFont.micro).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private var paperReviewLines: [String] {
        // Craft pass (003): the balance sentence renders in the Insight card, so it must NOT
        // also appear as a review bullet — same copy twice on one screen reads broken.
        let digest = paperDigest
        let lines = Array(digest.focalPoints.prefix(3))
        return lines.isEmpty ? [digest.balance.sentence] : lines
    }

    /// Insight only renders when it adds something the bullets don't already say.
    private var paperInsightIsDistinct: Bool {
        !paperReviewLines.contains(paperDigest.balance.sentence)
    }

    /// Bullet dot tinted by the pillar the sentence is about (board v2's colored review dots);
    /// neutral when no pillar is named.
    private func reviewDotColor(for line: String) -> Color {
        let l = line.lowercased()
        if l.contains("recovery") || l.contains("hrv") { return StrandPalette.recoveryData }
        if l.contains("strain") { return StrandPalette.strainAccent }
        if l.contains("sleep") { return StrandPalette.sleepAccent }
        if l.contains("stress") { return StrandPalette.stressAccent }
        return StrandPalette.textTertiary
    }

    private var paperWeekReview: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button { stepWeek(-1) } label: {
                        Image(systemName: "chevron.left").frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(weekOffset <= minWeekOffset ? StrandPalette.textTertiary : StrandPalette.link)
                    .disabled(weekOffset <= minWeekOffset)
                    .accessibilityLabel("Previous week")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Week in Review").strandOverline()
                        Text(weekOffsetLabel).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer()
                    Button { stepWeek(1) } label: {
                        Image(systemName: "chevron.right").frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(weekOffset >= 0 ? StrandPalette.textTertiary : StrandPalette.link)
                    .disabled(weekOffset >= 0)
                    .accessibilityLabel("Next week")
                }
                ForEach(Array(paperReviewLines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .top, spacing: 9) {
                        Circle().fill(reviewDotColor(for: line))
                            .frame(width: 8, height: 8).padding(.top, 5)
                        Text(line).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var minWeekOffset: Int {
        guard let earliest = repo.days.first?.day,
              let earliestMonday = WeeklyDigestEngine.mondayOfWeek(containing: earliest),
              let thisMonday = WeeklyDigestEngine.mondayOfWeek(containing: Repository.localDayKey(Date()))
        else { return 0 }
        var offset = 0
        var monday = thisMonday
        while monday > earliestMonday && offset > -520 {
            monday = WeeklyDigestEngine.addDays(monday, -7)
            offset -= 1
        }
        return offset
    }

    private var weekAnchorDay: String {
        WeeklyDigestEngine.addDays(Repository.localDayKey(Date()), weekOffset * 7)
    }

    private func stepWeek(_ delta: Int) {
        weekOffset = max(minWeekOffset, min(0, weekOffset + delta))
    }

    private var weekOffsetLabel: String {
        let weeksAgo = -weekOffset
        if weeksAgo == 0 { return String(localized: "This week") }
        if weeksAgo == 1 { return String(localized: "Last week") }
        return String(localized: "\(weeksAgo) weeks ago")
    }

    @ViewBuilder private var paperInsight: some View {
        if paperInsightIsDistinct {
            InsightCard(symbol: "sparkles", title: "Insight",
                        body: LocalizedStringKey(paperDigest.balance.sentence), accent: StrandPalette.link)
        }
    }

}

#if DEBUG
@MainActor
private func previewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    let cal = Calendar(identifier: .gregorian)
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(identifier: "UTC")
    fmt.dateFormat = "yyyy-MM-dd"
    let today = Date()
    var seeded: [DailyMetric] = []
    let span = 365 * 3
    for i in stride(from: span - 1, through: 0, by: -1) {
        guard let d = cal.date(byAdding: .day, value: -i, to: today) else { continue }
        let phase = Double(span - 1 - i)
        let rec = 55 + 28 * sin(phase / 11.0) + Double((Int(phase) * 31) % 17) - 8
        let hrv = 58 + 16 * sin(phase / 9.0) + Double((Int(phase) * 13) % 11) - 5
        let rhr = 52 + 4 * sin(phase / 7.0) + Double((Int(phase) * 7) % 5) - 2
        let strain = 9 + 6 * sin(phase / 5.0 + 1.2) + Double((Int(phase) * 5) % 4) - 2
        let gap = Int(phase) % 23 == 0
        seeded.append(DailyMetric(
            day: fmt.string(from: d),
            totalSleepMin: 420, efficiency: 0.9, deepMin: 90, remMin: 110, lightMin: 200,
            disturbances: 6, restingHr: gap ? nil : Int(rhr.rounded()),
            avgHrv: gap ? nil : max(15, hrv), recovery: gap ? nil : max(2, min(99, rec)),
            strain: gap ? nil : max(0, min(21, strain)), exerciseCount: 1
        ))
    }
    repo.days = seeded
    repo.loaded = true
    return repo
}

#Preview("Trends") {
    TrendsView()
        .environmentObject(previewRepo())
        .environmentObject(LiveState())
        .frame(width: 960, height: 960)
        .preferredColorScheme(.dark)
}
#endif
