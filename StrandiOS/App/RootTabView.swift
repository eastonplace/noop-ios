#if os(iOS)
import SwiftUI
import StrandDesign

/// iOS navigation shell. On iPhone the natural structure is a `TabView` with the most-used screens as
/// first-class tabs and contextual tools reached from their owning surfaces.
struct RootTabView: View {
    @EnvironmentObject private var repo: Repository
    /// Cross-screen navigation requests (e.g. Live → "Manage devices"). Devices isn't a tab, so a request
    /// presents it as a sheet, matching the quick-action screens.
    @EnvironmentObject private var router: NavRouter

    /// Which quick-action screen the centre FAB is presenting (nil = sheet closed).
    @State private var quickAction: QuickAction?
    /// Presents the Devices manager (pair / switch bands) when a screen asks the shell to open it.
    @State private var showDevices = false
    /// A routed v5 pillar screen (Insights hub / Lab Book / fused record / Rhythm) presented as a sheet
    /// when a hub row deep-links to it via NavRouter. nil = closed.
    @State private var routedPillar: NavRouter.Destination?
    /// Selected tab — bound so tab switches can crossfade. Defaults to Today.
    @State private var selectedTab: Int
    /// Paper is the sole Today surface.
    private var todayTabRoot: some View { TodayView() }

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
            case "more", "settings": 3
            default: 0
            }
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
        TabView(selection: $selectedTab) {
            tab(todayTabRoot, "Today", "square.grid.2x2").tag(0)
            tab(TrendsView(), "Trends", "chart.bar").tag(1)
            tab(SleepView(), "Sleep", "moon").tag(2)
            settingsTab.tag(3)
        }
        .toolbar(.hidden, for: .tabBar)
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24), value: selectedTab)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PaperTabBar(selection: $selectedTab, onReselect: { tab in
                // Only Today owns a current-day data refresh. Reselecting Settings, Trends, or Sleep
                // must not wake the store or rebuild unrelated health state.
                guard tab == 0 else { return }
                Task { _ = await repo.refresh(.currentDay) }
            }, onQuickActions: {
                withAnimation(Self.sheetEase) { quickAction = .menu }
            })
        }
        .background {
            SmartAlarmCommandReconciler()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .task {
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
        .sheet(item: $routedPillar) { destination in
            pillarScreen(destination)
        }
        .onChange(of: router.requestedDestination) { _, destination in
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
                // iPhone owns a direct active-workout sheet. Clear the legacy LiveView one-shot so a
                // later diagnostics visit cannot reopen the workout a second time.
                router.presentActiveWorkout = false
                withAnimation(Self.sheetEase) { quickAction = .activeWorkout }
                router.requestedDestination = nil
            case .liveSession:
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 0 }
                router.requestedDestination = nil
            case nil:
                break
            }
        }
        .onChange(of: router.quickActionsRequested) { _, requested in
            if requested {
                withAnimation(Self.sheetEase) { quickAction = .menu }
                router.quickActionsRequested = false
            }
        }
    }

    @ViewBuilder
    private func pillarScreen(_ destination: NavRouter.Destination) -> some View {
        NavigationStack {
            Group {
                switch destination {
                case .insightsHub: InsightsHubView()
                case .labBook: LabBookView()
                case .fusedRecord: FusedRecordHost()
                case .rhythm: RhythmHost(onClose: { routedPillar = nil })
                case .devices: DevicesView()
                case .trends: TrendsView()
                case .activeWorkout: LiveWorkoutView(onClose: { routedPillar = nil })
                case .liveSession: TodayView()
                case .settings: SettingsView()
                case .updates: UpdatesInboxView(onClose: { routedPillar = nil })
                }
            }
            .background(StrandPalette.appCanvas.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { routedPillar = nil }
                        .foregroundStyle(StrandPalette.accent)
                }
            }
        }
    }

    private static let sheetEase = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.42)

    @ViewBuilder
    private func quickActionDestination(_ action: QuickAction) -> some View {
        switch action {
        case .menu:
            QuickActionSheet { picked in
                quickAction = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(Self.sheetEase) { quickAction = picked }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        case .live:
            quickScreen(LiveView())
        case .activeWorkout:
            quickScreen(LiveWorkoutView(onClose: { quickAction = nil }))
        case .workout:
            QuickWorkoutFlow(onClose: { quickAction = nil })
        case .journal:
            quickScreen(CoachingRootView())
        case .breathe:
            quickScreen(BreathingView())
        case .intervals:
            quickScreen(IntervalTimerView())
        }
    }

    private func quickScreen<V: View>(_ view: V) -> some View {
        NavigationStack {
            view
                .background(StrandPalette.appCanvas.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { quickAction = nil }
                            .foregroundStyle(StrandPalette.accent)
                    }
                }
        }
    }

    private var devicesScreen: some View {
        NavigationStack {
            DevicesView(onClose: { showDevices = false })
                .background(StrandPalette.appCanvas.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
        }
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
                .toolbar(.hidden, for: .navigationBar)
        }
        .toolbar(.hidden, for: .tabBar)
        .tabItem { Label(title, systemImage: icon) }
    }
}

private enum QuickAction: Int, Identifiable {
    case menu, live, activeWorkout, workout, journal, breathe, intervals
    var id: Int { rawValue }
}

/// The quick-action route is intentionally separate from the history screen. It observes only the active
/// workout state it needs, chooses a sport once, and then replaces itself with the existing live workout.
private struct QuickWorkoutFlow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    let onClose: () -> Void
    @State private var showLiveWorkout = false

    var body: some View {
        StartWorkoutSheet(dismissAfterStart: false) { sport in
            model.startWorkout(sport: sport)
            showLiveWorkout = true
        }
        .sheet(isPresented: $showLiveWorkout, onDismiss: onClose) {
            LiveWorkoutView(onClose: onClose)
                .environmentObject(model)
                .environmentObject(live)
        }
        .onAppear {
            if model.activeWorkout != nil { showLiveWorkout = true }
        }
    }
}

private struct QuickActionSheet: View {
    let onPick: (QuickAction) -> Void
    @Environment(\.dismiss) private var dismiss

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
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider().overlay(StrandPalette.hairline)

            ScrollView {
                LazyVStack(spacing: 0) {
                    row("Live HR", subtitle: "Start live heart rate", icon: "heart.fill",
                        tint: StrandPalette.liveRed) { onPick(.live) }
                    row("Start workout", subtitle: "Track a workout", icon: "figure.run",
                        tint: StrandPalette.ink) { onPick(.workout) }
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

private struct PaperTabBar: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Binding var selection: Int
    var onReselect: (Int) -> Void = { _ in }
    var onQuickActions: () -> Void = {}

    private struct Item: Identifiable {
        let title: LocalizedStringKey
        let icon: String
        let tag: Int
        var id: Int { tag }
    }

    private let nav = [
        Item(title: "Today", icon: "square.grid.2x2", tag: 0),
        Item(title: "Trends", icon: "chart.bar", tag: 1),
        Item(title: "Sleep", icon: "moon", tag: 2),
        Item(title: "Settings", icon: "gearshape", tag: 3),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(StrandPalette.hairline).frame(height: 1)
            HStack(spacing: 0) {
                ForEach(nav.prefix(2)) { tabButton($0) }
                quickActionsButton
                ForEach(nav.suffix(2)) { tabButton($0) }
            }
            // Larger accessibility categories need vertical room for the user's actual label size.
            // The old app-wide cap hid this fixed-height collision instead of fixing it.
            .frame(height: dynamicTypeSize.isAccessibilitySize ? 92 : NoopMetrics.navBarHeight)
        }
        .background(StrandPalette.card)
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
                Text(item.title)
                    .font(StrandFont.micro.weight(active ? .semibold : .regular))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(active ? StrandPalette.ink : StrandPalette.textTertiary)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}
#endif
