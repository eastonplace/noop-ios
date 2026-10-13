#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - The journey's summary
//
// The screen after End and a save, drawn as the live screen is (Direction A, "Apple Workout, refined"): pure black, the number the
// sport is about large and under it the others, each in its own colour with its unit beside it; no eyebrows over numbers, no rules,
// no slab buttons. The header is the live header's: the sport's name, a state line under it ("Saved · 7:42 AM") and a 44 pt circle
// to leave by. Then the zone row of the live Heart page, the heart-rate trace, the route, and two actions: Details (a quiet capsule)
// opens the workout's full detail screen, which is the Workouts hub's own screen (every number, the recovery after, five zones, the
// curve you can read by touch, the map and its notes); Done, the one solid mint control, leaves the journey.

struct WorkoutSummaryView: View {
    let row: WorkoutRow
    /// When the workout was saved, for the state line. nil falls back to the time the workout ended.
    var savedAt: Date? = nil
    /// Done, or the close circle: the finish has been seen and the journey closes.
    let onDone: () -> Void

    @EnvironmentObject private var repo: Repository
    @StateObject private var profile = ProfileStore()
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue

    /// What loads after the first frame: the saved row as the store has it now, the heart-rate trace, the time in each zone and
    /// the route. The figures need only the row, so they draw at once.
    private struct Loaded {
        var row: WorkoutRow
        var series: WorkoutHeartRateSeries?
        var zoneSeconds: [Int]
        var route: [[RouteMath.LatLng]]
    }

    @State private var loaded: Loaded?
    @State private var usualStored: Double?
    @State private var showsDetails = false

    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var displayRow: WorkoutRow { loaded?.row ?? row }
    private var thresholds: HRZoneStyle.Thresholds { ProfileStore.hrZoneThresholds(override: profile.hrMaxOverride, age: profile.age) }
    private var heroStrain: WorkoutHeroStrain { WorkoutHeroStrain.make(for: displayRow, usualStored: usualStored) }
    private var sportName: String { WorkoutSportTitle.name(for: displayRow.sport) }

    /// The two sizes of the live screen, as scales of its numerals: the focus figure at full size and the rest at 62%, two to a
    /// row (one to a row at the accessibility sizes, where a column is too narrow for a figure and its unit).
    private static let restScale: CGFloat = 0.62
    private static let restScaleAccessibility: CGFloat = 0.8
    private static let sectionGap: CGFloat = 34
    private static let sideWidth: CGFloat = 84
    /// How tall the soft black fade above the pinned Done is: what scrolls up under it dissolves instead of being cut.
    private static let footerFade: CGFloat = 40

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                figuresBlock
                strainNote
                zoneSection
                traceSection
                routeSection
                detailsButton.padding(.top, Self.sectionGap)
            }
            .screenPadding()
            .padding(.top, NoopMetrics.space4)
            // The last thing on the page rests clear of the footer's fade, not under it.
            .padding(.bottom, Self.footerFade)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(LivePalette.canvas.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { doneBar }
        .sheet(isPresented: $showsDetails, onDismiss: reload) {
            // The Workouts hub's own screen, as the hub presents it: a sheet with its own navigation stack and one close button.
            NavigationStack {
                WorkoutDetailView(row: displayRow)
                    .environmentObject(repo)
                    .sheetScreenScaffoldEnvironment(onClose: { showsDetails = false })
            }
            .noopSheetPresentation(largeFirst: true)
        }
        // The row is read again whenever the store changes (a rescore after the save can change the strain, the energy and the
        // heart rate), and when Details closes, so what this page says is never behind what Details just showed.
        .task(id: repo.refreshSeq) { await load() }
    }

    private func reload() {
        Task { await load() }
    }

    // MARK: Header

    /// Close in a dark circle at the left, the sport's name and its state in the middle: the live screen's header.
    private var header: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space2) {
            Button(action: onDone) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(LivePalette.fill))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .frame(width: Self.sideWidth, alignment: .leading)
            .accessibilityLabel("Close")
            VStack(spacing: 3) {
                Text(verbatim: sportName)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .liveText(17, weight: .semibold, maxSize: 24, lines: 2)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                stateLine
            }
            .frame(maxWidth: .infinity)
            Color.clear.frame(width: Self.sideWidth, height: 44)
        }
        .frame(minHeight: 44)
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.top, 2 + NoopMetrics.space2)
        .padding(.bottom, NoopMetrics.space1)
        .background(LivePalette.canvas)
    }

    /// "✓ Saved · 7:42 AM": the word in mint, the clock in grey. At the accessibility sizes it breaks as "Saved" over "7:42 AM",
    /// never leaving a "·" alone.
    private var stateLine: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 0))
            : AnyLayout(HStackLayout(spacing: 5))
        let clock = WorkoutSummary.savedClock(for: displayRow, savedAt: savedAt)
        return layout {
            HStack(spacing: 5) {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                Text("Saved").liveText(13, weight: .medium, maxSize: 19, lines: 1)
            }
            .foregroundStyle(LivePalette.mint)
            if !typeSize.isAccessibilitySize {
                Text(verbatim: "·").foregroundStyle(LivePalette.secondaryText).liveText(13, weight: .medium, maxSize: 19, lines: 1)
            }
            Text(verbatim: clock).monospacedDigit().foregroundStyle(LivePalette.secondaryText)
                .liveText(13, weight: .medium, maxSize: 19, lines: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Saved at \(clock)"))
    }

    // MARK: Figures

    private func figureView(_ figure: WorkoutSummary.Figure, size: LiveNumeral.Size, scale: CGFloat) -> some View {
        LiveWorkoutFigure(value: figure.value, size: size, scale: scale, isPaused: false,
                          signals: LiveWorkoutSignals.Snapshot(), zone: figure.zone)
    }

    private var figuresBlock: some View {
        let figures = WorkoutSummary.figures(for: displayRow, strain: heroStrain, imperial: unitSystem == .imperial,
                                             thresholds: thresholds)
        let columns = typeSize.isAccessibilitySize ? 1 : 2
        let scale = typeSize.isAccessibilitySize ? Self.restScaleAccessibility : Self.restScale
        let rows = stride(from: 0, to: figures.rest.count, by: columns).map { Array(figures.rest[$0..<min($0 + columns, figures.rest.count)]) }
        return VStack(alignment: .leading, spacing: 0) {
            figureView(figures.focus, size: .focus, scale: 1)
            ForEach(Array(rows.enumerated()), id: \.offset) { index, pair in
                HStack(alignment: .top, spacing: NoopMetrics.space4) {
                    ForEach(pair) { figure in
                        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                            figureView(figure, size: .secondary, scale: scale)
                            if let comparison = figure.comparison { comparisonCaption(comparison) }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    // A row with one figure keeps its column: the figure is not stretched across the page.
                    if pair.count < columns { Color.clear.frame(maxWidth: .infinity).frame(height: 1) }
                }
                .padding(.top, (index == 0 ? LiveNumeralMetrics.focusGap : LiveNumeralMetrics.secondaryGap) * scale)
            }
        }
    }

    /// Under the strain figure, in the small print of the unit block: how it stands against the usual for the sport ("+0.9 vs usual").
    private func comparisonCaption(_ comparison: WorkoutSummary.Comparison) -> some View {
        Text(verbatim: comparison.text)
            .monospacedDigit()
            .foregroundStyle(LivePalette.secondaryText)
            .liveText(13, weight: .medium, maxSize: 19, lines: 2)
            .accessibilityLabel(Text(verbatim: comparison.spoken))
    }

    /// Under the figures: why a workout that nobody scored has no strain.
    @ViewBuilder private var strainNote: some View {
        switch heroStrain {
        case .unscored:
            VStack(alignment: .leading, spacing: 2) {
                Text("Not scored").foregroundStyle(StrandPalette.textPrimary)
                    .liveText(14, weight: .semibold, maxSize: 20, lines: 2)
                Text("NOOP scores a workout from the heart rate recorded during it.").foregroundStyle(LivePalette.secondaryText)
                    .liveText(14, weight: .regular, maxSize: 20, lines: 4)
            }
            .padding(.top, Self.sectionGap - 6)
            .accessibilityElement(children: .combine)
        default:
            EmptyView()
        }
    }

    // MARK: Zones, heart rate, route

    @ViewBuilder private var zoneSection: some View {
        if let seconds = loaded?.zoneSeconds, seconds.reduce(0, +) > 0 {
            // The live Heart page's zone row, lit on the zone most of the workout was spent in.
            LiveZoneRow(seconds: seconds, thresholds: thresholds, currentZone: WorkoutSummary.dominantZone(of: seconds))
                .padding(.top, Self.sectionGap)
        }
    }

    @ViewBuilder private var traceSection: some View {
        if let series = loaded?.series {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                sectionTitle("Heart rate")
                WorkoutSummaryTrace(series: series, start: displayRow.startTs, thresholds: thresholds,
                                    accessibilityName: String(localized: "Heart rate during \(sportName)"))
            }
            .padding(.top, Self.sectionGap)
        }
    }

    @ViewBuilder private var routeSection: some View {
        if let route = loaded?.route, !route.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                sectionTitle("Route")
                WorkoutRouteMap(segments: route)
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    // A picture of the route, not a map to move: a drag that starts on it scrolls the page, which a live map would
                    // take for itself. The map you can pan and zoom is on Details.
                    .allowsHitTesting(false)
                    .accessibilityLabel(Text(verbatim: routeAccessibilityLabel))
            }
            .padding(.top, Self.sectionGap)
        }
    }

    private var routeAccessibilityLabel: String {
        let distance = (displayRow.distanceM ?? 0) > 0
            ? UnitFormatter.distanceFromMeters(displayRow.distanceM ?? 0, system: unitSystem) : WidgetMetrics.missingValue
        return String(localized: "Map of your \(sportName) route, \(distance).")
    }

    /// A quiet heading: grey words, not tracked capitals.
    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .foregroundStyle(LivePalette.secondaryText)
            .liveText(15, weight: .semibold, maxSize: 22, lines: 2)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Actions

    private var detailsButton: some View {
        LiveCapsuleButton(String(localized: "Details")) { showsDetails = true }
    }

    /// Done, the one solid mint control: pinned under the page, as Start is on setup.
    private var doneBar: some View {
        LiveCircleButton(title: String(localized: "Done"), systemImage: "checkmark", solid: true,
                         diameter: LiveCircleMetrics.startDiameter(accessibilitySize: typeSize.isAccessibilitySize), action: onDone)
            .padding(.vertical, NoopMetrics.space2)
            .frame(maxWidth: .infinity)
            // Opaque and edge to edge, so what scrolls beneath it never shows through.
            .background(LivePalette.canvas.ignoresSafeArea(edges: .bottom))
            // And a soft black fade above it, so a figure that scrolls up to the footer dissolves into it rather than being cut.
            .overlay(alignment: .top) {
                LinearGradient(colors: [LivePalette.canvas.opacity(0), LivePalette.canvas], startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.footerFade)
                    .offset(y: -Self.footerFade)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }

    // MARK: Load

    private func load() async {
        // The row the journey was handed is the moment of the save; the store's is the one a rescore may since have changed.
        let window = await repo.workoutRows(from: max(0, row.startTs - 60), to: max(row.endTs, row.startTs + 1) + 60)
        let target = window.first { $0.startTs == row.startTs && $0.sport == row.sport } ?? row
        let route = RouteStore.load(startTs: target.startTs, sport: target.sport)?.decodedSegments.filter { $0.count >= 2 } ?? []
        let buckets = await repo.workoutHrBuckets(from: target.startTs, to: target.endTs)
        let series = WorkoutHeartRateSeries(
            samples: buckets.map { .init(seconds: Double($0.ts - target.startTs), bpm: $0.bpm) },
            duration: Double(max(1, target.endTs - target.startTs)),
            recordedAverage: target.avgHr, recordedPeak: target.maxHr)
        let samples = await repo.hrSamples(from: target.startTs, to: target.endTs,
                                           limit: min(172_800, max(8_000, target.endTs - target.startTs + 1)))
        // A workout that was paused leaves its paused minutes out of its zones: the strap kept logging through the pause.
        let pauses = WorkoutPauseStore.load(startTs: target.startTs, sport: target.sport) ?? WorkoutPauseLedger()
        let zoneSeconds = PersonalZoneSeconds.compute(samples: samples, pauses: pauses, thresholds: thresholds).seconds
        guard !Task.isCancelled else { return }
        loaded = Loaded(row: target, series: series, zoneSeconds: zoneSeconds, route: route)

        // "Compared to your usual" is secondary: it waits until the rest is on screen.
        let history = await repo.workoutRows(days: 4000, reconcileHR: false)
        guard !Task.isCancelled else { return }
        let comparison = history.filter {
            !($0.startTs == target.startTs && $0.sport == target.sport)
                && $0.sport.caseInsensitiveCompare(target.sport) == .orderedSame
        }.compactMap { StrainResolver.canonicalWorkout($0)?.storedValue }
        usualStored = comparison.isEmpty ? nil : comparison.reduce(0, +) / Double(comparison.count)
    }
}

// MARK: - The heart-rate trace

/// The workout's heart rate as one line in the live screen's zone colours (rest, steady, push), with nothing around it but the clock
/// time at each end and, under it, the average, peak and low. The curve you can read by touch is on the detail screen.
struct WorkoutSummaryTrace: View {
    let series: WorkoutHeartRateSeries
    /// Epoch second the workout started, for the clock times at the ends.
    let start: Int
    let thresholds: HRZoneStyle.Thresholds
    let accessibilityName: String

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Canvas { context, size in
                let samples = series.samples
                guard samples.count >= 2, series.duration > 0 else { return }
                let span = max(series.axis.upperBound - series.axis.lowerBound, 1)
                let inset: CGFloat = 3
                func point(_ sample: WorkoutHeartRateSeries.Sample) -> CGPoint {
                    CGPoint(x: inset + (size.width - 2 * inset) * CGFloat(min(max(sample.seconds / series.duration, 0), 1)),
                            y: inset + (size.height - 2 * inset) * CGFloat(1 - (sample.bpm - series.axis.lowerBound) / span))
                }
                // One short stroke per stretch between readings, each in the colour of the zone it lay in.
                for (a, b) in zip(samples, samples.dropFirst()) {
                    var path = Path()
                    path.move(to: point(a))
                    path.addLine(to: point(b))
                    let zone = thresholds.zone(for: (a.bpm + b.bpm) / 2)
                    context.stroke(path, with: .color(LivePalette.zone(zone)),
                                   style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(height: 120)
            HStack {
                Text(verbatim: clock(at: 0))
                Spacer(minLength: NoopMetrics.space2)
                Text(verbatim: clock(at: series.duration))
            }
            .monospacedDigit()
            .foregroundStyle(LivePalette.secondaryText)
            .liveText(12, weight: .medium, maxSize: 17, lines: 1)
            SeparatedFactsLine(facts: facts)
                .foregroundStyle(LivePalette.secondaryText)
                .liveText(14, weight: .regular, maxSize: 20, lines: 3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityName))
        .accessibilityValue(Text(verbatim: spoken))
    }

    private func clock(at seconds: Double) -> String {
        AppClock.hourMinute(Date(timeIntervalSince1970: TimeInterval(start) + seconds))
    }

    /// "Avg 149 bpm", "Peak 178 bpm", "Low 98 bpm".
    private var facts: [String] {
        let unit = LiveWorkoutGlance.Units.heartRate
        return [
            "\(String(localized: "Avg")) \(Int(series.average.rounded())) \(unit)",
            "\(String(localized: "Peak")) \(Int(series.peak.rounded())) \(unit)",
            "\(String(localized: "Low")) \(Int(series.low.rounded())) \(unit)",
        ]
    }

    /// The same, as it is spoken: the one localized sentence the detail screen's curve speaks (the unit as words, not the letters
    /// "bpm", and a word order each language can set).
    private var spoken: String {
        String(localized: "Average \(Int(series.average.rounded())) beats per minute, peak \(Int(series.peak.rounded())), low \(Int(series.low.rounded()))")
    }
}
#endif
