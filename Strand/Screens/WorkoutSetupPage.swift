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
//  • Ready: the strap, the GPS for a route sport, the day's strain target, the big number the live screen leads with (a menu
//    row: it stays up where it is seen, not below the pinned Start), the screen, the countdown; then the last time in this sport;
//  • a lifting session is its own flow, one row away;
//  • one pinned solid-mint 88 pt Start circle. Tap it to start (with the countdown, when that is on); press and hold it to
//    start straight away, the ring filling as it is held. Pure black, quiet rows, no rules between them.

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
    @State private var realtimeHRLease: RealtimeHRLeaseToken?
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
                recentSection.padding(.top, Self.sectionGap)
                WorkoutReadinessStrip(
                    showsGps: isRouteSport, probe: probe, live: model.live, today: today, bigNumber: bigNumberChoice,
                    keepScreenOn: $keepScreenOn, countdownOn: $countdownOn, lowPowerMode: lowPowerMode,
                    imperial: unitSystem == .imperial, onConnect: { showsDevices = true })
                    .padding(.top, Self.sectionGap)
                lastTimeLine
                // At the accessibility sizes the pinned bar is the circle alone; what Start will not record reads here.
                if typeSize.isAccessibilitySize, let caption = presentation.captionText {
                    startCaption(caption).padding(.top, NoopMetrics.space3)
                }
                liftRow.padding(.top, Self.sectionGap)
            }
            .padding(.horizontal, NoopMetrics.space4)
            .padding(.bottom, NoopMetrics.space4)
        }
        .background(LivePalette.canvas.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) { setupHeader }
        .safeAreaInset(edge: .bottom, spacing: 0) { startBar }
        .sheet(isPresented: $showsActivities) {
            WorkoutActivityPickerSheet(selected: selected, onSelect: { selected = $0 })
        }
        .sheet(isPresented: $showsDevices) { WorkoutDevicesSheet(onClose: { showsDevices = false }) }
        .onAppear {
            updateProbe()
            if realtimeHRLease == nil { realtimeHRLease = model.acquireRealtimeHR(for: .visible) }
        }
        .onDisappear {
            probe.stop()
            if let lease = realtimeHRLease { model.releaseRealtimeHR(lease) }
            realtimeHRLease = nil
        }
        // Only a sport that records a route needs the GPS: a treadmill run or a lift never wakes location.
        .onChange(of: isRouteSport) { _, _ in updateProbe() }
        .onChange(of: scenePhase) { _, _ in updateProbe() }
        // Posted on whatever thread noticed the change.
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)) { _ in lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled }
    }

    /// The gap between sections: air, not a rule.
    private static let sectionGap: CGFloat = 30

    /// Listens to the GPS only while the page is up, in the foreground, for a sport with a route.
    private func updateProbe() {
        if isRouteSport && scenePhase == .active { probe.start() } else { probe.stop() }
    }

    /// Close on the left in a dark circle, the title in the middle: the live screen's header, one step earlier.
    private var setupHeader: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space2) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(LivePalette.fill))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            Text("Start a workout")
                .foregroundStyle(StrandPalette.textPrimary)
                .liveText(17, weight: .semibold, maxSize: 24, lines: 2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.top, NoopMetrics.space2)
        .padding(.bottom, NoopMetrics.space1)
        .background(LivePalette.canvas)
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
                // Start is the page's one solid-mint control: the chosen run type is a 15% tint, like the chosen Recent chip.
                .segmentedPillSelectionStyle(.quiet)
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
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            sectionTitle("Recent")
            if !sports.isEmpty {
                WorkoutRecentSportChips(sports: sports, selected: selected) { selected = $0 }
            }
            WidgetChipButton(title: "All activities", systemImage: "square.grid.2x2", showsChevron: true,
                             accessibilityLabel: "All activities") { showsActivities = true }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A quiet heading: grey words, not tracked capitals.
    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .foregroundStyle(LivePalette.secondaryText)
            .liveText(15, weight: .semibold, maxSize: 22, lines: 2)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Big number (a row of the Ready list), last time

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

    private var bigNumberChoice: WorkoutBigNumberChoice {
        WorkoutBigNumberChoice(current: Glance.layout(for: sportClass, chosenFocus: chosenFocus).focus,
                               choices: Glance.FocusPreference.choices(for: sportClass), onChoose: { choose($0) })
    }

    /// The last time in this sport, one quiet line under the rows: its facts stack when they do not fit one line.
    @ViewBuilder private var lastTimeLine: some View {
        if let facts = Self.lastFacts(rows: rows, sport: selected, title: title, system: unitSystem) {
            SeparatedFactsLine(facts: facts)
                .foregroundStyle(LivePalette.secondaryText)
                .liveText(14, weight: .regular, maxSize: 20, lines: 3)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: Self.spokenLastLine(rows: rows, sport: selected, title: title, system: unitSystem)
                                         ?? facts.joined(separator: ", ")))
                .padding(.top, NoopMetrics.space3)
        }
    }

    static func spokenLastLine(rows: [WorkoutRow], sport: String, title: String, system: UnitSystem) -> String? {
        guard let row = WorkoutSetupLastTime.newest(of: sport, in: rows) else { return nil }
        return WorkoutSetupLastTime.spokenFacts(for: row, title: title, system: system).joined(separator: ", ")
    }

    /// The last time in this sport, as the separate facts of its line ("Last Run", "5.8 km", "5:49 /km", "Yesterday").
    static func lastFacts(rows: [WorkoutRow], sport: String, title: String, system: UnitSystem) -> [String]? {
        guard let row = WorkoutSetupLastTime.newest(of: sport, in: rows) else { return nil }
        return WorkoutSetupLastTime.facts(for: row, title: title, system: system)
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
            // The one solid-mint control: tap to start (with the countdown, when it is on), hold for half a second to start
            // straight away, the ring filling as it is held.
            LiveStartCircle(title: String(localized: "Start"), isEnabled: !blockedByLift,
                            previewProgress: previewHoldProgress,
                            onTap: { start(countdown: countdownOn) },
                            onHold: { start(countdown: false) })
                .accessibilityLabel(Text(verbatim: presentation.labelText))
                .accessibilityAction(named: Text("Start without countdown")) {
                    if !blockedByLift { start(countdown: false) }
                }
            if !typeSize.isAccessibilitySize, let caption = presentation.captionText {
                startCaption(caption)
            }
        }
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.vertical, NoopMetrics.space3)
        // Opaque and edge to edge, so what scrolls beneath it never shows through or is cut off beside the circle.
        .frame(maxWidth: .infinity)
        .background(LivePalette.canvas.ignoresSafeArea(edges: .bottom))
    }

    /// QA only: draws the Start ring filled to this share (`--demo-hold-progress 0.55`).
    private var previewHoldProgress: Double? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--demo-hold-progress"), arguments.indices.contains(flag + 1) else { return nil }
        return Double(arguments[flag + 1])
        #else
        return nil
        #endif
    }

    private func startCaption(_ caption: String) -> some View {
        Text(verbatim: caption)
            .foregroundStyle(LivePalette.secondaryText)
            .liveText(13, weight: .regular, maxSize: 19, lines: 4)
            .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .center)
            .frame(maxWidth: .infinity, alignment: typeSize.isAccessibilitySize ? .leading : .center)
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

    private var liftBlockPill: some View {
        Text("Finish your lift first")
            .foregroundStyle(StrandPalette.textPrimary)
            .liveText(14, weight: .semibold, maxSize: 20, lines: 2)
            .statePillChrome(tint: LivePalette.amber)
    }

    private var liftBlockAction: some View {
        LiveCapsuleButton(String(localized: "Open lift"), action: onOpenLift)
            .fixedSize(horizontal: true, vertical: false)
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
