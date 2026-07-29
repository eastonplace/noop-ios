import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation
#if canImport(MapKit)
import MapKit
#endif

// MARK: - Workout detail (#410)
//
// A READ-ONLY drill-down for one tapped session, built ONLY from the locked Noop component system
// (NoopCard / ChartCard / SectionHeader / StatTile / SegmentBar idiom) so it sits in the same
// instrument-grade, Strain-amber colour world as the Workouts list it opens from.
//
//   • a header (sport displayName · date · duration) with the source badge,
//   • a 3-up StatTile strip (avg HR · max HR · calories / distance),
//   • a GPS route map when the session recorded one on-device (#524) — a MapKit map of the captured
//     polyline with start/end markers, shown only when points were actually captured,
//   • an HR-curve ChartCard fed the workout's 5-min-ish HR buckets over [startTs, endTs],
//   • an HR-zones bar — imported per-workout zones when the row carries them, else the window's raw
//     HR samples binned into age-derived %HRmax zone-minutes (honestly labelled as approximate),
//   • the session's Strain/strain contribution when one was captured.
//
// Presented as a `.sheet` wrapped in a NavigationStack by WorkoutsView — these screens aren't hosted in
// a per-screen NavigationStack, so a sheet is the in-app drill-down idiom (mirrors HealthView opening
// MetricDetailView, StressView opening Breathe).

struct WorkoutDetailView: View {
    let row: WorkoutRow

    @EnvironmentObject private var repo: Repository
    @StateObject private var profile = ProfileStore()
    @Environment(\.dismiss) private var dismiss

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.whoop.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    /// Loaded HR curve over the session window (5-min-ish bucket means). Empty until loaded.
    @State private var hrPoints: [TrendPoint] = []
    /// Per-zone MINUTES for the zones bar: imported zones (duration-weighted) when present, else the
    /// window's raw HR samples binned into age-derived %HRmax zones. nil = no zone split to show.
    @State private var zoneMinutes: [Double]? = nil
    /// True when the zones bar came from imported WHOOP percentages (vs derived from raw strap HR).
    @State private var zonesFromImport = false
    @State private var loaded = false

    /// The GPS route captured for this session on-device (#524), if any. Decoded from `RouteStore` by the
    /// row's natural key. nil = no route was recorded (honest — the map only shows when points exist).
    @State private var routeSegments: [[RouteMath.LatLng]] = []
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
    @State private var detailTab: DetailTab = .overview
    @State private var usualEffort: Double?
    @State private var refreshedRow: WorkoutRow?

    /// The tap payload is only a routing key. Resolve it again after a durable workout
    /// finish so detail never keeps presenting the pre-save or pre-rescore snapshot.
    private var displayRow: WorkoutRow { refreshedRow ?? row }

    var body: some View {
        ScreenScaffold(title: "\(WorkoutSource.displaySport(displayRow.sport)) Summary",
                       subtitle: "\(dateLabel(displayRow.startTs))",
                       // PERF: chart/map-heavy column (a MapKit route map, the session HR curve, the
                       // zone-split chart and the effort card). The LazyVStack path builds the off-screen
                       // ones on demand — byte-identical layout — so a tall detail doesn't materialise the
                       // map + both charts before the header is even on screen.
                       lazy: true,
                       // The day-of-sky liquid backdrop, matching the Workouts list this detail opens from
                       // and every other liquid screen. Fixed and full-bleed; it does not scroll. This
                       // screen is presented in a sheet wrapped in a NavigationStack by WorkoutsView, so it
                       // needs no extra macOS NavigationStack of its own.
                       topBackground: nil,
                       trailing: {
                           Image(systemName: "square.and.arrow.up")
                               .font(.system(size: 15, weight: .medium))
                               .foregroundStyle(StrandPalette.textPrimary)
                       }) {
            paperEffortHero
            SegmentedPillControl(DetailTab.allCases, selection: $detailTab) { $0.label }
            switch detailTab {
            case .overview:
                paperStatsGrid
                WorkoutHeartRateRecoveryCard(
                    workout: displayRow,
                    maxHR: Double(profile.hrMax)
                )
                paperZonesCard
            case .heartRate:
                hrCurveCard
            case .map:
                paperRouteCard
                paperElevationCard
            }
            NoopButton("Save workout", systemImage: "checkmark", kind: .primary,
                       fullWidth: true) { dismiss() }
        }
        .toolbar {
            // A Done affordance for the sheet on both platforms (iOS gets the grabber too).
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task { await load() }
    }

    // MARK: - Load

    private func load() async {
        let history = await repo.workoutRows(days: 4000)
        let target = history.first {
            $0.startTs == row.startTs && $0.sport == row.sport
        } ?? row

        // #524: the GPS route, if this session recorded one on-device. A cheap UserDefaults read keyed
        // by the row's natural key (startTs + sport); decoded to points only when ≥2 were captured so the
        // map only ever draws a real route.
        let loadedRouteSegments: [[RouteMath.LatLng]] = {
            guard let r = RouteStore.load(startTs: target.startTs, sport: target.sport) else { return [] }
            return r.decodedSegments.filter { $0.count >= 2 }
        }()

        // HR curve over the exact session window — a finer bucket than the 24h chart so a short run
        // still reads as a curve, not a handful of points.
        let buckets = await repo.workoutHrBuckets(from: target.startTs, to: target.endTs)
        let points = buckets.map { TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.bpm) }
        let comparison = history.filter {
            !($0.startTs == target.startTs && $0.sport == target.sport)
                && $0.sport.caseInsensitiveCompare(target.sport) == .orderedSame
        }.compactMap { StrainResolver.canonicalWorkout($0)?.storedValue }
        let typical = comparison.isEmpty ? nil : comparison.reduce(0, +) / Double(comparison.count)

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
        if minutes == nil {
            minutes = await repo.workoutZoneMinutes(from: target.startTs, to: target.endTs, age: profile.age)
        }

        await MainActor.run {
            self.routeSegments = loadedRouteSegments
            self.refreshedRow = target
            self.hrPoints = points
            self.zoneMinutes = minutes
            self.zonesFromImport = fromImport
            self.usualEffort = typical
            self.loaded = true
        }
    }

    // MARK: - Header

    private var paperEffortHero: some View {
        let storedStrain = StrainResolver.canonicalWorkout(displayRow)?.storedValue
        let display = storedStrain.map { UnitFormatter.effortValue($0, scale: effortScale) }
        let maximum: Double = 21
        return PaperCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("RUN STRAIN")
                    .font(StrandFont.sectionOverline)
                    .tracking(StrandFont.sectionOverlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                HStack(spacing: 16) {
                    if let display {
                        ScoreRing(value: display, range: 0...maximum,
                                  accent: StrandPalette.strainAccent,
                                  size: NoopMetrics.heroRingDiameter,
                                  lineWidth: NoopMetrics.heroRingLineWidth,
                                  format: { String(format: "%.1f", $0) },
                                  centerCaption: nil)
                    } else {
                        ZStack {
                            Circle().stroke(StrandPalette.inset,
                                            lineWidth: NoopMetrics.heroRingLineWidth)
                            Text("—").font(StrandFont.ringScoreLarge)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        .frame(width: NoopMetrics.heroRingDiameter,
                               height: NoopMetrics.heroRingDiameter)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Good Work")
                            .font(StrandFont.cardTitle)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("This run maintained moderate effort.")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                Divider().overlay(StrandPalette.hairline)
                HStack {
                    Text("Compared to your usual")
                        .font(StrandFont.micro)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Spacer()
                    if let delta = effortDelta {
                        StatusBadge(LocalizedStringKey(String(format: "%+.1f", delta)),
                                    style: .upToDate,
                                    tint: delta >= 0 ? StrandPalette.success : StrandPalette.textSecondary)
                    } else {
                        Text("—").font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
    }

    private var effortDelta: Double? {
        guard let strain = StrainResolver.canonicalWorkout(displayRow)?.storedValue,
              let usualEffort else { return nil }
        return UnitFormatter.effortValue(strain, scale: effortScale)
            - UnitFormatter.effortValue(usualEffort, scale: effortScale)
    }

    private var paperStatsGrid: some View {
        PaperCard(padding: 0) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 3), spacing: 0) {
                paperStat("DISTANCE", distanceLabel(displayRow.distanceM), nil)
                paperStat("TIME", durationLabel(displayRow.durationS), nil)
                paperStat("AVG PACE", paceLabel, nil)
                paperStat("AVG HR", displayRow.avgHr.map(String.init) ?? "—", "bpm")
                paperStat("MAX HR", displayRow.maxHr.map(String.init) ?? "—", "bpm")
                paperStat("CALORIES", displayRow.energyKcal.map { grouped($0) } ?? "—", "kcal")
            }
        }
    }

    private func paperStat(_ label: String, _ value: String, _ unit: String?) -> some View {
        ValueToken(
            LocalizedStringKey(label),
            value: unit.map { "\(value) \($0)" } ?? value
        )
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .padding(.horizontal, 11)
        .overlay(alignment: .trailing) { Rectangle().fill(StrandPalette.hairline).frame(width: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(StrandPalette.hairline).frame(height: 1) }
    }

    @ViewBuilder private var paperZonesCard: some View {
        if let zones = zoneMinutes, zones.reduce(0, +) > 0 {
            let total = zones.reduce(0, +)
            let zoneSet = profile.hrMax > 0
                ? HRZones.zones(maxHR: Double(profile.hrMax), source: "profile") : nil
            PaperCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("HEART RATE ZONES")
                            .font(StrandFont.sectionOverline)
                            .tracking(StrandFont.sectionOverlineTracking)
                        Spacer()
                        Text("View Details")
                            .font(StrandFont.caption.weight(.semibold))
                            .foregroundStyle(StrandPalette.link)
                    }
                    .foregroundStyle(StrandPalette.textSecondary)
                    ZoneBars((1...5).map { zone in
                        let minutes = zones[zone - 1]
                        return ZoneBarItem(zone: zone,
                                           fraction: minutes / total,
                                           duration: shortZoneDuration(minutes),
                                           bpmRange: zoneSet?.bpmRangeLabel(forZone: zone))
                    })
                }
            }
        }
    }

    @ViewBuilder private var paperRouteCard: some View {
        if hasDrawableRoute {
            PaperCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "mappin.and.ellipse")
                            .foregroundStyle(StrandPalette.link)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ROUTE")
                                .font(StrandFont.sectionOverline)
                                .tracking(StrandFont.sectionOverlineTracking)
                            Text("\(WorkoutSource.displaySport(displayRow.sport)) · \(distanceLabel(displayRow.distanceM))")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        Spacer()
                    }
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(16)
                    WorkoutRouteMap(segments: routeSegments)
                        .frame(height: 180)
                        .accessibilityLabel(routeAccessibilityLabel)
                }
            }
        }
    }

    /// Elevation is not persisted by the current workout/route model. Keep the
    /// reference row present and honest instead of fabricating gain from a 2D polyline.
    private var paperElevationCard: some View {
        PaperCard(padding: 12) {
            HStack(spacing: 10) {
                Image(systemName: "mountain.2.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.strainAccent)
                    .frame(width: NoopMetrics.iconCircleDiameter,
                           height: NoopMetrics.iconCircleDiameter)
                    .background(StrandPalette.strainAccent.opacity(0.10), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("ELEVATION").strandOverline()
                    Text("Not recorded")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer()
                Text("—")
                    .font(StrandFont.statValue)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    private func shortZoneDuration(_ minutes: Double) -> String {
        let total = max(0, Int(minutes.rounded()))
        return total >= 60 ? "\(total / 60)h\(total % 60)m" : "\(total)m"
    }

    private var headerCard: some View {
        NoopCard(tint: StrandPalette.effortColor) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: sportSymbol(displayRow.sport))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(StrandPalette.effortColor)
                    .frame(width: 44, height: 44)
                    .background(StrandPalette.effortColor.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(WorkoutSource.displaySport(displayRow.sport))
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Text("\(dateLabel(displayRow.startTs)) · \(timeRangeLabel(displayRow.startTs, displayRow.endTs))")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 0)
                sourceBadge(displayRow.source)
            }
        }
    }

    // MARK: - Stat strip

    @ViewBuilder private var statStrip: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: NoopMetrics.gap)],
                  alignment: .leading, spacing: NoopMetrics.gap) {
            StatTile(label: "Duration",
                     value: durationLabel(displayRow.durationS),
                     caption: String(localized: "active"),
                     accent: StrandPalette.effortColor)
            StatTile(label: "Avg HR",
                     value: displayRow.avgHr.map { "\($0)" } ?? "–",
                     caption: displayRow.avgHr != nil ? "bpm" : nil,
                     accent: displayRow.avgHr != nil ? StrandPalette.metricRose : StrandPalette.textTertiary)
            StatTile(label: "Max HR",
                     value: displayRow.maxHr.map { "\($0)" } ?? "–",
                     caption: displayRow.maxHr != nil ? "bpm" : nil,
                     accent: displayRow.maxHr != nil ? StrandPalette.metricRose : StrandPalette.textTertiary)
            StatTile(label: "Calories",
                     value: displayRow.energyKcal.map { grouped($0) } ?? "–",
                     caption: displayRow.energyKcal != nil ? "kcal" : nil,
                     accent: displayRow.energyKcal != nil ? StrandPalette.metricAmber : StrandPalette.textTertiary)
            if displayRow.distanceM != nil {
                StatTile(label: "Distance",
                         value: distanceLabel(displayRow.distanceM),
                         caption: String(localized: "covered"),
                         accent: StrandPalette.metricCyan)
            }
        }
    }

    // MARK: - GPS route (#524)

    /// The captured-route card: a MapKit map of the polyline with start/end markers, plus distance and
    /// pace read off the route. Shown ONLY when ≥2 points were captured — honest "no map" otherwise (a
    /// Mac with no GPS, denied permission, or a non-distance sport never produce a route).
    @ViewBuilder private var routeCard: some View {
        if hasDrawableRoute {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Route", overline: "Recorded on device",
                              trailing: distanceLabel(displayRow.distanceM))
                NoopCard(padding: 0, tint: StrandPalette.effortColor) {
                    VStack(alignment: .leading, spacing: 0) {
                        WorkoutRouteMap(segments: routeSegments)
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius,
                                                        style: .continuous))
                            .accessibilityLabel(routeAccessibilityLabel)
                        HStack(spacing: 0) {
                            routeStat(String(localized: "Distance"), distanceLabel(displayRow.distanceM),
                                      tint: StrandPalette.metricCyan)
                            routeStat(String(localized: "Avg pace"), paceLabel, tint: StrandPalette.effortBright)
                            routeStat(String(localized: "Points"), "\(routePointCount)", tint: StrandPalette.textSecondary)
                        }
                        .padding(NoopMetrics.cardPadding)
                    }
                }
                Text("Your GPS route for this session, recorded and stored on your device. Nothing leaves your phone.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func routeStat(_ title: String, _ value: String, tint: Color) -> some View {
        ValueToken(LocalizedStringKey(title), value: value, tint: tint)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Avg pace from the row's GPS distance + duration, in the user's unit system: "m:ss /km" (metric) or
    /// "m:ss /mi" (imperial). "–" when distance or duration is missing/zero (pace undefined — honest).
    private var paceLabel: String {
        guard let m = displayRow.distanceM, m > 0 else { return "–" }
        let secs = displayRow.durationS ?? Double(displayRow.endTs - displayRow.startTs)
        guard secs > 0 else { return "–" }
        let km = m / 1000.0
        let (perUnit, label): (Double, String) = unitSystem == .imperial
            ? (km * UnitFormatter.milesPerKilometer, "/mi")
            : (km, "/km")
        guard perUnit > 0 else { return "–" }
        let secsPerUnit = Int((secs / perUnit).rounded())
        return "\(secsPerUnit / 60):\(String(format: "%02d", secsPerUnit % 60)) \(label)"
    }

    private var routeAccessibilityLabel: String {
        let dist = distanceLabel(displayRow.distanceM)
        return String(localized: "Map of your \(WorkoutSource.displaySport(displayRow.sport)) route, \(dist).")
    }

    // MARK: - HR curve

    @ViewBuilder private var hrCurveCard: some View {
        if hrPoints.count > 1 {
            let values = hrPoints.map(\.value)
            let lo = max(0, (values.min() ?? 60) - 8)
            let hi = (values.max() ?? 180) + 8
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                ChartCard(
                    title: "HEART RATE",
                    subtitle: String(localized: "Beats per minute across the session"),
                    trailing: displayRow.avgHr.map { String(localized: "avg \($0)") },
                    tint: StrandPalette.effortColor
                ) {
                    TrendChart(
                        points: hrPoints,
                        gradient: StrandPalette.effortGradient,
                        valueRange: lo...hi,
                        showsArea: true,
                        valueFormat: { String(localized: "\(Int($0.rounded())) bpm") },
                        dateFormat: { Self.tooltipTime.string(from: $0) },
                        accessibilityLabel: String(localized: "Heart rate during \(WorkoutSource.displaySport(displayRow.sport))")
                    )
                } footer: {
                    ChartFooter([
                        ("Avg", displayRow.avgHr.map { String(localized: "\($0) bpm") } ?? "–"),
                        ("Peak", displayRow.maxHr.map { String(localized: "\($0) bpm") } ?? String(localized: "\(Int((values.max() ?? 0).rounded())) bpm")),
                        ("Low", String(localized: "\(Int((values.min() ?? 0).rounded())) bpm")),
                    ])
                }
                // #18: the row's Avg HR can be EDITED on the manual sheet while the graph, zones and Strain
                // stay from the recorded session (preservingCaptured keeps the captured strain/zones). When
                // the typed average disagrees materially with this trace's own mean AND the row carries that
                // captured strain/zones, say so plainly. We do NOT re-score from the typed number.
                if avgHrEditedDisclosure(traceMean: values.reduce(0, +) / Double(values.count)) {
                    Text("The average above was edited. The graph, zones and Strain stay from the recorded session.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if loaded {
            NoopCard {
                emptyNote("No heart-rate samples were recorded over this session's window.")
            }
        }
    }

    /// #18: whether the displayed Avg HR was edited away from what this HR trace implies. True only when the
    /// row carries CAPTURED strain or zones (so the graph/zones/Strain are from a real recording, not the
    /// typed value) AND the row's avgHr differs from the trace mean by more than a small tolerance. The
    /// tolerance absorbs ordinary rounding/bucketing drift so an unedited session never trips the note.
    private func avgHrEditedDisclosure(traceMean: Double) -> Bool {
        guard let avg = displayRow.avgHr,
              StrainResolver.canonicalWorkout(displayRow) != nil || displayRow.zonesJSON != nil
        else { return false }
        return abs(Double(avg) - traceMean) > 3
    }

    // MARK: - HR zones

    @ViewBuilder private var zonesCard: some View {
        if let z = zoneMinutes, z.reduce(0, +) > 0 {
            let total = z.reduce(0, +)
            let busiest = z.indices.max(by: { z[$0] < z[$1] }) ?? 0
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("HR Zones",
                              overline: zonesFromImport ? "Whoop import" : "From strap HR",
                              trailing: String(localized: "\(Int(total.rounded()))m in zone"))
                NoopCard(tint: StrandPalette.effortColor) {
                    VStack(alignment: .leading, spacing: 12) {
                        GeometryReader { geo in
                            HStack(spacing: 2) {
                                ForEach(0..<5, id: \.self) { i in
                                    Rectangle()
                                        .fill(StrandPalette.hrZoneColor(i + 1))
                                        .frame(width: max(0, CGFloat(z[i] / total) * geo.size.width))
                                        .overlay {
                                            if i == busiest {
                                                Rectangle()
                                                    .strokeBorder(StrandPalette.textPrimary.opacity(0.85), lineWidth: 1.5)
                                            }
                                        }
                                }
                            }
                        }
                        .frame(height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(String(localized: "Heart-rate zone split: \((1...5).map { String(localized: "zone \($0) \(Int((z[$0 - 1] / total * 100).rounded())) percent") }.joined(separator: ", "))"))
                        Divider().overlay(StrandPalette.hairline)
                        HStack(spacing: 0) {
                            ForEach(0..<5, id: \.self) { i in
                                zoneStat(i + 1, minutes: z[i], total: total)
                            }
                        }
                        Text(zonesFromImport
                             ? "WHOOP's imported per-zone split for this session."
                             : "Time in each %HRmax zone, derived from the strap's heart rate over this window (approximate).")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
    }

    private func zoneStat(_ zone: Int, minutes: Double, total: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(StrandPalette.hrZoneColor(zone))
                    .frame(width: 9, height: 9)
                Text("Z\(zone)" as String).strandOverline()
            }
            Text("\(Int((minutes / max(total, 0.001) * 100).rounded()))%")
                .font(StrandFont.number(15))
                .foregroundStyle(StrandPalette.textPrimary)
            Text(durationLabel(minutes * 60))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Strain contribution

    private func effortCard(strain: Double) -> some View {
        // The session's Strain as the signature liquid gauge: a `PaperGauge` tinted Strain, filled to the
        // session's contribution on the user's selected scale, with the value counting up over it — the
        // same hero language as the Workouts list's Typical Strain gauge and the Sleep Sleep hero. The
        // explanatory sentence keeps its place beside the gauge.
        let displayValue = UnitFormatter.effortValue(strain, scale: effortScale)
        let scaleMax: Double = 21
        let fraction = max(0, min(1, displayValue / scaleMax))
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Strain", overline: "This session")
            NoopCard(tint: StrandPalette.effortColor) {
                HStack(alignment: .center, spacing: 18) {
                    ZStack {
                        // Static (posed) vessel — a compact liquid gauge inside a card, so it costs a single
                        // cached frame rather than a live canvas (same call as Trends' pip vessels).
                        PaperGauge(value: fraction, tint: StrandPalette.effortColor, animated: false)
                            .frame(width: 88, height: 88)
                        VStack(spacing: 0) {
                            // The session's Strain contribution ticks up to its value — the NOOP signature.
                            CountUpText(value: displayValue,
                                        format: { String(format: "%.1f", $0) },
                                        font: StrandFont.rounded(28),
                                        color: StrandPalette.textPrimary)
                                .shadow(color: .black.opacity(0.5), radius: 5, y: 1)
                        }
                        .allowsHitTesting(false)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(String(localized: "Strain \(UnitFormatter.effortDisplay(strain, scale: effortScale))"))
                    Spacer(minLength: 0)
                    Text("This session's contribution to the day's Strain, as captured during the workout.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 240, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Bits

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func sourceBadge(_ source: String) -> some View {
        let (label, tint): (String, Color) = {
            switch WorkoutSource.classify(source) {
            case .whoop:    return (String(localized: "Whoop"), StrandPalette.accent)
            case .apple:    return (String(localized: "Apple"), StrandPalette.metricCyan)
            case .detected: return (String(localized: "Detected"), StrandPalette.metricPurple)
            case .manual:   return (String(localized: "Manual"), StrandPalette.statusWarning)
            case .lifting:  return (String(localized: "Lifting"), StrandPalette.zone2)
            case .activityFile: return (String(localized: "File"), StrandPalette.metricAmber)
            }
        }()
        return SourceBadge("\(label)", tint: tint)
    }

    // MARK: - Formatting (kept local, matching WorkoutsView's rhythm)

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE d MMM yyyy"
        return f
    }()
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()
    private static let tooltipTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()

    private func dateLabel(_ ts: Int) -> String {
        Self.dateFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
    private func timeLabel(_ ts: Int) -> String {
        Self.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
    private func timeRangeLabel(_ start: Int, _ end: Int) -> String {
        end > start ? "\(timeLabel(start))-\(timeLabel(end))" : timeLabel(start)
    }
    private func durationLabel(_ s: Double?) -> String {
        guard let s, s > 0 else { return "–" }
        let total = Int(s.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return String(localized: "\(h)h \(m)m") }
        return String(localized: "\(m)m")
    }
    private func distanceLabel(_ m: Double?) -> String {
        guard let m, m > 0 else { return "–" }
        return UnitFormatter.distanceFromMeters(m, system: unitSystem)
    }
    private func grouped(_ v: Double) -> String {
        Self.intFmt.string(from: NSNumber(value: Int(v.rounded()))) ?? "\(Int(v.rounded()))"
    }
    private static let intFmt: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0; return f
    }()
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
        configure(map)
        return map
    }

    /// Draw the polyline + start/end pins and frame the route. Replaces any existing overlays so a
    /// re-render doesn't stack them.
    private func configure(_ map: MKMapView) {
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
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: line)
            // Paper run-flow reference: route is the constant navigation blue, distinct from
            // physiological zone colors. MapKit needs a platform color rather than SwiftUI Color.
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
    func updateUIView(_ map: MKMapView, context: Context) { configure(map) }
    #elseif canImport(AppKit)
    private var UIEdgeInsetsLikePadding: NSEdgeInsets { NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24) }
    func makeNSView(context: Context) -> MKMapView { makeMap(context: context) }
    func updateNSView(_ map: MKMapView, context: Context) { configure(map) }
    #endif
}

/// The route stroke colour as a platform colour (MapKit's renderer can't take a SwiftUI `Color`).
private enum RoutePlatformColor {
    #if canImport(UIKit)
    static let route = UIColor(red: 0.08, green: 0.45, blue: 0.96, alpha: 1.0)
    #elseif canImport(AppKit)
    static let route = NSColor(red: 0.08, green: 0.45, blue: 0.96, alpha: 1.0)
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
