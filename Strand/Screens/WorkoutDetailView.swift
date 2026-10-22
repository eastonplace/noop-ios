import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation
import WorkoutRouteExport
#if canImport(MapKit)
import MapKit
#endif

// MARK: - Workout detail (#410)
//
// A READ-ONLY drill-down for one tapped session, in the widget design language the Workouts hub it opens from speaks.
//
//   • the session's Strain as a dial when NOOP scored it, as WHOOP's own number (named, in a neutral dial) when WHOOP
//     did, and as a calm "Not scored" when nobody did, beside how long it was and when;
//   • Overview: the session's numbers as tiles, the heart-rate recovery after it, the time in each heart-rate
//     zone and the session's heart rate in brief (choose a zone to see where it fell; the curve opens the next tab);
//   • Heart Rate: the whole session's curve with the average, peak and low marked, readable by touch and hold;
//   • Map: the GPS route recorded on this device (#524), shown only when points were actually captured, and the
//     elevation row, which says plainly that it is not recorded.
//
// Presented as a `.sheet` wrapped in a NavigationStack by WorkoutsView, and pushed from Today's workouts.

struct WorkoutDetailView: View {
    let row: WorkoutRow

    @EnvironmentObject private var repo: Repository
    @StateObject private var profile = ProfileStore()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Set when this screen is the summary at the end of the workout journey: the bottom button then says "Done" and ends
    /// the journey instead of closing a sheet.
    @Environment(\.workoutJourneyDone) private var journeyDone

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    /// The session's heart rate as the curve draws it. nil until loaded, and when there are too few readings.
    @State private var heartRate: WorkoutHeartRateSeries?
    /// Per-zone MINUTES for the zones section: imported zones (duration-weighted) when present, else the window's raw
    /// HR samples binned into %HRmax zones. nil = no zone split to show.
    @State private var zoneMinutes: [Double]? = nil
    /// True when the zone split came from imported WHOOP percentages (vs derived from raw strap HR).
    @State private var zonesFromImport = false
    @State private var zoneSet: HRZoneSet?
    @State private var loaded = false
    @State private var zoneTimeline: WorkoutZoneTimeline?

    /// The GPS route captured for this session on-device (#524), if any. Decoded from `RouteStore` by the
    /// row's natural key. nil = no route was recorded (honest — the map only shows when points exist).
    @State private var routeSegments: [[RouteMath.LatLng]] = []
    @State private var savedRoute: WorkoutRoute?
    @State private var routeGPXFile: WorkoutRouteExportFile?
    @State private var routeFITFile: WorkoutRouteExportFile?
    @State private var routeExportError: String?
    @State private var preparingRouteExports = false
    @State private var routeExportRequestID: UUID?
    private var routePointCount: Int { routeSegments.reduce(0) { $0 + $1.count } }
    private var hasDrawableRoute: Bool { routeSegments.contains { $0.count >= 2 } }
    /// Board-v2 tabbed summary (spec 003 D6). Splits tab is pending a real per-split
    /// computation (none exists in the repo yet) — adding a fake table would violate the
    /// honesty rule, so the segment ships with three tabs until Codex lands split math.
    enum DetailTab: CaseIterable { case overview, heartRate, map
        var label: String {
            switch self {
            case .overview: String(localized: "Overview")
            case .heartRate: String(localized: "Heart Rate")
            case .map: String(localized: "Map")
            }
        }
    }
    @State private var detailTab: DetailTab = Self.launchTab
    /// The average stored strain of the person's other NOOP-scored sessions of this sport, for the comparison.
    @State private var usualStored: Double?
    /// What a Strength Training session says about the sets in its Strain; nil for any other session.
    @State private var liftNote: WorkoutLiftStrainNote?

    /// QA: `--noop-qa-detail-tab heart|map` opens the detail on that tab (DEBUG only).
    private static var launchTab: DetailTab {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--noop-qa-detail-tab"), arguments.indices.contains(index + 1) {
            switch arguments[index + 1].lowercased() {
            case "heart", "hr": return .heartRate
            case "map": return .map
            default: break
            }
        }
        #endif
        return .overview
    }
    @State private var refreshedRow: WorkoutRow?
    @ScaledMetric(relativeTo: .title) private var dialDiameter: CGFloat = NoopMetrics.heroRingDiameter
    @ScaledMetric(relativeTo: .title) private var dialLineWidth: CGFloat = NoopMetrics.heroRingLineWidth

    /// The tap payload is only a routing key. Resolve it again after a durable workout
    /// finish so detail never keeps presenting the pre-save or pre-rescore snapshot.
    private var displayRow: WorkoutRow { refreshedRow ?? row }
    private var startDate: Date { Date(timeIntervalSince1970: TimeInterval(displayRow.startTs)) }
    private var sportName: String { WorkoutSource.displaySport(displayRow.sport) }

    var body: some View {
        ScreenScaffold(title: "\(sportName) Summary",
                       // A sheet's header names the day in full; a pushed screen's row carries it as headerContext.
                       subtitle: LocalizedStringKey(startDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())),
                       // This bounded summary uses eager layout. Nested lazy chart/grid measurement
                       // repeatedly invalidates placement while scrolling on iOS 26.5.
                       lazy: false,
                       // The sheet host supplies the single close button (sheetScreenScaffoldEnvironment);
                       // pushed from Today it shows the scaffold's back chevron instead.
                       topBackground: nil,
                       headerContext: DrillInFormat.headerDate(startDate)) {
            VStack(alignment: .leading, spacing: 0) {
                hero
                FlatSectionSeparator()
                SegmentedPillControl(hasDrawableRoute ? DetailTab.allCases : [.overview, .heartRate],
                                     selection: $detailTab) { $0.label }
                    .padding(.top, NoopMetrics.space3)
                    .padding(.bottom, NoopMetrics.space4)
                switch detailTab {
                case .overview: overview
                case .heartRate: heartRateSection
                case .map: mapSections
                }
                Button {
                    if let journeyDone { journeyDone.perform() } else { dismiss() }
                } label: {
                    Group {
                        if journeyDone == nil {
                            Label("Close summary", systemImage: "checkmark")
                        } else {
                            Label("Done", systemImage: "checkmark")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .padding(.top, NoopMetrics.space6)
            }
        }
        .environment(\.appHeaderChromeVisibility, .hidden)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #else
        .toolbar {
            // A Done affordance for the sheet on both platforms (iOS gets the grabber too).
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        #endif
        .task { await load() }
        // A lift's sets are scored shortly after it is saved; the note and the dial catch up when that lands. Posted on
        // whatever thread did the work, so hop to the main thread before touching view state.
        .onReceive(NotificationCenter.default.publisher(for: .liftStrainDidChange)
            .receive(on: DispatchQueue.main)) { _ in
            guard displayRow.sport == StrengthStrainIntegration.sport else { return }
            Task { await refreshLiftStrain() }
        }
    }

    // MARK: - Load

    private func load() async {
        // Resolve only the tapped session first. The old path loaded + reconciled up to 4,000 days of
        // workout history before the detail could paint, even though the primary screen needs one row.
        let targetWindow = await repo.workoutRows(
            from: max(0, row.startTs - 60),
            to: max(row.endTs, row.startTs + 1) + 60
        )
        let target = targetWindow.first {
            $0.startTs == row.startTs && $0.sport == row.sport
        } ?? row

        // #524: the GPS route, if this session recorded one on-device. A cheap UserDefaults read keyed
        // by the row's natural key (startTs + sport); decoded to points only when ≥2 were captured so the
        // map only ever draws a real route.
        let loadedRoute = RouteStore.load(startTs: target.startTs, sport: target.sport)
        let loadedRouteSegments = loadedRoute?.decodedSegments.filter { $0.count >= 2 } ?? []

        // HR curve over the exact session window — a finer bucket than the 24h chart so a short run
        // still reads as a curve, not a handful of points.
        let buckets = await repo.workoutHrBuckets(from: target.startTs, to: target.endTs)
        let series = WorkoutHeartRateSeries(
            samples: buckets.map { .init(seconds: Double($0.ts - target.startTs), bpm: $0.bpm) },
            duration: Double(max(1, target.endTs - target.startTs)),
            recordedAverage: target.avgHr, recordedPeak: target.maxHr)
        // Zones: prefer the imported per-workout percentages (a WHOOP-computed split), and only fall
        // back to deriving zone-minutes from the strap's own raw HR when the row has none — so we
        // never overwrite a real imported split with an on-device approximation.
        var minutes: [Double]?
        var fromImport = false
        if let pct = WorkoutZones.percents(target.zonesJSON) {
            let durMin = (target.durationS ?? Double(target.endTs - target.startTs)) / 60.0
            if durMin > 0 {
                minutes = pct.map { durMin * $0 / 100.0 }
                fromImport = true
            }
        }
        let samples = await repo.hrSamples(from: target.startTs, to: target.endTs,
                                           limit: min(172_800, max(8_000, target.endTs - target.startTs + 1)))
        let maxHR = Double(profile.hrMax)
        let zones = HRZones.zones(maxHR: maxHR, source: profile.hrMaxOverride > 0 ? "manual" : "tanaka")
        // A workout that was paused leaves its paused minutes out of its zones: the strap kept logging through the pause.
        let zoneSamples = WorkoutPauseStore.load(startTs: target.startTs, sport: target.sport)?
            .activeSamples(samples) ?? samples
        let timeline = await Task.detached(priority: .userInitiated) {
            WorkoutZoneTimeline.make(samples: zoneSamples, start: target.startTs, end: target.endTs, maxHR: maxHR)
        }.value
        guard !Task.isCancelled else { return }
        if minutes == nil, timeline.minutes.contains(where: { $0 > 0 }) { minutes = timeline.minutes }

        await MainActor.run {
            self.routeSegments = loadedRouteSegments
            self.savedRoute = loadedRoute
            self.refreshedRow = target
            self.heartRate = series
            self.zoneTimeline = timeline
            self.zoneSet = zones
            self.zoneMinutes = minutes
            self.zonesFromImport = fromImport
            self.loaded = true
        }
        await prepareRouteExports(route: loadedRoute, startTs: target.startTs, sport: target.sport)
        await loadLiftNote(for: target)

        // "Compared to your usual" is secondary context. Load it AFTER the useful detail is committed,
        // and skip per-row HR reconciliation because this calculation only needs each stored Strain value.
        let history = await repo.workoutRows(days: 4000, reconcileHR: false)
        guard !Task.isCancelled else { return }
        let comparison = history.filter {
            !($0.startTs == target.startTs && $0.sport == target.sport)
                && $0.sport.caseInsensitiveCompare(target.sport) == .orderedSame
        }.compactMap { StrainResolver.canonicalWorkout($0)?.storedValue }
        usualStored = comparison.isEmpty ? nil : comparison.reduce(0, +) / Double(comparison.count)
    }

    /// The lift note for `target`, from stored values only. Imported lifts have totals and no lift row, so they never read it.
    private func loadLiftNote(for target: WorkoutRow) async {
        let imported = WorkoutSource.classify(target.source) == .lifting
        guard imported || target.sport == StrengthStrainIntegration.sport else { liftNote = nil; return }
        let snapshot = imported ? nil : await repo.liftStrainSummary(startTs: target.startTs, sport: target.sport)
        guard !Task.isCancelled else { return }
        liftNote = WorkoutLiftStrainNote.make(sport: target.sport, source: target.source, snapshot: snapshot)
    }

    /// The sets were just (re)scored: read the session's row again so the dial and the note agree.
    private func refreshLiftStrain() async {
        let current = displayRow
        let window = await repo.workoutRows(from: max(0, current.startTs - 60),
                                            to: max(current.endTs, current.startTs + 1) + 60)
        guard !Task.isCancelled else { return }
        let fresh = window.first { $0.startTs == current.startTs && $0.sport == current.sport } ?? current
        refreshedRow = fresh
        await loadLiftNote(for: fresh)
    }

    // MARK: - Hero

    private var heroStrain: WorkoutHeroStrain {
        WorkoutHeroStrain.make(for: displayRow, usualStored: usualStored)
    }

    private var hero: some View {
        FlatSection("Workout strain", systemImage: "flame", tint: .strain,
                    trailing: .text(WorkoutFormat.sourceName(for: displayRow))) {
            VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
                GaugeLayout {
                    dial
                } rows: {
                    VStack(alignment: .leading, spacing: 4) {
                        heroTitle
                        heroSentence
                        Text(verbatim: timeRange)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .padding(.top, 2)
                            .accessibilityLabel(Text(verbatim: spokenTimeRange))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let liftNote { liftStrainNote(liftNote) }
                // With no other scored session of this sport to compare against there is nothing to say.
                if case .noop(_, let delta?) = heroStrain { comparedToUsual(delta) }
            }
        }
    }

    @ViewBuilder private var dial: some View {
        // The dial grows with the text so its number and caption never outgrow the ring, up to a ceiling that keeps
        // it beside the words as long as it can.
        let diameter = min(dialDiameter, 190)
        let lineWidth = min(dialLineWidth, 12)
        switch heroStrain {
        case .noop(let display, _):
            ScoreRing(value: display, range: 0...21, accent: DomainTint.strain.accent, size: diameter,
                      lineWidth: lineWidth, format: { $0.formatted(.number.precision(.fractionLength(1))) })
        case .whoop(let display):
            // WHOOP's own number: the same dial in a neutral ink and named, so it is never read as NOOP's.
            ScoreRing(value: display, range: 0...21, accent: StrandPalette.textSecondary, size: diameter,
                      lineWidth: lineWidth, format: { $0.formatted(.number.precision(.fractionLength(1))) },
                      // At accessibility sizes the caption would sit on the ring; the source named above says it.
                      centerCaption: typeSize.isAccessibilitySize ? nil : String(localized: "WHOOP"))
        case .unscored:
            ZStack {
                Circle().stroke(StrandPalette.chipFill, lineWidth: lineWidth)
                Text(verbatim: WidgetMetrics.missingValue)
                    .font(StrandFont.ringScoreLarge)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .frame(width: diameter, height: diameter)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Not scored")
        }
    }

    @ViewBuilder private var heroTitle: some View {
        if let band = heroStrain.bandTitle {
            Text(verbatim: band)
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
        } else {
            Text("Not scored")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    @ViewBuilder private var heroSentence: some View {
        switch heroStrain {
        case .noop:
            Text("\(WorkoutFormat.spokenDuration(WorkoutFacts.activeSeconds(displayRow) ?? 0)) of recorded activity.")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        case .whoop:
            Text("Scored by WHOOP and imported with the session.")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        case .unscored:
            Text("NOOP scores a workout from the heart rate recorded during it.")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "5:40 PM – 6:14 PM": when the session ran, in the person's clock.
    private var timeRange: String {
        let start = AppClock.hourMinute(startDate)
        guard displayRow.endTs > displayRow.startTs else { return start }
        return String(localized: "\(start) – \(AppClock.hourMinute(Date(timeIntervalSince1970: TimeInterval(displayRow.endTs))))",
                      comment: "The clock times a workout started and ended, e.g. 5:40 PM – 6:14 PM. Order and punctuation may change.")
    }

    /// "from 5:40 PM to 6:14 PM": the same range, as it is spoken (a dash is often skipped, leaving two bare times).
    private var spokenTimeRange: String {
        let start = AppClock.hourMinute(startDate)
        guard displayRow.endTs > displayRow.startTs else { return start }
        return String(localized: "from \(start) to \(AppClock.hourMinute(Date(timeIntervalSince1970: TimeInterval(displayRow.endTs))))")
    }

    /// "Heart rate only 10.0 → With your sets 15.1" and what it includes, or the one line that says why the sets are not counted.
    private func liftStrainNote(_ note: WorkoutLiftStrainNote) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let line = note.line {
                Text(verbatim: line)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
            }
            Text(verbatim: note.caption)
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: note.spoken))
    }

    private func comparedToUsual(_ delta: Double) -> some View {
        HStack(alignment: .center, spacing: NoopMetrics.space2) {
            Text("Compared to your usual")
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
            Spacer(minLength: NoopMetrics.space2)
            StatePill(LocalizedStringKey(delta.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always()))),
                      tone: delta >= 0 ? .positive : .neutral, showsDot: false)
                .fixedSize()
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Overview

    @ViewBuilder private var overview: some View {
        tiles
        WorkoutHeartRateRecoveryCard(workout: displayRow, maxHR: Double(profile.hrMax))
        if loaded, zoneMinutes.map({ $0.reduce(0, +) > 0 }) == true {
            FlatSectionSeparator()
            zones
        }
    }

    private var tiles: some View {
        let all = WorkoutDetailTiles.make(for: displayRow, unitSystem: unitSystem)
        let columns = typeSize.isAccessibilitySize ? 1 : 2
        let rows = stride(from: 0, to: all.count, by: columns).map { Array(all[$0..<min($0 + columns, all.count)]) }
        return Grid(horizontalSpacing: NoopMetrics.space3, verticalSpacing: NoopMetrics.space3) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, pair in
                GridRow {
                    ForEach(pair) { tile($0) }
                    if pair.count < columns { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                }
            }
        }
    }

    private func tile(_ tile: WorkoutDetailTile) -> some View {
        let accent: Color
        let label: LocalizedStringKey
        switch tile.kind {
        case .distance: (label, accent) = ("Distance", DomainTint.workout.accent)
        case .time: (label, accent) = ("Duration", DomainTint.workout.accent)
        case .pace: (label, accent) = ("Avg pace", DomainTint.workout.accent)
        case .speed: (label, accent) = ("Avg speed", DomainTint.workout.accent)
        case .averageHR: (label, accent) = ("Avg HR", DomainTint.heart.accent)
        case .maxHR: (label, accent) = ("Max HR", DomainTint.heart.accent)
        case .calories: (label, accent) = ("Calories", StrandPalette.metricAmber)
        }
        return StatTile(label: label, value: tile.value, accent: accent)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(Text(verbatim: tile.spokenValue))
    }

    @ViewBuilder private var zones: some View {
        if let minutes = zoneMinutes {
            WorkoutZoneSummary(minutes: minutes, timeline: zoneTimeline, heartRate: heartRate,
                               imported: zonesFromImport, start: displayRow.startTs, zoneSet: zoneSet,
                               curveName: String(localized: "Heart rate during \(sportName)"),
                               onOpenHeartRate: { detailTab = .heartRate })
        }
    }

    // MARK: - Heart rate

    @ViewBuilder private var heartRateSection: some View {
        FlatSection("Heart rate", systemImage: "heart.fill", tint: .heart) {
            if let series = heartRate {
                VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
                    WorkoutHeartRateCurve(
                        series: series, start: displayRow.startTs,
                        accessibilityName: String(localized: "Heart rate during \(sportName)"))
                    StatFooter(items: [
                        (String(localized: "Avg"), "\(Int(series.average.rounded()))"),
                        (String(localized: "Peak"), "\(Int(series.peak.rounded()))"),
                        (String(localized: "Low"), "\(Int(series.low.rounded()))"),
                    ])
                    // #18: the row's Avg HR can be EDITED on the manual sheet while the graph, zones and Strain stay
                    // from the recorded session (preservingCaptured keeps the captured strain/zones). When the typed
                    // average disagrees materially with this trace's own mean AND the row carries that captured
                    // strain/zones, say so plainly. We do NOT re-score from the typed number.
                    if WorkoutDetailRules.averageWasEdited(
                        displayRow, traceMean: series.samples.map(\.bpm).reduce(0, +) / Double(series.samples.count)) {
                        Text("The average above was edited. The graph, zones and Strain stay from the recorded session.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if loaded {
                emptyNote("No heart-rate samples were recorded over this session's window.")
            }
        }
    }

    // MARK: - Map

    @ViewBuilder private var mapSections: some View {
        if hasDrawableRoute {
            route
            FlatSectionSeparator()
        }
        elevation
    }

    /// The captured-route section: a MapKit map of the polyline with start/end markers, plus distance and pace read
    /// off the route. Shown ONLY when ≥2 points were captured — honest "no map" otherwise (a Mac with no GPS, denied
    /// permission, or a non-distance sport never produce a route).
    private var route: some View {
        FlatSection("Route", systemImage: "mappin.and.ellipse", tint: .workout,
                    trailing: .text(distanceLabel(displayRow.distanceM))) {
            VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
                WorkoutRouteMap(segments: routeSegments)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.radius3, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: NoopMetrics.radius3, style: .continuous)
                        .stroke(StrandPalette.hairline, lineWidth: 1))
                    .accessibilityLabel(routeAccessibilityLabel)
                FactStrip(facts: routeFacts)
                Text("Your GPS route is stored on your device. It leaves the app only when you choose to share or export it.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                routeExportControls
            }
        }
    }

    @ViewBuilder private var routeExportControls: some View {
        if let routeGPXFile {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                if let routeFITFile {
                    Menu {
                        ShareLink(item: routeGPXFile, preview: SharePreview(routeGPXFile.filename)) {
                            Text("GPX (most apps)")
                        }
                        .accessibilityIdentifier("workout.route.export.gpx")
                        ShareLink(item: routeFITFile, preview: SharePreview(routeFITFile.filename)) {
                            Text("FIT (Garmin, Strava)")
                        }
                        .accessibilityIdentifier("workout.route.export.fit")
                    } label: {
                        routeShareLabel
                    }
                    .accessibilityIdentifier("workout.route.export")
                } else {
                    ShareLink(item: routeGPXFile, preview: SharePreview(routeGPXFile.filename)) {
                        routeShareLabel
                    }
                    .accessibilityIdentifier("workout.route.export.gpx")
                }
                Text("Includes time and distance. Heart rate isn’t added.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if savedRoute?.hasUnmeasuredSegments == true {
                    Text("Only portions with recorded timestamps are exported. Older portions remain visible on this map.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if preparingRouteExports {
            ProgressView("Preparing route files…")
                .font(StrandFont.footnote)
        } else if let savedRoute, !savedRoute.hasExportableMeasurements {
            Text("This route can’t be exported because it was saved without timing data.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let routeExportError {
            Text(routeExportError)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Plain text with a glyph, no capsule: the one control for sharing the route.
    private var routeShareLabel: some View {
        Label("Share route", systemImage: "square.and.arrow.up")
            .font(StrandFont.subhead.weight(.semibold))
            .foregroundStyle(StrandPalette.textPrimary)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
    }

    @MainActor
    private func prepareRouteExports(route: WorkoutRoute?, startTs: Int, sport: String) async {
        let requestID = UUID()
        routeExportRequestID = requestID
        routeGPXFile = nil
        routeFITFile = nil
        routeExportError = nil
        preparingRouteExports = false
        guard let route, route.hasExportableMeasurements else { return }
        preparingRouteExports = true
        defer {
            if routeExportRequestID == requestID { preparingRouteExports = false }
        }
        let worker = Task.detached(priority: .userInitiated) {
            var gpx: WorkoutRouteExportFile?
            var fit: WorkoutRouteExportFile?
            var errorMessage: String?
            do {
                try Task.checkCancellation()
                gpx = try WorkoutRouteExportService.file(format: .gpx, route: route, startTs: startTs, sport: sport)
                try Task.checkCancellation()
                fit = try WorkoutRouteExportService.file(format: .fit, route: route, startTs: startTs, sport: sport)
            } catch {
                errorMessage = error.localizedDescription
            }
            return (gpx, fit, errorMessage)
        }
        let prepared = await withTaskCancellationHandler {
            await worker.value
        } onCancel: { worker.cancel() }
        guard !Task.isCancelled, routeExportRequestID == requestID else { return }
        routeGPXFile = prepared.0
        routeFITFile = prepared.1
        routeExportError = prepared.2
    }

    private var routeFacts: [FactStrip.Fact] {
        var facts: [FactStrip.Fact] = [.init("Distance", value: distanceLabel(displayRow.distanceM))]
        if let pace = WorkoutPace.perUnit(displayRow, system: unitSystem) {
            facts.append(.init("Avg pace", value: WorkoutFormat.pace(pace, system: unitSystem),
                               spokenValue: WorkoutFormat.spokenPace(pace, system: unitSystem)))
        } else if let speed = WorkoutSpeed.perHour(displayRow, system: unitSystem) {
            facts.append(.init("Avg speed", value: WorkoutSpeed.text(speed, system: unitSystem)))
        }
        facts.append(.init("Points", value: routePointCount.formatted()))
        return facts
    }

    /// Elevation is not persisted by the current workout/route model. Keep the
    /// reference row present and honest instead of fabricating gain from a 2D polyline.
    private var elevation: some View {
        FlatSection("Elevation", systemImage: "mountain.2", tint: .workout) {
            Text("Not recorded")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var routeAccessibilityLabel: String {
        let dist = distanceLabel(displayRow.distanceM)
        return String(localized: "Map of your \(sportName) route, \(dist).")
    }

    // MARK: - Bits

    private func emptyNote(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func distanceLabel(_ m: Double?) -> String {
        guard let m, m > 0 else { return WidgetMetrics.missingValue }
        return UnitFormatter.distanceFromMeters(m, system: unitSystem)
    }
}

// MARK: - Route map (#524)
//
// A MapKit map of the captured route polyline, drawn with start (green) + end (red) markers — the Apple
// analogue of Android's `RouteCanvas`, but on real map tiles. Built as a platform-bridged representable
// around `MKMapView` so it runs on BOTH iOS 17 and macOS 13 (SwiftUI's newer `Map { MapPolyline }` needs
// iOS 17 / macOS 14, and the macOS deployment target is 13). The map is offline-capable: MapKit caches
// tiles locally and the route itself is on-device — NOOP never sends the route anywhere.

#if canImport(MapKit) && canImport(UIKit)
import UIKit
typealias RouteMapRepresentable = UIViewRepresentable
#elseif canImport(MapKit) && canImport(AppKit)
import AppKit
typealias RouteMapRepresentable = NSViewRepresentable
#endif

#if canImport(MapKit)
struct WorkoutRouteRenderIdentity: Equatable {
    let segments: [[RouteMath.LatLng]]
    let showsEndpoints: Bool
}

struct WorkoutRouteMap: RouteMapRepresentable {
    let segments: [[RouteMath.LatLng]]
    let showsEndpoints: Bool

    init(points: [RouteMath.LatLng], showsEndpoints: Bool = true) {
        segments = points.isEmpty ? [] : [points]
        self.showsEndpoints = showsEndpoints
    }

    init(segments: [[RouteMath.LatLng]], showsEndpoints: Bool = true) {
        self.segments = segments
        self.showsEndpoints = showsEndpoints
    }

    private var coordinateSegments: [[CLLocationCoordinate2D]] {
        segments.map {
            $0.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func makeMap(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsUserLocation = false
        configure(map, coordinator: context.coordinator)
        return map
    }

    /// Draw the polyline + start/end pins and frame the route. Replaces any existing overlays so a
    /// re-render doesn't stack them.
    private func configure(_ map: MKMapView, coordinator: Coordinator) {
        let identity = WorkoutRouteRenderIdentity(
            segments: segments,
            showsEndpoints: showsEndpoints)
        guard coordinator.accepts(identity) else { return }
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)
        let coordinates = coordinateSegments.filter { $0.count >= 2 }
        guard !coordinates.isEmpty else { return }
        let lines = coordinates.map { MKPolyline(coordinates: $0, count: $0.count) }
        map.addOverlays(lines)

        if showsEndpoints {
            let start = MKPointAnnotation()
            start.coordinate = coordinates.first!.first!
            start.title = String(localized: "Start")
            let end = MKPointAnnotation()
            end.coordinate = coordinates.last!.last!
            end.title = String(localized: "Finish")
            map.addAnnotations([start, end])
        }

        // Frame the whole route with a little padding so the line isn't flush to the edges.
        let rect = lines.dropFirst().reduce(lines[0].boundingMapRect) {
            $0.union($1.boundingMapRect)
        }
        let inset = UIEdgeInsetsLikePadding
        map.setVisibleMapRect(rect, edgePadding: inset, animated: false)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var renderedIdentity: WorkoutRouteRenderIdentity?

        func accepts(_ identity: WorkoutRouteRenderIdentity) -> Bool {
            guard renderedIdentity != identity else { return false }
            renderedIdentity = identity
            return true
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: line)
            // The route is the workout domain's blue, distinct from the physiological zone colours.
            r.strokeColor = RoutePlatformColor.route
            r.lineWidth = 4
            r.lineJoin = .round
            r.lineCap = .round
            return r
        }
    }

    #if canImport(UIKit)
    private var UIEdgeInsetsLikePadding: UIEdgeInsets { UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24) }
    func makeUIView(context: Context) -> MKMapView { makeMap(context: context) }
    func updateUIView(_ map: MKMapView, context: Context) {
        configure(map, coordinator: context.coordinator)
    }
    #elseif canImport(AppKit)
    private var UIEdgeInsetsLikePadding: NSEdgeInsets { NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24) }
    func makeNSView(context: Context) -> MKMapView { makeMap(context: context) }
    func updateNSView(_ map: MKMapView, context: Context) {
        configure(map, coordinator: context.coordinator)
    }
    #endif
}

/// The route stroke colour as a platform colour (MapKit's renderer can't take a SwiftUI `Color`). It comes from the
/// workout domain's token, so the line wears the same blue as the rest of a session's screens.
private enum RoutePlatformColor {
    #if canImport(UIKit)
    static var route: UIColor { UIColor(DomainTint.workout.accent) }
    #elseif canImport(AppKit)
    static var route: NSColor { NSColor(DomainTint.workout.accent) }
    #endif
}
#else
/// Platforms without MapKit (none we ship, but keeps the type resolvable): no route map.
struct WorkoutRouteMap: View {
    let segments: [[RouteMath.LatLng]]

    init(points: [RouteMath.LatLng], showsEndpoints: Bool = true) {
        segments = points.isEmpty ? [] : [points]
    }

    init(segments: [[RouteMath.LatLng]], showsEndpoints: Bool = true) {
        self.segments = segments
    }

    var body: some View { Color.clear }
}
#endif

#if DEBUG
#Preview("Workout Detail") {
    NavigationStack {
        WorkoutDetailView(row: WorkoutRow(
            startTs: Int(Date().timeIntervalSince1970) - 3600,
            endTs: Int(Date().timeIntervalSince1970),
            sport: "Running", source: "whoop", durationS: 3600, energyKcal: 712,
            avgHr: 152, maxHr: 178, strain: 14.2, distanceM: 10_400,
            zonesJSON: #"{"z1":12.5,"z2":28.0,"z3":33.5,"z4":18.0,"z5":6.0}"#, notes: nil))
            .environmentObject(Repository(deviceId: "preview"))
    }
    .frame(width: 1040, height: 940)
    .preferredColorScheme(.dark)
}
#endif
