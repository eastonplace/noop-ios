import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Deep Timeline (full-day, full-resolution metric viewer) — #575
//
// The headline tap-through from Explore: a whole-day line for one metric that the user can ZOOM and PAN
// down to the raw per-second signal. The hard problem — never drawing ~86k points for a worn 24h — is
// solved in the read layer (`Repository.timelineSeries` picks coarse SQL buckets at day scale and raw
// seconds when zoomed in), so this screen only ever receives ~targetPoints points regardless of zoom.
//
// Reuses the existing `OverviewHRChart` (its `.chartXScale(domain:)` already pins the axis); the chart's
// zoom binding drives the visible window, and re-reads at the new resolution as the window changes. macOS
// adds scroll-to-zoom (no pinch); both platforms drag-to-pan. Serves #574 (owned-source filter / honest
// "Other sources" disclosure) and is the detail surface behind #582.
//
// #979 spin-offs: (1) annotation parity with the classic Today whole-day chart — the main night's sleep
// band + a sport glyph at each workout, fed through the SAME OverviewHRChart layers Today uses (this
// screen previously drew a bare line, despite being sold as "the whole-day trend with bands"); (2) an
// iPhone touch-and-hold scrub (`touchScrub: true`) so the crosshair readout the Mac pointer hover gets
// is reachable on touch too.

struct FullDayChartView: View {
    @EnvironmentObject var repo: Repository

    /// The day this timeline is showing (its real calendar midnight). Defaults to the logical day so an
    /// after-midnight open still lands on the night the user is living, not an empty new calendar day (#144).
    /// Mutable so the user can step back through previous days (#597 — was today-only with no way back).
    @State private var dayStart: Date
    /// True once we've done the one-shot "open on the most recent day with data" jump (or the caller pinned
    /// an explicit day, in which case we never override it). Stops the jump from fighting manual navigation.
    @State private var didLandOnLatest: Bool

    init(dayStart: Date? = nil) {
        _dayStart = State(initialValue: dayStart ?? Repository.logicalDayStart(Date()))
        _didLandOnLatest = State(initialValue: dayStart != nil)
    }

    @State private var metric: Repository.TimelineMetric = .hr
    /// "Owned only" hides empty non-strap rows; "All sources" surfaces the disclosure (#574). The strap is
    /// always the owned source, so this currently scopes the empty-state copy rather than swapping reads.
    @State private var ownedOnly = true

    @State private var series: Repository.TimelineSeries = .empty
    /// Seconds a DAY spent resting / steady / pushing, read once per day at a fixed one-minute resolution so the
    /// totals never depend on how far the chart is zoomed. They carry the day they were read for, and only the shown
    /// day's are drawn: stepping to another day shows no totals until its own land, never the last day's under it.
    @State private var zoneTotals: ZoneTotals?
    // #979 spin-off — day annotations, mirroring the classic Today's Overview HR markers: the main
    // night's band (labelled with its duration) and each workout's sport glyph. Day-scoped facts, so
    // they're loaded per shown day (NOT per zoom window — the chart clamps them into the visible
    // window itself), keeping the zoom/pan re-read path untouched.
    @State private var sleepSpan: OverviewHRChart.SleepSpan? = nil
    @State private var workoutSpans: [OverviewHRChart.WorkoutSpan] = []
    /// The visible window the chart's gestures mutate. nil → full day (the chart falls back to `dayBounds`).
    @State private var zoomDomain: ClosedRange<Date>? = nil
    @State private var loading = true
    /// Bumped on every settled zoom/metric change so the re-read task re-runs at the new resolution.
    @State private var reloadTick = 0

    private var nextDayStart: Date {
        Repository.dateByAddingCalendarDays(1, to: dayStart)
    }

    /// The full clamp the zoom window can never escape — the selected calendar day.
    private var dayBounds: ClosedRange<Date> {
        dayStart...nextDayStart
    }

    /// #986: a continuous left-drag can scroll back to the shown day plus the two before it (a rolling
    /// 3-day window), so older HR is reachable by dragging, not only the day-stepper. Deliberately bounded
    /// so one drag can't fling through weeks. The default view is still exactly one day (xRange: dayBounds);
    /// this only widens the pan clamp, and the data reload keys on the visible window so panned-to days load.
    private var panBounds: ClosedRange<Date> {
        Repository.dateByAddingCalendarDays(-2, to: dayStart)...nextDayStart
    }

    /// The currently-visible window (zoomed or the whole day).
    private var visibleWindow: ClosedRange<Date> { zoomDomain ?? dayBounds }

    var body: some View {
        ScreenScaffold(title: "Deep Timeline") {
            // Flat sections with one hairline between them, like Today and Trends: the timeline (its controls
            // under the eyebrow, the chart in the Live HR module's language), the time in range, the source.
            VStack(alignment: .leading, spacing: 0) {
                timelineSection
                if metric == .hr, shownZoneSeconds.reduce(0, +) > 0 {
                    DrillInSeparator()
                    zonesSection
                }
                DrillInSeparator()
                sourceSection
            }
        }
        .task(id: taskKey) { await reload() }
        .task(id: zonesKey) { await reloadZones() }
        .task(id: annotationKey) { await reloadAnnotations() }
        .task { await landOnLatestDayIfNeeded() }
    }


    /// Annotations re-read only when the shown day changes or fresh strap data lands — deliberately NOT
    /// on zoom (see `sleepSpan` above), so scrubbing/pinching never re-queries sleeps/workouts.
    private var annotationKey: String {
        "\(Int(dayStart.timeIntervalSince1970))|\(repo.refreshSeq)"
    }

    /// Re-read whenever the metric, the day, the source scope, the settled zoom window, or fresh strap
    /// data changes. The window is bucketed to whole seconds so micro-jitter during a drag doesn't thrash
    /// the DB — the chart redraws smoothly from the in-hand domain while the data settles.
    private var taskKey: String {
        let lo = Int(visibleWindow.lowerBound.timeIntervalSince1970)
        let hi = Int(visibleWindow.upperBound.timeIntervalSince1970)
        return "\(metric.rawValue)|\(Int(dayStart.timeIntervalSince1970))|\(ownedOnly)|\(lo)|\(hi)|\(repo.refreshSeq)|\(reloadTick)"
    }

    /// Time in range is a fact about the day: it re-reads when the day, the source scope or fresh strap data changes,
    /// and deliberately not when the window moves.
    private var zonesKey: String {
        "\(metric == .hr)|\(Int(dayStart.timeIntervalSince1970))|\(ownedOnly)|\(repo.refreshSeq)"
    }

    // MARK: Controls

    private var metricSymbol: String { symbol(for: metric) }

    private func symbol(for metric: Repository.TimelineMetric) -> String {
        switch metric {
        case .hr: return "heart.fill"
        case .hrv: return "waveform.path.ecg"
        case .spo2: return "drop.fill"
        case .skinTemp: return "thermometer.medium"
        case .respiration: return "lungs.fill"
        case .motion: return "figure.walk"
        case .bandSleepState: return "bed.double.fill"
        }
    }

    /// The metric's own ink: the heart's live red for heart rate, else the Deep Timeline's per-metric colour.
    private var metricInk: Color { timelineTint ?? StrandPalette.liveRed }

    /// The metric menu and the day stepper on one tight row under the eyebrow (Trends' control row): at larger
    /// text, or when a long metric name leaves no room, the stepper drops under the chip instead of truncating.
    private var controlRow: some View {
        TrendsControlRow(
            leading: { isCompact in metricMenu(isCompact: isCompact) },
            trailing: { dayStepper }
        )
    }

    private func metricMenu(isCompact: Bool) -> some View {
        Menu {
            Picker("Metric", selection: $metric) {
                ForEach(Repository.TimelineMetric.allCases) { option in
                    Label(option.title, systemImage: symbol(for: option)).tag(option)
                }
            }
        } label: {
            TrendsMenuChipLabel(
                title: metric.title,
                systemImage: metricSymbol,
                tint: metricInk,
                isCompact: isCompact
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Metric: \(metric.title). Opens the metric list")
    }

    /// Day stepper: move the whole timeline back/forward a day so a user can reach the days that actually hold
    /// their data, not just today (#597). Forward is clamped at today (no future days).
    private var dayStepper: some View {
        HStack(spacing: 0) {
            Button { stepDay(-1) } label: {
                TrendsStepChipLabel(systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous day")

            Text(dayLabel)
                .font(StrandFont.captionNumber.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minWidth: 72)

            Button { stepDay(1) } label: {
                TrendsStepChipLabel(systemImage: "chevron.right", isEnabled: !isOnLatestDay)
            }
            .buttonStyle(.plain)
            .disabled(isOnLatestDay)
            .accessibilityLabel("Next day")
        }
    }

    private var isOnLatestDay: Bool { dayStart >= Repository.logicalDayStart(Date()) }

    /// Step the shown day by `delta` days, clamped so you can never go past today, and drop any zoom so the
    /// new day opens at full-day scale.
    private func stepDay(_ delta: Int) {
        let next = Repository.dateByAddingCalendarDays(delta, to: dayStart)
        if delta > 0 && next > Repository.logicalDayStart(Date()) { return }
        withAnimation(StrandMotion.interactive) {
            dayStart = next
            zoomDomain = nil
        }
    }

    private var dayLabel: String {
        let calendar = Calendar.autoupdatingCurrent
        let today = Repository.logicalDayStart(Date())
        if calendar.isDate(dayStart, inSameDayAs: today) { return String(localized: "Today") }
        let yesterday = Repository.dateByAddingCalendarDays(-1, to: today)
        if calendar.isDate(dayStart, inSameDayAs: yesterday) { return String(localized: "Yesterday") }
        return dayStart.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    // MARK: Timeline section

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow(
                title: zoomDomain == nil ? String(localized: "24-hour timeline") : String(localized: "Zoomed window"),
                systemImage: metricSymbol,
                tint: .custom(metricInk),
                trailing: series.points.isEmpty ? .none : .text(resolutionSubtitle)
            )
            controlRow
            if loading && series.points.isEmpty {
                loadingState
            } else if series.points.isEmpty {
                emptyState
            } else {
                chart
                statsFooter
            }
        }
    }

    private var chart: some View {
        HRTimelineChart(
            points: series.points.enumerated().map { index, point in
                HRTrackPoint(id: index, t: point.date.timeIntervalSince1970, bpm: point.value)
            },
            day: dayBounds.lowerBound.timeIntervalSince1970...dayBounds.upperBound.timeIntervalSince1970,
            sleep: sleepSpan.map {
                HRSleepBand(start: $0.start.timeIntervalSince1970,
                            end: $0.end.timeIntervalSince1970,
                            label: $0.label ?? "Sleep")
            },
            workouts: workoutSpans.enumerated().map { index, workout in
                HRWorkoutMark(id: index,
                              start: workout.start.timeIntervalSince1970,
                              end: workout.end.timeIntervalSince1970,
                              symbol: workout.symbol)
            },
            timeLabel: { Self.timeText(Date(timeIntervalSince1970: $0)) },
            title: metric.title,
            tint: timelineTint,
            unit: unitSuffix.trimmingCharacters(in: .whitespaces),
            valueFormat: { format($0) },
            showsZoneLegend: metric == .hr,
            zoomDomain: Binding(
                get: {
                    zoomDomain.map {
                        $0.lowerBound.timeIntervalSince1970...$0.upperBound.timeIntervalSince1970
                    }
                },
                set: { window in
                    zoomDomain = window.map {
                        Date(timeIntervalSince1970: $0.lowerBound)...Date(timeIntervalSince1970: $0.upperBound)
                    }
                }
            ),
            zoomBounds: panBounds.lowerBound.timeIntervalSince1970...panBounds.upperBound.timeIntervalSince1970,
            onSettledWindow: { _ in reloadTick &+= 1 }
        )
    }

    private var timelineTint: Color? {
        switch metric {
        case .hr: nil
        case .hrv: StrandPalette.metricPurple
        case .skinTemp: StrandPalette.metricAmber
        case .respiration: StrandPalette.accent
        case .spo2: StrandPalette.metricCyan
        case .motion: StrandPalette.textSecondary
        case .bandSleepState: StrandPalette.sleepDeep
        }
    }

    // MARK: States

    private var loadingState: some View {
        ZStack {
            TrendsGhostRail(height: 176)
            VStack(spacing: NoopMetrics.space2) {
                ProgressView().controlSize(.regular)
                Text("Loading the day…")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Honest empty/dash state: a window the strap offloaded nothing for (a not-yet-synced stretch, an
    /// off-wrist gap, or a metric this device doesn't record). Never a fabricated flat line.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            HeroValue(value: WidgetMetrics.missingValue, caption: String(localized: "\(metric.title): no data here"),
                      captionPlacement: .below)
            ZStack {
                TrendsGhostRail(height: 176)
                Text(ownedOnly
                     ? "Nothing offloaded for this window yet."
                     : "Other sources don’t offload raw per-second data on-device.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, NoopMetrics.space4)
                    .background(StrandPalette.appCanvas.opacity(0.88))
            }
            // A zoom that lands on an empty stretch has no plot to double-tap, so the way back stays on screen.
            if zoomDomain != nil {
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(StrandMotion.interactive) { zoomDomain = nil }
                    } label: {
                        WidgetChip(appTitle: "Reset", showsChevron: false, overhangs: false).chipHitTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Reset zoom"))
                }
            }
        }
    }

    /// Low, average and peak of the plotted window, inline as Today's Live HR module closes: the value bright,
    /// its caps label quiet, and the peak with the time it happened ("76 PEAK · 7:40"). At larger text the keys
    /// wrap onto a second and third line instead of truncating.
    private var statsFooter: some View {
        let values = series.points.map(\.value)
        let peak = series.points.max(by: { $0.value < $1.value })
        let low = footKey(label: String(localized: "Low"), value: format(values.min() ?? 0))
        let average = footKey(label: String(localized: "Avg"),
                              value: format(values.reduce(0, +) / Double(max(1, values.count))))
        let high = footKey(label: String(localized: "Peak"), value: format(peak?.value ?? 0),
                           time: peak.map { Self.timeText($0.date) })
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: NoopMetrics.space3) {
                low; average; high
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                HStack(spacing: NoopMetrics.space3) { low; average }
                high
            }
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                low; average; high
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func footKey(label: String, value: String, time: String? = nil) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(StrandFont.micro.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textPrimary)
            Text((time.map { "\(label.uppercased()) · \($0)" }) ?? label.uppercased())
                .font(StrandFont.micro)
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    // MARK: Time in range (heart rate)

    /// Time in range of the day on screen: none until that day's totals land.
    private var shownZoneSeconds: [Double] { zoneTotals?.seconds(for: dayStart) ?? [0, 0, 0] }

    private var zonesSection: some View {
        let seconds = shownZoneSeconds
        let total = max(seconds.reduce(0, +), 1)
        let rows: [(word: String, range: String, ink: Color)] = [
            (String(localized: "Rest"), "<60", StrandPalette.liveRed.opacity(0.58)),
            (String(localized: "Steady"), "60–110", StrandPalette.liveRed),
            (String(localized: "Push"), "110+", StrandPalette.destructive),
        ]
        return VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow(
                title: String(localized: "Time in range"),
                systemImage: "chart.bar.fill",
                tint: .heart,
                trailing: .text(dayLabel)
            )
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    zoneRow(word: row.word, range: row.range, ink: row.ink,
                            seconds: seconds[index], fraction: seconds[index] / total)
                }
            }
        }
    }

    /// Time in range as read for one day.
    struct ZoneTotals: Equatable {
        let day: Date
        let seconds: [Double]

        /// The totals if they were read for `shownDay`, and none (zero seconds in every zone) if they belong to another
        /// day, so a slow or cancelled read can never leave the last day's figures under a new day.
        func seconds(for shownDay: Date) -> [Double] {
            day == shownDay ? seconds : [0, 0, 0]
        }
    }

    /// "2h 5m", "7m", "<1m" for a sliver, and the missing dash for none.
    static func zoneDuration(_ seconds: Double) -> String {
        if seconds <= 0 { return WidgetMetrics.missingValue }
        if seconds < 60 { return String(localized: "<1m") }
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }

    private func zoneRow(word: String, range: String, ink: Color, seconds: Double, fraction: Double) -> some View {
        let duration = Self.zoneDuration(seconds)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                Circle().fill(ink).frame(width: 6, height: 6).accessibilityHidden(true)
                Text(word).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                Text(range).font(StrandFont.micro).monospacedDigit().foregroundStyle(StrandPalette.textTertiary)
                Spacer(minLength: NoopMetrics.space1)
                Text(duration)
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(seconds > 0 ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    .lineLimit(1)
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(StrandFont.micro).monospacedDigit().foregroundStyle(StrandPalette.textTertiary)
                    .frame(minWidth: 34, alignment: .trailing)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous).fill(ink.opacity(0.16))
                    Capsule(style: .continuous).fill(ink)
                        .frame(width: seconds > 0 ? max(proxy.size.width * CGFloat(fraction), 4) : 0)
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Source

    /// The strap is the owned source; "All" reveals the honest disclosure that other sources' raw per-second
    /// streams aren't offloaded on-device (#574).
    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow(
                title: String(localized: "Source"),
                systemImage: "dot.radiowaves.left.and.right",
                tint: .neutral
            )
            ViewThatFits(in: .horizontal) {
                HStack(spacing: NoopMetrics.space2) {
                    Text("My WHOOP").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: NoopMetrics.space2)
                    scopePicker
                }
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Text("My WHOOP").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    scopePicker
                }
            }
        }
    }

    private var scopePicker: some View {
        SegmentedPillControl([true, false], selection: $ownedOnly) {
            $0 ? String(localized: "Owned") : String(localized: "All")
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Source")
        .accessibilityValue(ownedOnly ? String(localized: "Owned") : String(localized: "All"))
        .accessibilityAdjustableAction { _ in ownedOnly.toggle() }
    }


    // MARK: Read

    /// One-shot on first open: if today has no data but an earlier day does (the classic just-synced-history
    /// case, #597), land the timeline on that most-recent day so the user sees their data instead of an empty
    /// today. Skipped when the caller pinned an explicit day, and never fights manual navigation afterwards.
    private func landOnLatestDayIfNeeded() async {
        guard !didLandOnLatest else { return }
        didLandOnLatest = true
        if let latest = await repo.latestDataDayStart(), latest < dayStart {
            withAnimation(StrandMotion.interactive) { dayStart = latest }
        }
    }

    private func reload() async {
        loading = true
        let window = visibleWindow
        let result = await repo.timelineSeries(
            metric: metric,
            from: Int(window.lowerBound.timeIntervalSince1970),
            to: Int(window.upperBound.timeIntervalSince1970),
            targetPoints: 600
        )
        // Guard against a stale task landing after the user moved on.
        guard !Task.isCancelled else { return }
        series = result
        loading = false
    }

    /// How long the shown DAY spent resting (under 60), steady (60 to 110) and pushing (110 and over): the whole
    /// calendar day read at one-minute buckets whatever the chart's zoom, each bucket standing for its own width.
    /// (1500 target points makes the read layer pick 60 s for a 23-, 24- or 25-hour day alike.)
    private func reloadZones() async {
        guard metric == .hr else { zoneTotals = nil; return }
        let day = dayStart
        let result = await repo.timelineSeries(
            metric: .hr,
            from: Int(day.timeIntervalSince1970),
            to: Int(nextDayStart.timeIntervalSince1970),
            targetPoints: 1500
        )
        guard !Task.isCancelled else { return }
        let width = Double(max(result.bucketSeconds, 1))
        var totals = [0.0, 0.0, 0.0]
        for point in result.points where point.value.isFinite {
            if point.value < HRZoneStyle.restCeiling { totals[0] += width }
            else if point.value < HRZoneStyle.steadyCeiling { totals[1] += width }
            else { totals[2] += width }
        }
        zoneTotals = ZoneTotals(day: day, seconds: totals)
    }

    /// #979 spin-off — load the shown day's sleep + workouts and scope them EXACTLY like the classic
    /// Today's Overview HR markers: `allSleepSessions` (imported AND on-device computed sources — a
    /// Bluetooth-only user's sleep lives under the computed source), longest overlapping block = the main
    /// night, never a nap; `workoutRows` (already dedup/dismiss-filtered) kept where they overlap the day.
    /// The band + duration use the EFFECTIVE onset so a hand-corrected bedtime shows the same band here as
    /// on the Sleep tab (#318). Both repo reads are today-relative, so `days:` walks back far enough from
    /// now to cover the shown day; the +2 pad mirrors TodayView's sleep read (the night straddles midnight).
    private func reloadAnnotations() async {
        let calendar = Calendar.current
        let currentDayStart = calendar.startOfDay(for: Date())
        let civilDaysBack = calendar.dateComponents([.day], from: dayStart, to: currentDayStart).day ?? 0
        let daysBack = max(0, civilDaysBack) + 2

        let sleepCandidates: [OverviewHRChart.SleepSpan] = await repo.allSleepSessions(days: daysBack)
            .map { s in
                .init(start: Date(timeIntervalSince1970: TimeInterval(s.effectiveStartTs)),
                      end: Date(timeIntervalSince1970: TimeInterval(s.endTs)),
                      label: Self.hoursMinutes(s.endTs - s.effectiveStartTs))
            }
        let workoutCandidates: [OverviewHRChart.WorkoutSpan] = await repo.workoutRows(days: daysBack)
            .map { w in
                .init(start: Date(timeIntervalSince1970: TimeInterval(w.startTs)),
                      end: Date(timeIntervalSince1970: TimeInterval(w.endTs)),
                      symbol: sportSymbol(w.sport))
            }
        guard !Task.isCancelled else { return }
        // The pure, headless-tested selection (StrandDesignTests) — window = the shown DAY, not the zoom.
        sleepSpan = OverviewHRChart.mainSleep(sleepCandidates, overlapping: dayBounds)
        workoutSpans = OverviewHRChart.workouts(workoutCandidates, overlapping: dayBounds)
    }

    /// "H:MM" for a duration in seconds (e.g. a 6h06m night → "6:06") — mirrors TodayView.hoursMinutes
    /// so the band label reads identically on both whole-day charts.
    private static func hoursMinutes(_ seconds: Int) -> String {
        let h = max(0, seconds) / 3600, m = (max(0, seconds) % 3600) / 60
        return "\(h):\(String(format: "%02d", m))"
    }

    // MARK: Presentation helpers

    private var resolutionSubtitle: String {
        guard !series.points.isEmpty else { return "—" }
        if series.isRaw { return String(localized: "Raw · per second") }
        let m = series.bucketSeconds / 60
        return m >= 1 ? String(localized: "\(m)-minute average")
                      : String(localized: "\(series.bucketSeconds)-second average")
    }

    private var unitSuffix: String {
        switch metric {
        case .hr: return " bpm"
        case .skinTemp: return "°C"
        case .respiration: return ""
        case .hrv: return " ms"
        case .spo2, .motion, .bandSleepState: return ""
        }
    }

    private func format(_ v: Double) -> String {
        switch metric {
        case .hr, .respiration, .hrv: return String(Int(v.rounded()))
        case .skinTemp: return String(format: "%.1f", v)
        case .spo2, .motion: return String(format: "%.2f", v)
        // #175: name the band's own state at the nearest code so the readout reads "asleep", not "2.0".
        case .bandSleepState: return Self.bandStateLabel(v)
        }
    }

    /// #175: map the band's 0-3 sleep_state code to its word. A bucket-averaged fractional value (when
    /// zoomed out) is rounded to the nearest code — honest for a readout label; the track itself plots the
    /// numeric code. This names the BAND's own reported state, never a stage NOOP derives.
    static func bandStateLabel(_ v: Double) -> String {
        switch Int(v.rounded()) {
        case 0: return String(localized: "wake")
        case 1: return String(localized: "still")
        case 2: return String(localized: "asleep")
        case 3: return String(localized: "up")
        default: return String(Int(v.rounded()))
        }
    }

    /// The time of day as the rest of the app writes it: the device's locale and time zone with the app's own
    /// 12/24-hour setting ("5:45 PM" / "17:45").
    private static func timeText(_ date: Date) -> String {
        AppClock.hourMinute(date)
    }
}

#if os(macOS)
import AppKit
// MARK: - macOS scroll-to-zoom
//
// Scroll up (or trackpad pinch on macOS, which arrives as a magnify event the chart already handles) zooms
// in about the window centre; scroll down zooms out toward the day. Kept as a modifier so the platform
// split stays out of the screen body.
private struct ScrollToZoomModifier: ViewModifier {
    let current: () -> ClosedRange<Date>
    let bounds: ClosedRange<Date>
    let apply: (ClosedRange<Date>) -> Void

    func body(content: Content) -> some View {
        content.background(ScrollCatcher { deltaY in
            // Each notch scales by ~1.15; up (positive) zooms in, down zooms out.
            let scale = deltaY > 0 ? 1.15 : (1.0 / 1.15)
            let zoomed = OverviewHRChart.zoomed(current(), scale: scale, anchorFraction: 0.5, bounds: bounds)
            apply(zoomed.upperBound > zoomed.lowerBound ? zoomed : current())
        })
    }
}

/// A transparent NSView that reports scroll-wheel deltaY up the closure. AppKit-only.
private struct ScrollCatcher: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void
    func makeNSView(context: Context) -> NSView { CatcherView(onScroll: onScroll) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onScroll = onScroll
    }
    final class CatcherView: NSView {
        var onScroll: (CGFloat) -> Void
        init(onScroll: @escaping (CGFloat) -> Void) {
            self.onScroll = onScroll
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func scrollWheel(with event: NSEvent) {
            if abs(event.scrollingDeltaY) > 0.5 { onScroll(event.scrollingDeltaY) }
        }
    }
}
#endif
