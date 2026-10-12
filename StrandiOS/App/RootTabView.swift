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
    /// Presents the Devices manager (pair / switch bands) when a screen asks the shell to open it.
    @State private var showDevices = false
    /// Presents the Lift flow. Owned here, not by `LiftResumeCard`, so the shell can open it on its own after a
    /// relaunch and from the lift Live Activity's deep link.
    @State private var showLift = false
    /// A routed v5 pillar screen (Insights hub / Lab Book / fused record / Rhythm) presented as a sheet
    /// when a hub row deep-links to it via NavRouter. nil = closed.
    @State private var routedPillar: NavRouter.Destination?
    /// The workout journey (setup, live, summary), presented once as a full-screen cover that cannot be swiped away. nil =
    /// closed. Every screen asks for it through `NavRouter.beginWorkout()` / `openActiveWorkout()`.
    @State private var journey: WorkoutJourneyEntry?
    /// What Quick Actions asked for; presented once its sheet has fully gone, never while it is still dismissing.
    @State private var pendingJourneyAfterQuickActions: WorkoutJourneyStart?
    /// A destination requested while the journey is up (Updates, Devices, Trends, Settings): it never presents underneath
    /// the cover, it waits for it to close.
    @State private var pendingDestinationAfterJourney: NavRouter.Destination?
    /// The lift flow was asked for while the journey is up (the setup page's "Open lift").
    @State private var liftAfterJourney = false
    /// Selected tab — bound so tab switches can crossfade. Defaults to Today.
    @AppStorage(ClockFormatPreference.defaultsKey) private var clockPreference = ClockFormatPreference.system.rawValue
    @State private var selectedTab: Int
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
        LocalCoachView(screen: QACoachPage.requested ?? .home)
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
            initialTab = switch requested {
            case "trends": 1
            case "sleep": 2
            case "coach": 4
            case "more", "settings": 3
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
        VStack(spacing: 0) {
        TabView(selection: $selectedTab) {
            tab(todayTabRoot, "Today", "square.grid.2x2").tag(0)
            tab(trendsTabRoot, "Trends", "chart.bar").tag(1)
            tab(coachTabRoot, "Coach", "bubble.left.and.text.bubble.right").tag(4)
            tab(sleepTabRoot, "Sleep", "moon").tag(2)
            settingsTab.tag(3)
        }
        .environment(\.locale, clockPreference.isEmpty ? Locale.autoupdatingCurrent : AppClock.formattingLocale)
        .toolbar(.hidden, for: .tabBar)
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24), value: selectedTab)
        // Give the bar its own layout space. A TabView can forward an outer safe-area inset
        // inconsistently to nested NavigationStacks, covering a bottom-aligned composer.
            VStack(spacing: 0) {
            WorkoutResumeBarHost(coverIsUp: journey != nil)
            LiftResumeCard(onResume: { showLift = true }).padding(.horizontal, 16)
            PaperTabBar(selection: $selectedTab, onReselect: { tab in
                // Only Today owns a current-day data refresh. Reselecting Settings, Trends, or Sleep
                // must not wake the store or rebuild unrelated health state.
                guard tab == 0 else { return }
                Task { _ = await repo.refresh(.currentDay) }
            }, onQuickActions: {
                withAnimation(Self.sheetEase) { quickAction = .menu }
            })
            }
        }
        .background(StrandPalette.appCanvas.ignoresSafeArea(.container, edges: .bottom))
        .background {
            SmartAlarmCommandReconciler()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .background {
            ActiveSessionAutoPresenter(
                otherPresentationActive: journey != nil || quickAction != nil || showDevices || routedPillar != nil || showLift,
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
        .sheet(item: $quickAction, onDismiss: {
            // The journey presents only after the sheet is fully gone, so the two never compete for the root.
            if let pending = pendingJourneyAfterQuickActions {
                pendingJourneyAfterQuickActions = nil
                router.workoutJourneyRequest = pending
            }
        }) { action in
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
                showDevices = true
                router.requestedDestination = nil
            case .insightsHub, .labBook, .fusedRecord, .rhythm, .updates:
                routedPillar = destination
                router.requestedDestination = nil
            case .settings:
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 3 }
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
                withAnimation(Self.sheetEase) { quickAction = .menu }
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
        guard let route = QARoute.requested, case .shell(let target) = route.presentation else { return }
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
            let presented = target == .startWorkout || target == .liveWorkout ? journey != nil : QARoute.modalIsPresented
            if presented { route.logPresented(); return }
            if target != .startWorkout, target != .liveWorkout {
                quickAction = nil
                routedPillar = nil
            }
            try? await Task.sleep(for: .milliseconds(400))
            switch target {
            case .updates: routedPillar = .updates
            case .rhythm: routedPillar = .rhythm
            case .liveHR: quickAction = .live
            case .breathe: quickAction = .breathe
            case .journal: quickAction = .journal
            case .intervals: quickAction = .intervals
            case .startWorkout: router.beginWorkout()
            case .liveWorkout: router.openActiveWorkout()
            case .workoutMinimized: break
            }
        }
    }
    #endif

    /// Opens the journey. A cover on the root fails silently while any screen below it presents something, so everything
    /// is closed first (`ShellModalCollapse`) and the cover presents once nothing is up.
    private func presentJourney(_ start: WorkoutJourneyStart) {
        // Already up: only the live screen is ever re-requested while it is open, and it is already where it should be.
        guard journey == nil else { return }
        // A collapse already under way will present it: a second request (a Live Activity tap arrives as a link and as the app
        // becoming active) must not start a second wait.
        ShellModalCollapse.run(
            clearShellState: {
                quickAction = nil
                showDevices = false
                routedPillar = nil
                showLift = false
                router.collapseModals()
            },
            isSatisfied: { journey != nil },
            then: {
                if journey == nil { journey = WorkoutJourneyEntry(start: start) }
            })
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
    }

    private var shellToastPresented: Binding<Bool> {
        Binding(get: { router.shellToast != nil }, set: { if !$0 { router.shellToast = nil } })
    }

    /// The lift Live Activity's deep link. Any shell sheet already up is closed first, then the Lift flow
    /// opens and (because it lands on its start screen) resumes the active session on its own.
    private func openLift() {
        guard !showLift else { return }
        let shellSheetWasUp = quickAction != nil || showDevices || routedPillar != nil
        quickAction = nil
        showDevices = false
        routedPillar = nil
        if shellSheetWasUp {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showLift = true }
        } else {
            showLift = true
        }
    }

    private func routePendingCoachRequest() {
        let source = repo.todayHealthSnapshotScopeId + "|" + repo.liveSourceState.lineageComponent
        guard LocalCoachIntentBridge.updateContext(sourceID: source, preferences: localCoach.preferences,
                                                   isFenced: repo.verifiedExternalSurfaceFenced) else { return }
        if LocalCoachIntentBridge.hasPendingRequest { selectedTab = 4 }
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
                case .settings: SettingsView()
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

    @ViewBuilder
    private func quickActionDestination(_ action: QuickAction) -> some View {
        switch action {
        case .menu:
            QuickActionSheet(onPick: { picked in
                quickAction = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(Self.sheetEase) { quickAction = picked }
                }
            }, onWorkout: { active in
                // The journey opens after this sheet is gone (`.sheet(item:onDismiss:)` above).
                pendingJourneyAfterQuickActions = active ? .live : .setup(initialSport: nil)
                quickAction = nil
            })
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
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

    /// Settings is the one tab that intentionally keeps the native navigation bar. Its large title,
    /// always-visible search field, grouped lists, and inline detail titles should behave like iOS
    /// Settings instead of inheriting the dashboard tabs' hidden-bar chrome.
    private var settingsTab: some View {
        NavigationStack {
            SettingsView()
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
        }
        // Keep the Settings presentation on the navigation container itself. SwiftUI may host
        // nested NavigationLink destinations outside the view that created the link, so applying
        // these values only to the first destination lets third- and fourth-level screens fall
        // back to NOOP's dashboard scaffold. Container ownership makes every depth use the same
        // native grouped-list vocabulary.
        .environment(\.screenScaffoldPresentation, .settingsDetail)
        .environment(\.appHeaderChromeVisibility, .hidden)
        .toolbar(.hidden, for: .tabBar)
        .tabItem { Label("Settings", systemImage: "gearshape") }
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
    /// The shell's own sheets. Launch-time modals elsewhere in the app report through the router.
    let otherPresentationActive: Bool
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
            otherPresentationActive: isBlocked)
    }

    private func present(_ target: ActiveSessionAutoPresentPolicy.Target?) {
        switch target {
        case .run: router.openActiveWorkout()
        case .lift: presentLift()
        case nil: break
        }
    }
}

private enum QuickAction: Int, Identifiable {
    case menu, live, journal, breathe, intervals
    var id: Int { rawValue }
}

private struct QuickActionSheet: View {
    let onPick: (QuickAction) -> Void
    /// The workout row: `active` is whether a workout is already recording (the row then returns to it).
    let onWorkout: (_ active: Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Quick Actions")
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .frame(width: 32, height: 32)
                        .background(StrandPalette.inset, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Quick Actions")
                .accessibilityIdentifier("quickActions.close")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider().overlay(StrandPalette.hairline)

            ScrollView {
                LazyVStack(spacing: 0) {
                    row("Live HR", subtitle: "Start live heart rate", icon: "heart.fill",
                        tint: StrandPalette.liveRed) { onPick(.live) }
                    if let active = model.activeWorkout {
                        row("Return to workout", subtitle: "\(WorkoutSource.displaySport(active.sport)) · in progress",
                            icon: "figure.run", tint: StrandPalette.ink) { onWorkout(true) }
                    } else {
                        row("Start workout", subtitle: "Track a workout", icon: "figure.run",
                            tint: StrandPalette.ink) { onWorkout(false) }
                    }
                    row("Log journal", subtitle: "How are you feeling?", icon: "square.and.pencil",
                        tint: StrandPalette.journalAccent) { onPick(.journal) }
                    row("Breathe", subtitle: "Guided breathing", icon: "wind",
                        tint: StrandPalette.chargeAccent) { onPick(.breathe) }
                    row("Intervals", subtitle: "Run an interval timer", icon: "timer",
                        tint: StrandPalette.strainAccent) { onPick(.intervals) }
                }
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(StrandPalette.card.ignoresSafeArea())
    }

    private func row(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        icon: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.10), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(StrandFont.body.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(subtitle)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 68)
            .overlay(alignment: .bottom) {
                Rectangle().fill(StrandPalette.hairline).frame(height: 1).padding(.leading, 52)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
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
    @Binding var selection: Int
    var onReselect: (Int) -> Void = { _ in }
    var onQuickActions: () -> Void = {}
    @Environment(\.dynamicTypeSize) private var typeSize

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
        Item(title: "Settings", icon: "gearshape", tag: 3),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(StrandPalette.hairline).frame(height: 1)
            // Every size short of the accessibility sizes keeps six equal slots, exactly as before. At the accessibility
            // sizes the labels are larger, and a long one ("Einstellungen") would be squeezed to half size in an equal
            // slot, so the slots are shared out by what their labels need instead.
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
        .background(StrandPalette.card)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app.bottomNavigation")
    }

    @ViewBuilder private var slots: some View {
        ForEach(nav.prefix(2)) { tabButton($0) }
        quickActionsButton
        ForEach(nav.dropFirst(2)) { tabButton($0) }
    }

    private var quickActionsButton: some View {
        Button(action: onQuickActions) {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(StrandPalette.onInk)
                .frame(width: 44, height: 44)
                .background(StrandPalette.ink, in: Circle())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Quick Actions")
        .accessibilityIdentifier("app.quickActions")
    }

    private func tabButton(_ item: Item) -> some View {
        let active = selection == item.tag
        return Button {
            if active {
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
            .foregroundStyle(active ? StrandPalette.ink : StrandPalette.textTertiary)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        let widths = TabSlotWidths.widths(ideals: ideals, total: bounds.width)
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
#endif
