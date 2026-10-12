#if os(iOS)
import Combine
import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - The setup page
//
// The first page of the workout journey: pick what to do, see that everything it needs is ready, press Start.
//
// In the order people reach for things:
//  • the sport (a run chooses outdoor or treadmill), the recent ones as one-tap chips, and every activity behind a chip;
//  • Ready: the strap, the GPS for a route sport, the day's strain target, the screen, the countdown;
//  • which number the live screen leads with, and the last time in this sport;
//  • a lifting session is its own flow, one row away;
//  • one pinned 88 pt Start that says what it will do. Tap it to start (with the countdown, when that is on); press and
//    hold it to start straight away.

struct WorkoutSetupPage: View, @preconcurrency Equatable {
    let initialSport: String?
    /// A lift is in progress, so starting would do nothing: the page says so above Start, disables it, and offers the lift.
    let blockedByLift: Bool
    let model: AppModel
    let onOpenLift: () -> Void
    /// Closes the journey's cover.
    let onClose: () -> Void
    /// Starts: the sport, whether the countdown comes first, and (for a route sport) whether the GPS has a lock, which the
    /// countdown says under its number.
    let onStart: (_ sport: String, _ countdown: Bool, _ gpsLocked: Bool?) -> Void

    /// What the page is made from, not what it does: the closures a host re-render hands over fresh never rebuild it.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.initialSport == rhs.initialSport && lhs.blockedByLift == rhs.blockedByLift && lhs.model === rhs.model
    }

    var body: some View {
        WorkoutSetupContent(initialSport: initialSport, blockedByLift: blockedByLift, model: model,
                            onOpenLift: onOpenLift, onClose: onClose, onStart: onStart)
    }
}

private struct WorkoutSetupContent: View {
    let blockedByLift: Bool
    let model: AppModel
    let onOpenLift: () -> Void
    let onClose: () -> Void
    let onStart: (String, Bool, Bool?) -> Void

    @EnvironmentObject private var repo: Repository
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(WorkoutPrefs.keepScreenOnKey) private var keepScreenOn = WorkoutPrefs.keepScreenOnDefault
    @AppStorage(WorkoutPrefs.countdownOnKey) private var countdownOn = WorkoutPrefs.countdownOnDefault
    @AppStorage(LiveWorkoutGlance.FocusPreference.key(for: .routePace)) private var focusRoutePace = ""
    @AppStorage(LiveWorkoutGlance.FocusPreference.key(for: .routeSpeed)) private var focusRouteSpeed = ""
    @AppStorage(LiveWorkoutGlance.FocusPreference.key(for: .indoor)) private var focusIndoor = ""
    @StateObject private var probe = GpsReadinessProbe()
    @StateObject private var strap: StrapConnectionWatcher
    @State private var selected: String
    @State private var recents: [String]
    @State private var rows: [WorkoutRow] = []
    @State private var today: WorkoutReadinessToday?
    @State private var showsLift = false
    @State private var showsActivities = false
    @State private var showsDevices = false
    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// Set when a press on Start became a hold, so the tap that ends it does not start a second time.
    @State private var startedByHold = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize

    private typealias Glance = LiveWorkoutGlance

    init(initialSport: String?, blockedByLift: Bool, model: AppModel, onOpenLift: @escaping () -> Void,
         onClose: @escaping () -> Void, onStart: @escaping (String, Bool, Bool?) -> Void) {
        self.blockedByLift = blockedByLift
        self.model = model
        self.onOpenLift = onOpenLift
        self.onClose = onClose
        self.onStart = onStart
        _strap = StateObject(wrappedValue: StrapConnectionWatcher(live: model.live))
        let recents = RecentSportsPrefs.recent()
        _recents = State(initialValue: recents)
        if let initialSport, let named = WorkoutCatalog.sport(named: initialSport) {
            _selected = State(initialValue: named.name)
        } else {
            _selected = State(initialValue: StartWorkoutChoices.initialSport(recents: recents))
        }
    }

    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var selectedSport: WorkoutCatalog.Sport? { WorkoutCatalog.sport(named: selected) }
    private var title: String { StartWorkoutChoices.displayTitle(for: selected) }
    private var isRouteSport: Bool { selectedSport?.isDistanceSport == true }

    var body: some View {
        Group {
            if showsLift {
                LiftLogView(onBack: { showsLift = false })
            } else {
                page
            }
        }
        .task(id: repo.refreshSeq) { await load() }
    }

    // MARK: Page

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                selectionSection
                FlatSectionSeparator()
                recentSection
                FlatSectionSeparator()
                WorkoutReadinessStrip(
                    showsGps: isRouteSport, probe: probe, live: model.live, today: today,
                    keepScreenOn: $keepScreenOn, countdownOn: $countdownOn, lowPowerMode: lowPowerMode,
                    onConnect: { showsDevices = true })
                FlatSectionSeparator()
                bigNumberSection
                FlatSectionSeparator()
                liftRow
            }
            .padding(.horizontal, NoopMetrics.space4)
            .padding(.bottom, NoopMetrics.space4)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) { WorkoutSheetHeader(title: "Start a workout", onClose: onClose) }
        .safeAreaInset(edge: .bottom, spacing: 0) { startBar }
        .sheet(isPresented: $showsActivities) {
            WorkoutActivityPickerSheet(selected: selected, onSelect: { selected = $0 })
        }
        .sheet(isPresented: $showsDevices) { WorkoutDevicesSheet(onClose: { showsDevices = false }) }
        .onAppear {
            probe.start()
            model.startRealtimeHR()
        }
        .onDisappear {
            probe.stop()
            model.stopRealtimeHR()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { probe.start() } else { probe.stop() }
        }
        // Posted on whatever thread noticed the change.
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)) { _ in lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled }
    }

    private func load() async {
        let found = await repo.workoutRows(days: 365, reconcileHR: false)
        guard !Task.isCancelled else { return }
        rows = found
        let recovery = repo.today?.recovery
        let stored = repo.canonicalStrain(for: Repository.logicalDayKey(Date()))?.storedValue
        today = WorkoutReadinessToday.make(recovery: recovery, soFar: stored.map(StrainScale.displayValue(fromStored:)))
    }

    // MARK: Sport

    private var selectionSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        WorkoutSportGlyph(symbol: sportSymbol(selected))
                        selectionTitle
                    }
                } else {
                    HStack(alignment: .center, spacing: NoopMetrics.space3) {
                        WorkoutSportGlyph(symbol: sportSymbol(selected))
                        selectionTitle
                        Spacer(minLength: NoopMetrics.space2)
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
        }
        .padding(.top, NoopMetrics.space2)
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

    /// The run type as the control reads it: a run maps onto outdoor or treadmill, and choosing one sets the sport.
    private var runType: Binding<WorkoutRunType> {
        Binding(get: { WorkoutRunType.of(sport: selected) ?? .outdoor }, set: { selected = $0.sportName })
    }

    private var recentSection: some View {
        let sports = StartWorkoutChoices.recentSports(from: recents).map(\.name)
        return FlatSection("Recent", systemImage: "clock.arrow.circlepath", tint: .workout) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                if !sports.isEmpty {
                    WorkoutRecentSportChips(sports: sports, selected: selected) { selected = $0 }
                }
                WidgetChipButton(title: "All activities", systemImage: "square.grid.2x2", showsChevron: true,
                                 accessibilityLabel: "All activities") { showsActivities = true }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Big number, last time

    private var sportClass: Glance.SportClass {
        Glance.sportClass(sport: selected, tracksRoute: isRouteSport && probe.readiness.canRecordRoute)
    }

    private var chosenFocus: Glance.Metric? {
        let raw: String
        switch sportClass {
        case .routePace: raw = focusRoutePace
        case .routeSpeed: raw = focusRouteSpeed
        case .indoor: raw = focusIndoor
        }
        return Glance.FocusPreference.metric(from: raw)
    }

    private func choose(_ metric: Glance.Metric) {
        switch sportClass {
        case .routePace: focusRoutePace = metric.rawValue
        case .routeSpeed: focusRouteSpeed = metric.rawValue
        case .indoor: focusIndoor = metric.rawValue
        }
        StrandHaptic.selection.play()
    }

    private var bigNumberSection: some View {
        let current = Glance.layout(for: sportClass, chosenFocus: chosenFocus).focus
        return VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) { bigNumberLabel; bigNumberMenu(current) }
                } else {
                    HStack(alignment: .center, spacing: NoopMetrics.space3) {
                        bigNumberLabel
                        Spacer(minLength: NoopMetrics.space2)
                        bigNumberMenu(current)
                    }
                }
            }
            .frame(minHeight: 44)
            if let last = Self.lastLine(rows: rows, sport: selected, title: title, system: unitSystem) {
                Text(verbatim: last)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var bigNumberLabel: some View {
        Text("Big number").strandOverlineFitted().lineLimit(2)
    }

    private func bigNumberMenu(_ current: Glance.Metric) -> some View {
        Menu {
            ForEach(Glance.FocusPreference.choices(for: sportClass), id: \.self) { metric in
                Button { choose(metric) } label: {
                    if metric == current {
                        Label(Glance.name(of: metric), systemImage: "checkmark")
                    } else {
                        Text(verbatim: Glance.name(of: metric))
                    }
                }
            }
        } label: {
            WidgetChip(verbatimTitle: Glance.name(of: current), showsChevron: true, opensMenu: true)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("Big number"))
        .accessibilityValue(Text(verbatim: Glance.name(of: current)))
    }

    static func lastLine(rows: [WorkoutRow], sport: String, title: String, system: UnitSystem) -> String? {
        guard let row = WorkoutSetupLastTime.newest(of: sport, in: rows) else { return nil }
        return WorkoutFormat.joined(WorkoutSetupLastTime.facts(for: row, title: title, system: system))
    }

    // MARK: Lift

    private var liftRow: some View {
        Button { showsLift = true } label: {
            HStack(spacing: NoopMetrics.space3) {
                WorkoutSportGlyph(symbol: "dumbbell.fill")
                Text("Lift weights instead")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: NoopMetrics.space2)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Choose a routine and track sets, reps and weight.")
    }

    // MARK: Start

    private var presentation: WorkoutStartPresentation {
        WorkoutStartPresentation.make(sportTitle: title, isRouteSport: isRouteSport, gps: probe.readiness,
                                      strapConnected: strap.connected, countdownOn: countdownOn)
    }

    private func start(countdown: Bool) {
        RecentSportsPrefs.recordSelection(selected)
        var locked: Bool?
        if isRouteSport {
            if case .locked = probe.readiness { locked = true } else { locked = false }
        }
        probe.stop()
        onStart(selected, countdown, locked)
    }

    private var startBar: some View {
        let presentation = presentation
        return VStack(spacing: NoopMetrics.space3) {
            if blockedByLift { liftBlockRow }
            Button {
                // The tap that ends a hold already started.
                if startedByHold { startedByHold = false; return }
                start(countdown: countdownOn)
            } label: {
                Label(presentation.labelText, systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GlanceActionButtonStyle(.primary))
            .disabled(blockedByLift)
            // Press and hold Start for half a second: straight in, no countdown.
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                guard !blockedByLift else { return }
                startedByHold = true
                start(countdown: false)
            })
            .accessibilityAction(named: Text("Start without countdown")) {
                if !blockedByLift { start(countdown: false) }
            }
            if let caption = presentation.captionText {
                Text(verbatim: caption)
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.vertical, NoopMetrics.space3)
        // Opaque, so what scrolls beneath it never shows through the button's surroundings.
        .background(StrandPalette.surfaceBase.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(StrandPalette.hairline).frame(height: 1).accessibilityHidden(true) }
    }

    /// Why Start would do nothing, and what to do instead. Side by side while both fit on one line; stacked when a longer
    /// translation or a larger type size would otherwise wrap a word of the pill ("Kraft-training").
    @ViewBuilder private var liftBlockRow: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) { liftBlockPill; liftBlockAction }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: NoopMetrics.space3) {
                    liftBlockPill.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    liftBlockAction.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: NoopMetrics.space2) { liftBlockPill; liftBlockAction }
            }
        }
    }

    private var liftBlockPill: some View { StatePill("Finish your lift first", tone: .warning) }

    private var liftBlockAction: some View {
        Button(action: onOpenLift) { Text("Open lift") }
            .buttonStyle(SecondaryPillButtonStyle())
    }
}

/// Publishes only whether a strap is connected, so the setup page is not redrawn for every heartbeat to know it.
@MainActor
private final class StrapConnectionWatcher: ObservableObject {
    @Published private(set) var connected: Bool
    private var token: Any?

    init(live: LiveState) {
        connected = live.connected
        token = live.$connected.removeDuplicates().sink { [weak self] value in self?.connected = value }
    }
}
#endif
