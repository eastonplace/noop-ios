import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Start a workout
//
// The Apple-side entry point for LIVE tracking, mirroring Android's StartWorkoutSheet (WorkoutStart.kt): pick a
// named sport from the shared WorkoutCatalog, then begin the session. A host presents this and forwards the chosen
// name to `AppModel.startWorkout(sport:)`. Free-text isn't offered here (a live start is a quick tap from a fixed
// list); an unusual sport can still be set afterwards via the manual edit sheet's free-text field.
//
// The page, in the widget design language, in the order people reach for things:
//  • the Lift card (a lifting session is its own flow, so it leads);
//  • Recent sports as one-tap chips, and the sheet opens on the last one used;
//  • what is selected, with a GPS pill for a route sport (ready only once location is allowed) and an outdoor /
//    treadmill choice for a run;
//  • every activity in the catalogue, searchable, the selected one marked;
//  • keep-screen-awake, the last workout and the last route;
//  • one pinned button that says what it will do ("Start Run").
//
// The same picker names a merged session's sport (`Purpose.nameMergedSession`), in a short sheet.

struct StartWorkoutSheet: View {
    /// What the picker is for.
    enum Purpose: Equatable {
        /// Begin a live workout in the chosen sport.
        case start
        /// Name the sport of a merged session whose sessions had none (they were bare detected bouts).
        case nameMergedSession
    }

    /// Called with the chosen sport name once the user confirms. The host wires this to `model.startWorkout(sport:)`
    /// (and presents the live workout view), or to the merge it is naming.
    let onStart: (_ sport: String) -> Void

    private let purpose: Purpose
    private let dismissAfterStart: Bool

    /// `initialSport` is the sport the sheet opens on; nil opens on the most recent one (running before there is
    /// one). A merged session opens on "Other", the honest label for sessions that had none.
    init(purpose: Purpose = .start, initialSport: String? = nil, dismissAfterStart: Bool = true,
         onStart: @escaping (_ sport: String) -> Void) {
        self.onStart = onStart
        self.purpose = purpose
        self.dismissAfterStart = dismissAfterStart
        let recents = RecentSportsPrefs.recent()
        _recents = State(initialValue: recents)
        let opening: String
        if let initialSport, let named = WorkoutCatalog.sport(named: initialSport) {
            opening = named.name
        } else if purpose == .nameMergedSession {
            opening = WorkoutCatalog.defaultSportName
        } else {
            opening = StartWorkoutChoices.initialSport(recents: recents)
        }
        _selected = State(initialValue: opening)
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var model: AppModel
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage("workoutKeepScreenOn") private var keepScreenOn = false
    @State private var query = ""
    @State private var selected: String
    @State private var recents: [String]
    @State private var recentRows: [WorkoutRow] = []
    @State private var showsLift = false
    /// Bumped when a tile in the activity grid is chosen, so the page brings the selection into view.
    @State private var summaryRequest = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase

    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var selectedSport: WorkoutCatalog.Sport? { WorkoutCatalog.sport(named: selected) }
    private var title: String { StartWorkoutChoices.displayTitle(for: selected) }
    private var inputShape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    var body: some View {
        Group {
            switch purpose {
            case .start:
                if showsLift {
                    LiftLogView(onBack: { showsLift = false })
                } else {
                    startPage
                }
            case .nameMergedSession:
                mergePicker
            }
        }
        .task(id: repo.refreshSeq) { recentRows = await repo.workoutRows(days: 365) }
        // The permission may have been changed in Settings while the app was away.
        .onAppear { model.gpsRecorder.refreshAvailability() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.gpsRecorder.refreshAvailability() }
        }
    }

    /// The pinned button's own action, and where a confirmed choice is remembered.
    ///
    /// The quick-action host keeps this picker alive while it presents the live workout above it. Every ordinary
    /// host still dismisses first and presents its next sheet from `onDismiss`, avoiding two competing sheet
    /// transitions in the same update cycle.
    private func confirm() {
        RecentSportsPrefs.recordSelection(selected)
        onStart(selected)
        if dismissAfterStart { dismiss() }
    }

    // MARK: - The start page

    private var startPage: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    liftCard
                    FlatSectionSeparator()
                    if !recentSports.isEmpty {
                        recentSection
                        FlatSectionSeparator()
                    }
                    selectionSection.id(Self.summaryID)
                    FlatSectionSeparator()
                    activitiesSection
                    FlatSectionSeparator()
                    setupSection
                    if recentRoute != nil || recentRows.first != nil {
                        FlatSectionSeparator()
                        lastTimeSection
                    }
                }
                .padding(.horizontal, NoopMetrics.space4)
                .padding(.bottom, NoopMetrics.space4)
            }
            // Choosing a tile far down the grid changes what sits above it (the run type, the GPS note), which would
            // move the grid under the finger. The page goes to the selection instead, where the change reads as the
            // answer to the tap. VoiceOver keeps its own focus, so it is left where it is.
            .onChange(of: summaryRequest) { _, _ in
                guard !voiceOverOn else { return }
                withAnimation(reduceMotion ? nil : .snappy) { proxy.scrollTo(Self.summaryID, anchor: .top) }
            }
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { startBar }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: true)
        #endif
    }

    private static let summaryID = "start.selection"

    private var header: some View { WorkoutSheetHeader(title: "Start a workout") }

    // MARK: Lift

    private var liftCard: some View {
        Button { showsLift = true } label: {
            Group {
                if typeSize.isAccessibilitySize {
                    // The words get the whole card: the glyph and the chevron share a line above them.
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        HStack {
                            WorkoutSportGlyph(symbol: "dumbbell.fill")
                            Spacer(minLength: NoopMetrics.space2)
                            liftChevron
                        }
                        liftTexts
                    }
                } else {
                    HStack(spacing: NoopMetrics.space3) {
                        WorkoutSportGlyph(symbol: "dumbbell.fill")
                        liftTexts
                        Spacer(minLength: NoopMetrics.space2)
                        liftChevron
                    }
                }
            }
            .padding(NoopMetrics.space3)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(StrandPalette.chipFill, in: RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous)
                .stroke(StrandPalette.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PaperPressStyle())
        .accessibilityElement(children: .combine)
    }

    private var liftTexts: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Lift weights")
                .font(StrandFont.body.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Choose a routine and track sets, reps and weight.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var liftChevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(StrandPalette.textTertiary)
            .accessibilityHidden(true)
    }

    // MARK: Recent

    private var recentSports: [WorkoutCatalog.Sport] { StartWorkoutChoices.recentSports(from: recents) }

    private var recentSection: some View {
        FlatSection("Recent", systemImage: "clock.arrow.circlepath", tint: .workout) {
            WorkoutRecentSportChips(sports: recentSports.map(\.name), selected: selected) { selected = $0 }
        }
    }

    // MARK: What is selected

    private var selectionSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        WorkoutSportGlyph(symbol: sportSymbol(selected))
                        selectionTitle
                        if isRouteSport { gpsPill }
                    }
                } else {
                    HStack(alignment: .center, spacing: NoopMetrics.space3) {
                        WorkoutSportGlyph(symbol: sportSymbol(selected))
                        selectionTitle
                        Spacer(minLength: NoopMetrics.space2)
                        if isRouteSport { gpsPill }
                    }
                }
            }
            .accessibilityElement(children: .combine)
            if WorkoutRunType.of(sport: selected) != nil {
                SegmentedPillControl(WorkoutRunType.allCases, selection: runType) { type in
                    switch type {
                    case .outdoor: String(localized: "Outdoor")
                    case .treadmill: String(localized: "Treadmill")
                    }
                }
                .accessibilityLabel("Run type")
            }
            if isRouteSport { gpsNote }
        }
    }

    private var selectionTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title)
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let setting = selectedSport.flatMap(StartWorkoutChoices.setting(for:)) {
                Text(setting == .outdoor ? "Outdoor workout" : "Indoor workout")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: GPS
    //
    // A route sport says what location allows right now, and only claims "GPS ready" once it is allowed. Before the
    // person has answered, starting asks once, so the pill is a neutral "GPS". When it is off, the pill says so and the
    // note offers Settings (unless a restriction means the person cannot change it).

    private var isRouteSport: Bool { selectedSport?.isDistanceSport == true }

    private var gpsPill: some View {
        GpsStatusReader(recorder: model.gpsRecorder) { availability in
            switch availability {
            case .ready: StatePill("GPS ready", tone: .positive)
            case .willAsk: StatePill("GPS", tone: .neutral)
            case .denied, .restricted: StatePill("Location off", tone: .warning)
            }
        }
        .fixedSize()
    }

    private var gpsNote: some View {
        GpsStatusReader(recorder: model.gpsRecorder) { availability in
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                Group {
                    switch availability {
                    case .ready: Text("Your route is saved on this device only.")
                    case .willAsk: Text("NOOP asks for your location when you start. Your route is saved on this device only.")
                    case .denied: Text("Location is off for NOOP, so this workout won't record a route. Turn it on in Settings.")
                    case .restricted: Text("Location is restricted on this device, so this workout won't record a route.")
                    }
                }
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                #if canImport(UIKit)
                if availability == .denied, let settings = URL(string: UIApplication.openSettingsURLString) {
                    Link(destination: settings) {
                        Text("Open Settings")
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(StrandPalette.link)
                            .frame(minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                }
                #endif
            }
        }
    }

    /// The run type as the control reads it: a run maps onto outdoor or treadmill, and choosing one sets the sport.
    private var runType: Binding<WorkoutRunType> {
        Binding(get: { WorkoutRunType.of(sport: selected) ?? .outdoor },
                set: { selected = $0.sportName })
    }

    // MARK: Every activity

    private var filtered: [WorkoutCatalog.Sport] { WorkoutCatalog.matching(query) }

    private var activitiesSection: some View {
        FlatSection("All activities", systemImage: "square.grid.2x2", tint: .workout) {
            WorkoutActivityGrid(selected: selected, hintsGps: true) { name in
                selected = name
                summaryRequest += 1
            }
        }
    }

    // MARK: Setup

    private var setupSection: some View {
        FlatSection("Setup", systemImage: "slider.horizontal.3", tint: .workout) {
            Toggle(isOn: $keepScreenOn) {
                HStack(spacing: NoopMetrics.space3) {
                    Image(systemName: "sun.max")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    Text("Keep screen awake")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
            }
            .toggleStyle(.switch)
            .tint(StrandPalette.ink)
            .frame(minHeight: 44)
            .accessibilityHint("Stops the screen dimming while a workout is recording")
        }
    }

    // MARK: Last time

    private var lastTimeSection: some View {
        FlatSection("Last time", systemImage: "arrow.counterclockwise", tint: .workout) {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                if let last = recentRows.first {
                    lastWorkoutRow(last)
                }
                if let recentRoute {
                    routeRow(recentRoute)
                }
            }
        }
    }

    private func lastWorkoutRow(_ row: WorkoutRow) -> some View {
        let shown = WorkoutRowPresentation.make(
            row, unitSystem: unitSystem, when: .dayAndTime, detail: .full)
        return VStack(alignment: .leading, spacing: 2) {
            Text("Last workout").font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
            WorkoutRowContent(presentation: shown)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func routeRow(_ recent: RecentRoute) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            WorkoutRouteMap(segments: recent.segments, showsEndpoints: false)
                .frame(width: 104, height: 78)
                .allowsHitTesting(false)
                .compositingGroup()
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Recent route").font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                Text(verbatim: WorkoutSource.displaySport(recent.row.sport))
                    .font(StrandFont.body.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                Text(verbatim: UnitFormatter.distanceFromMeters(recent.route.distanceM, system: unitSystem))
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                Text("Last used \(WorkoutFormat.day(Date(timeIntervalSince1970: TimeInterval(recent.row.startTs))))")
                    .font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private struct RecentRoute {
        let row: WorkoutRow
        let route: WorkoutRoute
        let segments: [[RouteMath.LatLng]]
    }

    /// D15: only a genuinely persisted, decodable route earns a route card. A distance-only workout stays
    /// route-less; no map placeholder or synthetic production fallback is shown.
    private var recentRoute: RecentRoute? {
        for row in recentRows {
            guard let route = RouteStore.load(startTs: row.startTs, sport: row.sport) else { continue }
            let segments = route.decodedSegments.filter { $0.count >= 2 }
            guard !segments.isEmpty else { continue }
            return RecentRoute(row: row, route: route, segments: segments)
        }
        return nil
    }

    // MARK: The pinned button

    private var startBar: some View {
        Button(action: confirm) {
            Label("Start \(title)", systemImage: "play.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryPillButtonStyle())
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.vertical, NoopMetrics.space3)
        // Opaque, so the activity tiles scrolling beneath it never show through the button's surroundings.
        .background(StrandPalette.surfaceBase.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(StrandPalette.hairline).frame(height: 1).accessibilityHidden(true) }
    }

    // MARK: - Naming a merged session

    /// The short sheet that names a merged session's sport: a heading, the activity list and one button.
    private var mergePicker: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            HStack(alignment: .top, spacing: NoopMetrics.space3) {
                WorkoutSportGlyph(symbol: "figure.run")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Name the merged session")
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("These sessions have no sport label yet. Pick one for the merged session.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            PaperSearchField("Search sport", text: $query, height: 44, cornerRadius: 10)
                .accessibilityLabel("Search sport")
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { sport in
                        Button { selected = sport.name } label: {
                            HStack(spacing: 6) {
                                Text(verbatim: sport.name)
                                    .font(StrandFont.body)
                                    .foregroundStyle(sport.name == selected ? StrandPalette.link : StrandPalette.textPrimary)
                                Spacer()
                                if sport.name == selected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(StrandPalette.success)
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                            .padding(.horizontal, 12)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(sport.name == selected ? .isSelected : [])
                    }
                }
            }
            .frame(maxHeight: 240)
            .background(StrandPalette.surfaceInset, in: inputShape)
            .overlay(inputShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))

            HStack(spacing: NoopMetrics.space3) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(minHeight: 44)
                Spacer()
                Button(action: confirm) {
                    Label("Merge as \(selected)", systemImage: "arrow.triangle.merge")
                }
                .buttonStyle(PrimaryPillButtonStyle())
            }
        }
        .padding(NoopMetrics.space6)
        #if os(macOS)
        .frame(width: 420)
        #else
        .frame(maxWidth: .infinity)
        .noopSheetPresentation(largeFirst: false)
        #endif
        .background(StrandPalette.surfaceOverlay)
    }
}

/// Reads the recorder's location permission and redraws its content when it changes. The sheet holds the recorder only
/// as part of the app model, which would not tell it the person had just answered the prompt.
private struct GpsStatusReader<Content: View>: View {
    @ObservedObject var recorder: GpsWorkoutRecorder
    @ViewBuilder let content: (GpsAvailability) -> Content

    var body: some View { content(recorder.availability) }
}

#if DEBUG
#Preview("Start") {
    StartWorkoutSheet { _ in }
        .preferredColorScheme(.dark)
}
#endif
