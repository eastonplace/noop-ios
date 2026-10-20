#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics

/// iOS navigation shell. On iPhone the natural structure is a `TabView` with the most-used screens as
/// first-class tabs and contextual tools reached from their owning surfaces.
struct RootTabView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var localCoach: LocalCoachEngine
    @Environment(\.scenePhase) private var scenePhase
    /// Cross-screen navigation requests (e.g. Live → "Manage devices"). Devices isn't a tab, so a request
    /// presents it as a sheet, matching the quick-action screens.
    @EnvironmentObject private var router: NavRouter

    /// Which quick-action screen the centre FAB is presenting (nil = sheet closed).
    @State private var quickAction: QuickAction?
    /// The Quick Actions fan: true from the tap on the + that opens it until the tap that closes it.
    @State private var fanOpen = false
    /// The fan is in the view tree from just before it opens until its closing animation has finished.
    @State private var fanMounted = false
    /// Presents the Devices manager (pair / switch bands) when a screen asks the shell to open it.
    @State private var showDevices = false
    /// Presents the Lift flow. Owned here, not by `LiftResumeCard`, so the shell can open it on its own after a
    /// relaunch and from the lift Live Activity's deep link.
    @State private var showLift = false
    /// A routed v5 pillar screen (Insights hub / Lab Book / fused record / Rhythm) presented as a sheet
    /// when a hub row deep-links to it via NavRouter. nil = closed.
    @State private var routedPillar: NavRouter.Destination?
    /// The Settings sheet (the top bar's profile button, or any caller of `NavRouter.openSettings`). nil = closed.
    @State private var settingsSheet: SettingsSheetRequest?
    /// True from the moment `presentAfterClosingSettings` closes the Settings sheet until the presentation it was
    /// waiting for has been made, so the auto-presenter does not slip a sheet of its own into that gap.
    @State private var settingsClosing = false
    /// The workout journey (setup, live, summary), presented once as a full-screen cover that cannot be swiped away. nil =
    /// closed. Every screen asks for it through `NavRouter.beginWorkout()` / `openActiveWorkout()`.
    @State private var journey: WorkoutJourneyEntry?
    /// A destination requested while the journey is up (Updates, Devices, Trends, Settings): it never presents underneath
    /// the cover, it waits for it to close.
    @State private var pendingDestinationAfterJourney: NavRouter.Destination?
    /// The lift flow was asked for while the journey is up (the setup page's "Open lift").
    @State private var liftAfterJourney = false
    /// Settings was asked for while the journey is up (or about to be): it waits for the cover to close, like a destination.
    @State private var settingsAfterJourney: SettingsSheetRequest?
    /// Selected tab — bound so tab switches can crossfade. Defaults to Today.
    @AppStorage(ClockFormatPreference.defaultsKey) private var clockPreference = ClockFormatPreference.system.rawValue
    @State private var selectedTab: Int
    /// The locale that carries the in-app clock format (12/24-hour) to the pickers and dates under it.
    private var clockLocale: Locale {
        clockPreference.isEmpty ? Locale.autoupdatingCurrent : AppClock.formattingLocale
    }
    /// Paper is the sole Today surface.
    private var todayTabRoot: some View {
        #if DEBUG
        TodayView().qaRouteHost(.today)
        #else
        TodayView()
        #endif
    }
    private var trendsTabRoot: some View {
        #if DEBUG
        TrendsView().qaRouteHost(.trends)
        #else
        TrendsView()
        #endif
    }
    private var coachTabRoot: some View {
        #if DEBUG
        LocalCoachView(screen: QACoachPage.requested ?? .chat)
        #else
        LocalCoachView()
        #endif
    }
    private var sleepTabRoot: some View {
        #if DEBUG
        SleepView().qaRouteHost(.sleep)
        #else
        SleepView()
        #endif
    }

    init() {
        var initialTab = 0
        #if DEBUG
        // Screenshot/QA harness: launch directly into a tab without UI automation permissions.
        let arguments = ProcessInfo.processInfo.arguments
        let argumentTab = arguments.firstIndex(of: "--demo-tab").flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        }
        if let requested = (ProcessInfo.processInfo.environment["NOOP_DEMO_TAB"] ?? argumentTab)?.lowercased() {
            // "settings" and "more" launch on Today with the Settings sheet up (see `presentQAShellRoute`).
            initialTab = switch requested {
            case "trends": 1
            case "sleep": 2
            case "coach": 4
            default: 0
            }
        } else if let route = QARoute.requested {
            // `--noop-qa-route` launches over the tab that owns the route.
            initialTab = route.launchTab.rawValue
        }
        #endif
        _selectedTab = State(initialValue: initialTab)

        // The native bar stays hidden, but keep its appearance correct for transient UIKit hosts.
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(StrandPalette.appCanvas)
        appearance.shadowColor = UIColor(StrandPalette.hairline)
        appearance.selectionIndicatorTintColor = .clear
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        UISwitch.appearance().onTintColor = UIColor(StrandPalette.ink)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
        VStack(spacing: 0) {
        TabView(selection: $selectedTab) {
            tab(todayTabRoot, "Today", "square.grid.2x2").tag(0)
            tab(trendsTabRoot, "Trends", "chart.bar").tag(1)
            tab(coachTabRoot, "Coach", "bubble.left.and.text.bubble.right").tag(4)
            tab(sleepTabRoot, "Sleep", "moon").tag(2)
        }
        .segmentedPillSelectionStyle(.quiet)
        .environment(\.locale, clockLocale)
        .toolbar(.hidden, for: .tabBar)
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24), value: selectedTab)
        // Give the bar its own layout space. A TabView can forward an outer safe-area inset
        // inconsistently to nested NavigationStacks, covering a bottom-aligned composer.
            WorkoutResumeBarHost(coverIsUp: journey != nil)
            LiftResumeCard(onResume: { showLift = true }).padding(.horizontal, 16)
            // The tab bar is drawn after the Quick Actions scrim so it stays above it; this is the layout space it takes.
            Color.clear.frame(height: PaperTabBar.height).accessibilityHidden(true)
        }
        if fanMounted {
            QuickActionFan(isOpen: fanOpen, frozenProgress: fanFrozenProgress, onClose: { closeFan() },
                onPick: { picked in
                    closeFan()
                    quickAction = picked
                }, onWorkout: { active in
                    // The journey is the shell's; the fan only asks for it and goes. "Return to workout" goes through
                    // `openActiveWorkout()` like the resume bar, so the auto-present policy counts it as a request and
                    // does not bring the workout back after it is minimized.
                    closeFan()
                    if active { router.openActiveWorkout() } else { router.workoutJourneyRequest = .setup(initialSport: nil) }
                }, onStrength: {
                    // The same Lift flow the Live Activity's deep link opens; it closes the fan itself.
                    openLift()
                }, onQuickStart: { sport in
                    closeFan()
                    router.workoutJourneyRequest = .quickStart(sport: sport)
                }, onChooseQuickActions: {
                    // Unmount first so Settings never appears behind the modal fan.
                    closeFan(animated: false)
                    router.openSettings(.quickActions)
                })
        }
        PaperTabBar(selection: $selectedTab, fanOpen: fanOpen, fanProgress: fanProgress, onReselect: { tab in
            // Only Today owns a current-day data refresh. Reselecting Trends, Coach, or Sleep
            // must not wake the store or rebuild unrelated health state.
            guard tab == 0 else { return }
            Task { _ = await repo.refresh(.currentDay) }
        }, onQuickActions: {
            if fanOpen { closeFan() } else { openFan() }
        })
        }
        .background(StrandPalette.appCanvas.ignoresSafeArea(.container, edges: .bottom))
        .background {
            SmartAlarmCommandReconciler()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .background {
            ActiveSessionAutoPresenter(
                otherPresentationActive: journey != nil || quickAction != nil || fanOpen || showDevices || routedPillar != nil || showLift
                    || settingsSheet != nil || settingsClosing,
                presentRun: autoPresentJourney,
                presentLift: { showLift = true })
        }
        #if DEBUG
        .task { await presentQAShellRoute() }
        .task { await QAScrollDriver.run() }
        // Capture scripts wait for the demo history before judging a frame stable.
        .onChange(of: repo.days.count, initial: true) { _, count in
            if count > 0 { NSLog("[qa-route] data days=%d", count) }
        }
        #endif
        .task {
            routePendingCoachRequest()
            // AppModel owns the one initial full-history repository load. This shell only performs the
            // independent backup catch-up, avoiding two equivalent launch refreshes racing each other.
            let backupRepo = repo
            Task.detached(priority: .utility) {
                await FolderBackup.catchUpIfDue(checkpoint: { await backupRepo.checkpointForBackup() })
            }
        }
        .sheet(item: $quickAction) { action in
            quickActionDestination(action)
        }
        .sheet(isPresented: $showDevices) {
            devicesScreen
        }
        .sheet(isPresented: $showLift) {
            // The Lift screen carries its own back/close control; the sheet only needs the app chrome
            // out of the way.
            LiftLogView().sheetScreenScaffoldEnvironment()
        }
        .sheet(item: $routedPillar) { destination in
            pillarScreen(destination)
        }
        .sheet(item: $settingsSheet) { request in
            SettingsSheetHost(request: request, onClose: { settingsSheet = nil })
                // A sheet is outside the TabView, so it needs the in-app clock format's locale itself: Sleep & alarm's
                // time pickers inside Settings follow the 12/24-hour preference like the Sleep tab's.
                .environment(\.locale, clockLocale)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationBackground(StrandPalette.appCanvas)
        }
        .onChange(of: router.settingsRequest) { _, request in
            guard let request else { return }
            router.settingsRequest = nil
            presentSettings(request, afterDismissal: false)
        }
        // The workout: one full-screen cover, so nothing is stacked and nothing can be swiped away.
        .fullScreenCover(item: $journey, onDismiss: journeyDidDismiss) { entry in
            WorkoutJourneyView(entry: entry, onClose: { journey = nil })
        }
        .onChange(of: router.workoutJourneyRequest) { _, request in
            guard let request else { return }
            router.workoutJourneyRequest = nil
            presentJourney(request)
        }
        .paperToast(isPresented: shellToastPresented) {
            PaperToast(LocalizedStringKey(router.shellToast ?? ""), systemImage: "trash",
                       tint: StrandPalette.textSecondary, announcement: router.shellToast)
        }
        .onChange(of: router.requestedDestination) { _, destination in
            // While the journey is up nothing else presents underneath it: the request waits for the cover to close.
            if journey != nil || ShellModalCollapse.isCollapsing, let destination, destination != .activeWorkout {
                pendingDestinationAfterJourney = destination
                router.requestedDestination = nil
                return
            }
            switch destination {
            case .devices:
                router.requestedDestination = nil
                presentAfterClosingSettings { showDevices = true }
            case .insightsHub, .labBook, .fusedRecord, .rhythm, .updates:
                router.requestedDestination = nil
                presentAfterClosingSettings { routedPillar = destination }
            case .settings:
                // The deep-link key an Updates item carries, and any caller that predates `openSettings`. The
                // Updates sheet that raised it is still dismissing, so wait it out.
                presentSettings(SettingsSheetRequest(), afterDismissal: true)
                router.requestedDestination = nil
            case .trends:
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 1 }
                router.requestedDestination = nil
            case .activeWorkout:
                // The deep-link key for the running workout: the journey opens at the live screen.
                router.openActiveWorkout()
                router.requestedDestination = nil
            case .liveSession:
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 0 }
                router.requestedDestination = nil
            case nil:
                break
            }
        }
        .onChange(of: router.activeLiftRequested) { _, requested in
            guard requested else { return }
            router.activeLiftRequested = false
            if journey != nil || ShellModalCollapse.isCollapsing {
                // The lift opens once the journey's cover has closed.
                liftAfterJourney = true
                journey = nil
            } else {
                openLift()
            }
        }
        .onChange(of: router.quickActionsRequested) { _, requested in
            if requested {
                openFan()
                router.quickActionsRequested = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: LocalCoachIntentBridge.notification)) { _ in routePendingCoachRequest() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { routePendingCoachRequest() } }
        .onChange(of: localCoach.preferences) { _, _ in routePendingCoachRequest() }
        .onChange(of: repo.todayHealthSnapshotScopeId) { _, _ in routePendingCoachRequest() }
        .onChange(of: repo.liveSourceState.lineageComponent) { _, _ in routePendingCoachRequest() }
        .onChange(of: repo.verifiedExternalSurfaceFenced) { _, _ in routePendingCoachRequest() }
    }

    #if DEBUG
    /// `--noop-qa-route` for the screens the shell itself presents (quick actions, routed pillars).
    private func presentQAShellRoute() async {
        guard let route = QARoute.requested ?? (QARoute.demoTabOpensSettings ? .settings : nil),
              case .shell(let target) = route.presentation else { return }
        if target == .workoutMinimized {
            // The seeded workout is resumed by the shell's auto-present, as it is at a real launch. This route is the screen
            // the person lands on after minimizing it: wait for the cover, close it, and let the resume bar be the frame.
            for _ in 0..<40 where journey == nil { try? await Task.sleep(for: .milliseconds(250)) }
            try? await Task.sleep(for: .milliseconds(1500))
            journey = nil
            try? await Task.sleep(for: .milliseconds(2500))
            route.logPresented()
            return
        }
        // A sheet requested mid-launch can be dropped, so retry until a modal is actually up.
        for attempt in 0..<10 {
            try? await Task.sleep(for: .milliseconds(attempt == 0 ? 1800 : 3500))
            // The workout routes are presented by the journey cover, whatever else (the lift flow the demo data resumes) is up.
            let isJourney = target == .startWorkout || target == .workoutCountdown || target == .liveWorkout
            let presented = isJourney ? journey != nil : target == .quickActions ? fanOpen : QARoute.modalIsPresented
            if presented { route.logPresented(); return }
            if !isJourney {
                quickAction = nil
                routedPillar = nil
            }
            try? await Task.sleep(for: .milliseconds(400))
            switch target {
            case .updates: routedPillar = .updates
            case .settings: settingsSheet = SettingsSheetRequest(route: QARoute.settingsPage)
            case .rhythm: routedPillar = .rhythm
            case .liveHR: quickAction = .live
            case .breathe: quickAction = .breathe
            case .journal: quickAction = .journal
            case .intervals: quickAction = .intervals
            case .quickActions: openFan()
            case .startWorkout: router.beginWorkout()
            case .workoutCountdown: router.quickStartWorkout(sport: "Running")
            case .liveWorkout: router.openActiveWorkout()
            case .workoutMinimized: break
            }
        }
    }
    #endif

    /// Opens the journey. A cover on the root fails silently while any screen below it presents something, so everything
    /// is closed first and the cover presents once nothing is up: the Settings sheet the way every shell presentation closes
    /// it (`presentAfterClosingSettings`, which keeps the auto-presenter out of the gap), then the rest (`ShellModalCollapse`).
    private func presentJourney(_ start: WorkoutJourneyStart) {
        // Already up: only the live screen is ever re-requested while it is open, and it is already where it should be.
        guard journey == nil else { return }
        presentAfterClosingSettings {
            // Checked again once Settings is gone: a second request may have presented it during the dismissal.
            guard journey == nil else { return }
            // A collapse already under way will present it: a second request (a Live Activity tap arrives as a link and as the
            // app becoming active) must not start a second wait.
            ShellModalCollapse.run(
                clearShellState: {
                    quickAction = nil
                    closeFan(animated: false)
                    showDevices = false
                    routedPillar = nil
                    showLift = false
                    // Settings is shell state like the rest: never left non-nil under the cover.
                    settingsSheet = nil
                    settingsClosing = false
                    router.collapseModals()
                },
                isSatisfied: { journey != nil },
                then: {
                    if journey == nil { journey = WorkoutJourneyEntry(start: start) }
                })
        }
    }

    /// The auto-presenter's run: the journey at the live screen, onto a bare shell or not at all. An automatic presentation
    /// never collapses or force-dismisses anything (a screen's sheet may hold unsaved input); the policy has already waited
    /// for any modal, and this covers the moment between its decision and the presentation. Only a person's request
    /// (`presentJourney`) collapses what is up.
    private func autoPresentJourney() {
        guard journey == nil else { return }
        ShellModalCollapse.presentIfNothingIsUp { journey = WorkoutJourneyEntry(start: .live) }
    }

    /// What was waiting for the cover to close: the lift flow, then a destination someone asked for meanwhile.
    private func journeyDidDismiss() {
        if liftAfterJourney {
            liftAfterJourney = false
            openLift()
        }
        if let destination = pendingDestinationAfterJourney {
            pendingDestinationAfterJourney = nil
            router.requestedDestination = destination
        }
        if let request = settingsAfterJourney {
            settingsAfterJourney = nil
            presentSettings(request, afterDismissal: true)
        }
    }

    private var shellToastPresented: Binding<Bool> {
        Binding(get: { router.shellToast != nil }, set: { if !$0 { router.shellToast = nil } })
    }

    /// The lift Live Activity's deep link. Any shell sheet already up is closed first, then the Lift flow
    /// opens and (because it lands on its start screen) resumes the active session on its own.
    private func openLift() {
        guard !showLift else { return }
        let shellSheetWasUp = quickAction != nil || showDevices || routedPillar != nil || settingsSheet != nil
        quickAction = nil
        closeFan(animated: false)
        showDevices = false
        routedPillar = nil
        settingsSheet = nil
        if shellSheetWasUp {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showLift = true }
        } else {
            showLift = true
        }
    }

    /// Opens Settings. Any other shell sheet that is up is closed first, and Settings follows once it is gone, because
    /// SwiftUI drops a sheet presented while another is still on screen (the `openLift` pattern). `afterDismissal` is for a
    /// caller whose own sheet was closed in the same breath, so it is no longer visible in the state it left behind. While
    /// the workout journey is up, or a collapse is about to present it, Settings never presents underneath the cover: it
    /// waits for the cover to close, as every destination does.
    private func presentSettings(_ request: SettingsSheetRequest, afterDismissal: Bool) {
        if journey != nil || ShellModalCollapse.isCollapsing {
            settingsAfterJourney = request
            return
        }
        let shellSheetWasUp = quickAction != nil || showDevices || routedPillar != nil || showLift || settingsSheet != nil
        quickAction = nil
        closeFan(animated: false)
        showDevices = false
        routedPillar = nil
        showLift = false
        settingsSheet = nil
        if shellSheetWasUp || afterDismissal {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { settingsSheet = request }
        } else {
            settingsSheet = request
        }
    }

    /// Runs `present` once the Settings sheet is out of the way. SwiftUI drops a sheet presented while another is still on
    /// screen (and a tab switch under Settings is invisible), so a routed pillar, the Devices sheet, the workout journey
    /// and a Coach request all go through here: with Settings up it is closed first and `present` follows after the
    /// dismissal, the `openLift` pattern; with nothing up `present` runs at once. The journey then hands whatever else is
    /// up to `ShellModalCollapse`, so Settings is always closed through its own binding, never by a UIKit force-dismiss.
    private func presentAfterClosingSettings(_ present: @escaping () -> Void) {
        guard let delay = ShellSettingsGate.delay(settingsIsUp: settingsSheet != nil) else {
            present()
            return
        }
        settingsClosing = true
        settingsSheet = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            settingsClosing = false
            present()
        }
    }

    private func routePendingCoachRequest() {
        let source = repo.todayHealthSnapshotScopeId + "|" + repo.liveSourceState.lineageComponent
        guard LocalCoachIntentBridge.updateContext(sourceID: source, preferences: localCoach.preferences,
                                                   isFenced: repo.verifiedExternalSurfaceFenced) else { return }
        if LocalCoachIntentBridge.hasPendingRequest { presentAfterClosingSettings { selectedTab = 4 } }
    }

    @ViewBuilder
    private func pillarScreen(_ destination: NavRouter.Destination) -> some View {
        // Routed pillars are modal sheets: no system navigation bar and no pinned app chrome, just the
        // screen's own header with one close button. Screens that already draw their own close keep it.
        let ownsClose = destination == .rhythm || destination == .updates
        NavigationStack {
            Group {
                switch destination {
                case .insightsHub: InsightsHubView()
                case .labBook: LabBookView()
                case .fusedRecord: FusedRecordHost()
                case .rhythm: RhythmHost(onClose: { routedPillar = nil })
                case .devices: DevicesView()
                case .trends: TrendsView()
                // The running workout is the journey's, never a routed sheet; kept so the switch stays exhaustive.
                case .activeWorkout: EmptyView()
                case .liveSession: TodayView()
                case .settings: EmptyView() // Settings is `SettingsSheetHost`, never a routed pillar.
                case .updates: UpdatesInboxView(onClose: { routedPillar = nil })
                }
            }
            .background(StrandPalette.appCanvas.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheetScreenScaffoldEnvironment(onClose: ownsClose ? nil : { routedPillar = nil })
        }
        .drillInDestinationEnvironment()
    }

    private static let sheetEase = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.42)

    // MARK: Quick Actions fan

    /// How the fan's pieces move, which the + button follows: a spring, or a short fade under Reduce Motion.
    private static let fanSpring = Animation.spring(response: 0.38, dampingFraction: 0.62)

    /// The + button's progress between + (0) and × (1). QA can hold it part way through the spring.
    private var fanProgress: CGFloat { fanOpen ? (fanFrozenProgress ?? 1) : 0 }

    private var fanFrozenProgress: CGFloat? {
        #if DEBUG
        QAFan.frozenProgress
        #else
        nil
        #endif
    }

    private func openFan() {
        guard !fanOpen else { return }
        // The one tactile cue the app already gives a state change like this.
        StrandHaptic.light.play()
        // Mounted closed first, so the next frame has something to spring from.
        fanMounted = true
        DispatchQueue.main.async {
            withAnimation(Self.fanSpring) { fanOpen = true }
        }
    }

    private func closeFan(animated: Bool = true) {
        guard fanOpen || fanMounted else { return }
        guard animated else {
            fanOpen = false
            fanMounted = false
            return
        }
        withAnimation(Self.fanSpring) { fanOpen = false }
        // Unmounted once the springs have settled, unless it was opened again meanwhile.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if !fanOpen { fanMounted = false }
        }
    }

    @ViewBuilder
    private func quickActionDestination(_ action: QuickAction) -> some View {
        switch action {
        case .live:
            quickScreen(LiveView())
        case .journal:
            quickScreen(CoachingRootView())
        case .breathe:
            quickScreen(BreathingView())
        case .intervals:
            quickScreen(IntervalTimerView())
        }
    }

    /// A quick-action modal: no system navigation bar and no pinned app chrome, just the screen's own
    /// header with one close button (unless the screen draws its own, `ownsClose`).
    private func quickScreen<V: View>(_ view: V, ownsClose: Bool = false) -> some View {
        NavigationStack {
            view
                .background(StrandPalette.appCanvas.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .sheetScreenScaffoldEnvironment(onClose: ownsClose ? nil : { quickAction = nil })
        }
        .drillInDestinationEnvironment()
    }

    private var devicesScreen: some View {
        NavigationStack {
            DevicesView(onClose: { showDevices = false })
                .background(StrandPalette.appCanvas.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .sheetScreenScaffoldEnvironment()
        }
        .drillInDestinationEnvironment()
    }

    private func tab<V: View>(_ view: V, _ title: LocalizedStringKey, _ icon: String) -> some View {
        NavigationStack {
            view
                .background(StrandPalette.appCanvas.ignoresSafeArea())
                // The tab root keeps the pinned app chrome; everything pushed onto this stack is a drill-in.
                .environment(\.screenScaffoldNavigationRole, .root)
                .toolbar(.hidden, for: .navigationBar)
        }
        .drillInDestinationEnvironment()
        .toolbar(.hidden, for: .tabBar)
        .tabItem { Label(title, systemImage: icon) }
    }
}

/// Invisible leaf that re-presents an in-flight run or lift without a tap: once on launch, and once each time
/// the app returns from the background (see `ActiveSessionAutoPresentPolicy` for the rules). It is its own view
/// so the AppModel and lift churn it observes re-renders only this empty body, never the tab shell.
private struct ActiveSessionAutoPresenter: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var lift: NoopReceiptLiftIntegration
    @EnvironmentObject private var router: NavRouter
    @Environment(\.scenePhase) private var scenePhase
    /// The shell's own sheets. Launch-time modals elsewhere in the app report through the router, and a screen's own sheet
    /// or cover is read from the window when a decision is made.
    let otherPresentationActive: Bool
    /// Presents the run without closing anything (`RootTabView.autoPresentJourney`).
    let presentRun: () -> Void
    let presentLift: () -> Void
    @State private var policy = ActiveSessionAutoPresentPolicy()

    private var isBlocked: Bool { otherPresentationActive || router.isAutoPresentBlocked }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task {
                // Let the first frame and its sheets settle; a sheet presented during the launch transition
                // can be dropped.
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, scenePhase == .active else { return }
                present(policy.sceneBecameActive(context))
            }
            .task(id: isBlocked) {
                // Whatever blocked an earlier attempt just went away. Wait for its dismissal to finish
                // before presenting; a modal that returns meanwhile cancels this task (the id changes).
                guard !isBlocked else { return }
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                present(policy.otherPresentationEnded(context))
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background: policy.sceneEnteredBackground()
                case .active: present(policy.sceneBecameActive(context))
                case .inactive: break
                @unknown default: break
                }
            }
            .onChange(of: router.workoutRequestCount) { _, _ in
                // The shell is opening a workout on request (Live Activity, Today indicator): it was not auto-presented,
                // so whatever this policy was holding back for a blocking sheet must not fire when it is closed.
                policy.workoutOpenedByRequest()
            }
            .onChange(of: lift.restoredSessionPending) { _, pending in
                guard pending else { return }
                lift.consumeRestoredSession()
                // Restored while backgrounded (a background relaunch): the next foreground edge sees it.
                guard scenePhase == .active else { return }
                present(policy.liftSessionRestored(context))
            }
    }

    private var context: ActiveSessionAutoPresentPolicy.Context {
        ActiveSessionAutoPresentPolicy.Context(
            hasActiveRun: model.activeWorkout != nil,
            hasActiveLift: lift.coordinator?.hasActiveSession == true,
            workoutSurfaceVisible: router.workoutSurfaces.isVisible,
            shellPresentationActive: isBlocked,
            // A screen's own sheet (a manual workout, a journal edit) blocks too: automatic presentation never dismisses it.
            anyModalPresented: ModalPresentationProbe.isAnyModalPresented)
    }

    private func present(_ target: ActiveSessionAutoPresentPolicy.Target?) {
        #if DEBUG
        // QA only: a restored run or lift does not cover the screen being captured.
        if ProcessInfo.processInfo.arguments.contains("--noop-qa-no-auto-present") { return }
        #endif
        switch target {
        case .run: presentRun()
        case .lift: presentLift()
        case nil: break
        }
    }
}

/// The screens the Quick Actions fan opens as sheets.
enum QuickAction: Int, Identifiable {
    case live, journal, breathe, intervals
    var id: Int { rawValue }
}

/// A tab's name: one line, never broken inside a word. The slot is about 60 pt wide, so a long word ("Einstellungen")
/// is wider than it even at the default text size, and SwiftUI would hyphenate it ("Einstellun-gen") when the type is
/// a Dynamic Type text style. A fixed size that scales with Dynamic Type (up to a ceiling) shrinks instead.
struct PaperTabLabel: View {
    let title: LocalizedStringKey
    let isActive: Bool

    /// The largest the label grows to at an accessibility size, where the large content viewer shows it at full size.
    /// Every smaller size is the plain `.caption2` text as it always was (the viewer does not exist there).
    static let ceiling: CGFloat = 15

    var body: some View {
        Text(title)
            .microLabelFit(lines: 1, weight: isActive ? .semibold : .regular, ceiling: Self.ceiling)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PaperTabBar: View {
    /// The bar's own height: the hairline over its row. The shell leaves this much room under the tab content.
    static let height = NoopMetrics.navBarHeight + 1

    @Binding var selection: Int
    /// The Quick Actions fan is open: the bar is see-through, the tabs recede to 30% and the + has turned into a ×.
    var fanOpen = false
    /// 0 + ... 1 ×, so a QA capture can hold the turn half way.
    var fanProgress: CGFloat = 0
    var onReselect: (Int) -> Void = { _ in }
    var onQuickActions: () -> Void = {}
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Item: Identifiable {
        let title: LocalizedStringKey
        let icon: String
        let tag: Int
        var id: Int { tag }
    }

    private let nav = [
        Item(title: "Today", icon: "square.grid.2x2", tag: 0),
        Item(title: "Trends", icon: "chart.bar", tag: 1),
        Item(title: "Coach", icon: "bubble.left.and.text.bubble.right", tag: 4),
        Item(title: "Sleep", icon: "moon", tag: 2),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(StrandPalette.hairline).frame(height: 1).opacity(1 - Double(fanProgress))
            // Every size short of the accessibility sizes keeps five equal slots (four tabs and the quick-actions
            // button, which sits in the middle). At the accessibility sizes the labels are larger, and a long one
            // would be squeezed to half size in an equal slot, so the slots are shared out by what their labels need
            // instead.
            Group {
                if typeSize.isAccessibilitySize {
                    TabSlotLayout { slots }
                } else {
                    HStack(spacing: 0) { slots }
                }
            }
            // A label is one line that scales down to fit its slot (`PaperTabLabel`), so the bar's height does not
            // depend on the user's text size; the large content viewer carries the full-size label.
            .frame(height: NoopMetrics.navBarHeight)
        }
        .background(StrandPalette.card.opacity(1 - Double(fanProgress)))
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .easeOut(duration: 0.25), value: fanOpen)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app.bottomNavigation")
    }

    @ViewBuilder private var slots: some View {
        ForEach(nav.prefix(2)) { tabButton($0) }
        quickActionsButton
        ForEach(nav.dropFirst(2)) { tabButton($0) }
    }

    /// The mint + of the mockup: 54pt with a soft glow. Opening the fan turns its glyph 135 degrees into a × while the fill
    /// settles to a neutral raised surface; with Reduce Motion the glyph swaps with a fade instead of turning.
    private var quickActionsButton: some View {
        let p = Double(fanProgress)
        return Button(action: onQuickActions) {
            ZStack {
                Circle()
                    .fill(StrandPalette.ink.blended(into: StrandPalette.inset, by: p))
                    .shadow(color: StrandPalette.ink.opacity(0.25 * (1 - p)), radius: 11, y: 6)
                ZStack {
                    Image(systemName: "plus")
                        .rotationEffect(.degrees(reduceMotion ? 0 : 135 * p))
                        .opacity(reduceMotion ? 1 - p : 1)
                    if reduceMotion {
                        Image(systemName: "xmark").opacity(p)
                    }
                }
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(StrandPalette.onInk.blended(into: StrandPalette.textPrimary, by: p))
            }
            .frame(width: 54, height: 54)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 0.62),
                       value: fanOpen)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(fanOpen ? "Close Quick Actions" : "Quick Actions")
        .accessibilityIdentifier("app.quickActions")
    }

    private func tabButton(_ item: Item) -> some View {
        let active = selection == item.tag
        return Button {
            if fanOpen {
                // The tabs are dimmed behind the scrim: a tap on one is a tap outside the fan.
                onQuickActions()
            } else if active {
                onReselect(item.tag)
            } else {
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) {
                    selection = item.tag
                }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: item.icon)
                    .font(.system(size: 18, weight: active ? .semibold : .regular))
                PaperTabLabel(title: item.title, isActive: active)
            }
            // The selected tab is the light ink; mint stays on the + and on "recording now" (the one pill system).
            .foregroundStyle(active ? StrandPalette.solidFill : StrandPalette.textTertiary)
            .opacity(1 - 0.7 * Double(fanProgress))
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(fanOpen)
        .accessibilityLabel(item.title)
        .accessibilityShowsLargeContentViewer { Label(item.title, systemImage: item.icon) }
        .accessibilityIdentifier("app.tab.\(item.tag)")
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}

/// The tab bar's row at the accessibility sizes: each slot is as wide as its label wants, in proportion, so the whole
/// row is filled and no slot is squeezed while another has room to spare.
private struct TabSlotLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified).width }
        let height = proposal.height ?? subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: proposal.width ?? ideals.reduce(0, +), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified).width }
        let widths = TabSlotWidths.centredMiddle(TabSlotWidths.widths(ideals: ideals, total: bounds.width))
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width
        }
    }
}

/// How the accessibility-size tab bar divides its width. Pure, so the rule is tested without a view.
enum TabSlotWidths {
    /// The least a slot is given while the row has the room: the size of a touch target.
    static let minimumSlot: CGFloat = 44
    /// Air kept between one label and the next.
    static let gutter: CGFloat = 8

    /// The widths with the middle slot (the quick-actions button) on the centre line of the row: the slots to its left
    /// and right are each scaled to fill the same share, so the button sits in the middle however long the labels on
    /// either side are. Left alone when the count is even, or when scaling would take a slot under the touch target.
    static func centredMiddle(_ widths: [CGFloat]) -> [CGFloat] {
        guard widths.count >= 3, widths.count % 2 == 1 else { return widths }
        let middle = widths.count / 2
        let left = widths[..<middle].reduce(0, +)
        let right = widths[(middle + 1)...].reduce(0, +)
        let side = (widths.reduce(0, +) - widths[middle]) / 2
        guard left > 0, right > 0 else { return widths }
        let leftScale = side / left
        let rightScale = side / right
        let centred = widths.enumerated().map { index, width in
            index == middle ? width : width * (index < middle ? leftScale : rightScale)
        }
        return centred.allSatisfy({ $0 >= minimumSlot - 0.001 }) ? centred : widths
    }

    /// A width per slot, in proportion to what each one needs (its ideal width plus the gutter, never under the touch
    /// target), scaled so they fill `total` exactly.
    ///
    /// When what they need is more than `total`, the long labels give way and the short ones do not: a slot that needs
    /// only the touch target keeps it for as long as the row can afford 44pt for every slot, and the rest share what is
    /// left in proportion to what they need (so the labels shrink to fit). Scaling every slot by one fraction instead took
    /// the short ones (Hoy, +) under the touch target even though six of them fit with room to spare. Only a row too narrow
    /// for six touch targets gives every slot an equal share.
    static func widths(ideals: [CGFloat], total: CGFloat) -> [CGFloat] {
        guard !ideals.isEmpty else { return [] }
        let count = CGFloat(ideals.count)
        let needs = ideals.map { max($0 + gutter, minimumSlot) }
        let sum = needs.reduce(0, +)
        guard total > 0, sum > 0 else { return Array(repeating: max(total, 0) / count, count: ideals.count) }
        if sum <= total { return needs.map { $0 * total / sum } }
        guard total >= minimumSlot * count else { return Array(repeating: total / count, count: ideals.count) }

        // Overfull: lock a slot at the touch target as soon as its scaled share would fall under it, and share what is
        // left between the rest. A lock takes a little from the others, which can put one more under the target, so this
        // repeats; the last slot standing always has at least 44pt (the row affords six of them), so it settles.
        var locked = Array(repeating: false, count: needs.count)
        while true {
            let lockedCount = CGFloat(locked.filter { $0 }.count)
            let free = total - minimumSlot * lockedCount
            let freeNeed = zip(needs, locked).filter { !$0.1 }.reduce(0) { $0 + $1.0 }
            guard freeNeed > 0 else { return needs.map { _ in minimumSlot } }
            let factor = free / freeNeed
            var changed = false
            for index in needs.indices where !locked[index] && needs[index] * factor < minimumSlot {
                locked[index] = true
                changed = true
            }
            if !changed {
                return zip(needs, locked).map { $1 ? minimumSlot : $0 * factor }
            }
        }
    }
}

private extension Color {
    /// This colour moved `amount` (0...1) of the way to `other`, in sRGB. For a fill that follows an animation's progress.
    func blended(into other: Color, by amount: Double) -> Color {
        let amount = min(max(amount, 0), 1)
        var from: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var to: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        UIColor(self).getRed(&from.0, green: &from.1, blue: &from.2, alpha: &from.3)
        UIColor(other).getRed(&to.0, green: &to.1, blue: &to.2, alpha: &to.3)
        let t = CGFloat(amount)
        return Color(UIColor(red: from.0 + (to.0 - from.0) * t, green: from.1 + (to.1 - from.1) * t,
                             blue: from.2 + (to.2 - from.2) * t, alpha: from.3 + (to.3 - from.3) * t))
    }
}

#if DEBUG
/// `--noop-qa-fan-progress <0...1>` holds the Quick Actions fan part way through its spring, so a capture can show the
/// frame between closed and open. Pair it with `--noop-qa-route quick-actions`.
enum QAFan {
    static let frozenProgress: CGFloat? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--noop-qa-fan-progress"), arguments.indices.contains(index + 1),
              let value = Double(arguments[index + 1]) else { return nil }
        return CGFloat(min(max(value, 0), 1))
    }()
}
#endif
#endif

/// When a request that needs the whole screen (a routed pillar, the Devices sheet, the live workout, Coach) may be made
/// while the Settings sheet is up: it waits for Settings to close, then for the dismissal to finish.
enum ShellSettingsGate {
    /// Long enough for the sheet's dismissal to complete (`presentSettings` and `openLift` wait the same).
    static let dismissalDelay: TimeInterval = 0.45

    /// nil: Settings is not up, so present now. Otherwise how long to wait after closing it.
    static func delay(settingsIsUp: Bool) -> TimeInterval? {
        settingsIsUp ? dismissalDelay : nil
    }
}
