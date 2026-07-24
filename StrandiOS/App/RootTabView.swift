#if os(iOS)
import SwiftUI
import StrandDesign

/// iOS navigation shell. On iPhone the natural structure is a `TabView` with the most-used screens as
/// tabs and everything else under a "More" list.
struct RootTabView: View {
    @EnvironmentObject private var repo: Repository
    /// Cross-screen navigation requests (e.g. Live → "Manage devices"). Devices isn't a tab — it lives
    /// behind the More list — so a request presents it as a sheet, matching the quick-action screens.
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
            initialTab = requested == "trends" ? 1 : 0
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
            moreTab.tag(3)
        }
        .toolbar(.hidden, for: .tabBar)
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24), value: selectedTab)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PaperTabBar(selection: $selectedTab, onReselect: { _ in
                // A reselect is a small UI refresh. It must never reload the full 4,000-day history.
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
            case .insightsHub, .labBook, .fusedRecord, .rhythm, .settings, .updates:
                routedPillar = destination
                router.requestedDestination = nil
            case .trends:
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 1 }
                router.requestedDestination = nil
            case .activeWorkout:
                withAnimation(Self.sheetEase) { quickAction = .live }
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
                case .activeWorkout: LiveView()
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
            .presentationDetents([.height(390)])
            .presentationDragIndicator(.hidden)
        case .live:
            quickScreen(LiveView())
        case .workout:
            quickScreen(WorkoutsView())
        case .journal:
            quickScreen(CoachingRootView())
        case .breathe:
            quickScreen(BreathingView())
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

    private func tab<V: View>(_ view: V, _ title: LocalizedStringKey, _ icon: String) -> some View {
        NavigationStack {
            view
                .background(StrandPalette.appCanvas.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
        }
        .toolbar(.hidden, for: .tabBar)
        .tabItem { Label(title, systemImage: icon) }
    }

    private var moreTab: some View {
        NavigationStack {
            ScreenScaffold(
                title: "More",
                subtitle: "Tools grouped by what you are trying to do",
                onRefresh: { _ = await repo.refresh(.currentDay) },
                topBackground: nil
            ) {
                SettingsScreenTemplate(sections: moreSections)
            }
            .toolbar(.hidden, for: .tabBar)
        }
        .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
    }

    private var moreSections: [SettingsSectionModel] {
        [
            SettingsSectionModel(
                id: "browse",
                header: "Browse",
                footer: "Open a focused group instead of scanning one long wall of tools.",
                rows: [
                    .navDetail(
                        id: "understand",
                        icon: "brain.head.profile",
                        tint: StrandPalette.metricPurple,
                        title: "Understand your data",
                        subtitle: "Patterns, coaching, metric exploration, and comparisons"
                    ) {
                        MoreCategoryView(
                            title: "Understand",
                            subtitle: "Turn your history into patterns and decisions",
                            rows: understandRows
                        )
                    },
                    .navDetail(
                        id: "train-recover",
                        icon: "figure.run.circle.fill",
                        tint: StrandPalette.strainAccent,
                        title: "Train & recover",
                        subtitle: "Live data, workouts, health, stress, breathing, and timing"
                    ) {
                        MoreCategoryView(
                            title: "Train & recover",
                            subtitle: "Record, review, and regulate your body",
                            rows: trainRecoverRows
                        )
                    },
                    .navDetail(
                        id: "data-devices",
                        icon: "externaldrive.connected.to.line.below.fill",
                        tint: StrandPalette.metricCyan,
                        title: "Data & devices",
                        subtitle: "Sources, Apple Health, fused records, backups, and exports"
                    ) {
                        MoreCategoryView(
                            title: "Data & devices",
                            subtitle: "Connect, inspect, move, and protect your data",
                            rows: dataDeviceRows
                        )
                    },
                    .navDetail(
                        id: "plan-automate",
                        icon: "wand.and.stars",
                        tint: StrandPalette.metricAmber,
                        title: "Plan & automate",
                        subtitle: "Alarms, automations, diagnostics, and Siri shortcuts"
                    ) {
                        MoreCategoryView(
                            title: "Plan & automate",
                            subtitle: "Set up routines and technical tools",
                            rows: planAutomateRows
                        )
                    },
                ]
            ),
            SettingsSectionModel(
                id: "account-help",
                header: "Account & Help",
                rows: [
                    .navDetail(
                        id: "settings",
                        icon: "gearshape.fill",
                        tint: StrandPalette.textSecondary,
                        title: "Settings",
                        subtitle: "Profile, device, scoring, appearance, privacy, and advanced tools"
                    ) { SettingsView() },
                    .navDetail(
                        id: "support",
                        icon: "heart.fill",
                        tint: StrandPalette.metricRose,
                        title: "Support",
                        subtitle: "Help, troubleshooting, and support for the project"
                    ) { SupportView() },
                ]
            ),
        ]
    }

    private var understandRows: [SettingsRowModel] {
        [
            .navDetail(
                id: "what-moves-you",
                icon: "wand.and.sparkles",
                tint: StrandPalette.metricPurple,
                title: "What Moves You",
                subtitle: "Your strongest relationships and recurring behavior signals"
            ) { InsightsHubView() },
            .navDetail(
                id: "intelligence",
                icon: "brain.head.profile",
                tint: StrandPalette.recoveryData,
                title: "Intelligence",
                subtitle: "Forecasts, confidence, and engine-backed explanations"
            ) { IntelligenceView() },
            .navDetail(
                id: "coach",
                icon: "sparkles",
                tint: StrandPalette.metricAmber,
                title: "Coach",
                subtitle: "Personalized guidance grounded in your local history"
            ) { CoachView() },
            .navDetail(
                id: "explore",
                icon: "square.grid.2x2.fill",
                tint: StrandPalette.metricCyan,
                title: "Explore metrics",
                subtitle: "Open every recorded and derived metric in one catalog"
            ) { MetricExplorerView() },
            .navDetail(
                id: "compare",
                icon: "rectangle.split.2x1.fill",
                tint: StrandPalette.sleepAccent,
                title: "Compare",
                subtitle: "Place two periods or metrics side by side"
            ) { CompareView() },
        ]
    }

    private var trainRecoverRows: [SettingsRowModel] {
        [
            .navDetail(
                id: "live",
                icon: "waveform.path.ecg",
                tint: StrandPalette.liveRed,
                title: "Live",
                subtitle: "Current heart rate, strap state, and live session controls"
            ) { LiveView() },
            .navDetail(
                id: "workouts",
                icon: "figure.run",
                tint: StrandPalette.strainAccent,
                title: "Workouts",
                subtitle: "Record, finish, edit, and review training sessions"
            ) { WorkoutsView() },
            .navDetail(
                id: "health",
                icon: "heart.text.square.fill",
                tint: StrandPalette.metricRose,
                title: "Health",
                subtitle: "Vitals, trends, flags, and health context"
            ) { HealthView() },
            .navDetail(
                id: "lab-book",
                icon: "books.vertical.fill",
                tint: StrandPalette.metricPurple,
                title: "Lab Book",
                subtitle: "Experiments, observations, and personal evidence"
            ) { LabBookView() },
            .navDetail(
                id: "stress",
                icon: "bolt.heart.fill",
                tint: StrandPalette.stressAccent,
                title: "Stress",
                subtitle: "Daytime stress, check-ins, and regulation tools"
            ) { StressView() },
            .navDetail(
                id: "breathe",
                icon: "wind",
                tint: StrandPalette.recoveryData,
                title: "Breathe",
                subtitle: "Guided breathing sessions with live feedback"
            ) { BreathingView() },
            .navDetail(
                id: "intervals",
                icon: "timer",
                tint: StrandPalette.metricAmber,
                title: "Intervals",
                subtitle: "Simple interval timing for structured sessions"
            ) { IntervalTimerView() },
            .navDetail(
                id: "rhythm",
                icon: "waveform.path",
                tint: StrandPalette.sleepAccent,
                title: "Rhythm",
                subtitle: "Daily timing, sleep regularity, and circadian patterns"
            ) { RhythmHost() },
        ]
    }

    private var dataDeviceRows: [SettingsRowModel] {
        [
            .navDetail(
                id: "fused-record",
                icon: "square.stack.3d.up.fill",
                tint: StrandPalette.metricPurple,
                title: "Your data, fused",
                subtitle: "One chronological record across local sources"
            ) { FusedRecordHost() },
            .navDetail(
                id: "apple-health",
                icon: "heart.fill",
                tint: StrandPalette.metricRose,
                title: "Apple Health",
                subtitle: "Read and write permissions, sync, and source status"
            ) { AppleHealthView() },
            .navDetail(
                id: "mi-band",
                icon: "figure.walk.motion",
                tint: StrandPalette.metricCyan,
                title: "Mi Band",
                subtitle: "Xiaomi band connection and supported data"
            ) { XiaomiBandView() },
            .navDetail(
                id: "data-sources",
                icon: "externaldrive.fill",
                tint: StrandPalette.metricCyan,
                title: "Data Sources",
                subtitle: "Imports, source priority, storage, and cleanup"
            ) { DataSourcesView() },
            .navDetail(
                id: "backup-sync",
                icon: "externaldrive.fill.badge.icloud",
                tint: StrandPalette.sleepAccent,
                title: "Backup & Sync",
                subtitle: "Create, restore, and inspect portable backups"
            ) { BackupSyncView() },
            .navDetail(
                id: "shortcuts-export",
                icon: "square.and.arrow.up.fill",
                tint: StrandPalette.metricAmber,
                title: "Shortcuts Export",
                subtitle: "Configure files and values exposed to Shortcuts"
            ) { ShortcutExportSettingsView() },
        ]
    }

    private var planAutomateRows: [SettingsRowModel] {
        [
            .navDetail(
                id: "alarms",
                icon: "alarm.fill",
                tint: StrandPalette.sleepAccent,
                title: "Alarms",
                subtitle: "Wake mode, weekdays, wind-down, test buzz, and backup status"
            ) { SmartAlarmView() },
            .navDetail(
                id: "automations",
                icon: "wand.and.stars",
                tint: StrandPalette.metricPurple,
                title: "Automations",
                subtitle: "Run local actions from strap and app events"
            ) { AutomationsView() },
            .navDetail(
                id: "test-centre",
                icon: "stethoscope",
                tint: StrandPalette.metricCyan,
                title: "Test Centre",
                subtitle: "Connection, sensor, scoring, and notification checks"
            ) { TestCentreView() },
            .navDetail(
                id: "siri-shortcuts",
                icon: "mic.fill",
                tint: StrandPalette.metricRose,
                title: "Siri & Shortcuts",
                subtitle: "Voice and system actions exposed by NOOP"
            ) { SiriShortcutsSettingsView() },
        ]
    }
}

private struct MoreCategoryView: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let rows: [SettingsRowModel]

    var body: some View {
        ScreenScaffold(title: title, subtitle: subtitle, lazy: true, topBackground: nil) {
            SettingsScreenTemplate(
                sections: [
                    SettingsSectionModel(
                        id: "tools",
                        header: "Tools",
                        rows: rows
                    )
                ]
            )
        }
        .environment(\.screenScaffoldNavigationRole, .detail)
    }
}

private enum QuickAction: Int, Identifiable {
    case menu, live, workout, journal, breathe
    var id: Int { rawValue }
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

            row("Live HR", subtitle: "Start live heart rate", icon: "heart.fill",
                tint: StrandPalette.liveRed) { onPick(.live) }
            row("Start workout", subtitle: "Track a workout", icon: "figure.run",
                tint: StrandPalette.ink) { onPick(.workout) }
            row("Log journal", subtitle: "How are you feeling?", icon: "square.and.pencil",
                tint: StrandPalette.journalAccent) { onPick(.journal) }
            row("Breathe", subtitle: "Guided breathing", icon: "wind",
                tint: StrandPalette.chargeAccent) { onPick(.breathe) }

            Spacer(minLength: 0)
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
        Item(title: "More", icon: "ellipsis", tag: 3),
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
