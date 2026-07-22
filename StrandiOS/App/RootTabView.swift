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
    /// Which More-tab groups are expanded. Persisted across navigation and relaunch.
    @AppStorage(MoreSectionPrefs.storageKey) private var expandedMoreSectionsCSV = MoreSectionPrefs.defaultCSV
    private var expandedMoreSections: Set<String> { MoreSectionPrefs.decode(expandedMoreSectionsCSV) }

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
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard selectedTab != 0 else { return }
                    let dx = value.translation.width
                    let dy = value.translation.height
                    guard abs(dx) > 60, abs(dx) > abs(dy) * 1.6 else { return }
                    let next = min(3, max(0, selectedTab + (dx < 0 ? 1 : -1)))
                    if next != selectedTab {
                        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) {
                            selectedTab = next
                        }
                    }
                }
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PaperTabBar(selection: $selectedTab, onReselect: { _ in
                // A reselect is a small UI refresh. It must never reload the full 4,000-day history.
                Task { _ = await repo.refresh(.currentDay) }
            }, onQuickActions: {
                withAnimation(Self.sheetEase) { quickAction = .menu }
            })
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
                subtitle: "Everything else, one tap away",
                onRefresh: { _ = await repo.refresh(.currentDay) },
                topBackground: nil
            ) {
                moreSection("Insights") {
                    MoreRow("What Moves You", "wand.and.sparkles") { InsightsHubView() }
                    MoreRow("Intelligence", "brain.head.profile") { IntelligenceView() }
                    MoreRow("Coach", "sparkles") { CoachView() }
                    MoreRow("Insights", "lightbulb.fill") { InsightsHubView() }
                    MoreRow("Explore", "square.grid.2x2.fill") { MetricExplorerView() }
                    MoreRow("Compare", "rectangle.split.2x1.fill") { CompareView() }
                }
                moreSection("Body") {
                    MoreRow("Live", "waveform.path.ecg") { LiveView() }
                    MoreRow("Workouts", "figure.run") { WorkoutsView() }
                    MoreRow("Health", "heart.text.square.fill") { HealthView() }
                    MoreRow("Lab Book", "books.vertical.fill") { LabBookView() }
                    MoreRow("Stress", "bolt.heart.fill") { StressView() }
                    MoreRow("Breathe", "wind") { BreathingView() }
                    MoreRow("Intervals", "timer") { IntervalTimerView() }
                    MoreRow("Rhythm", "waveform.path") { RhythmHost() }
                }
                moreSection("Data") {
                    MoreRow("Your Data, Fused", "square.stack.3d.up.fill") { FusedRecordHost() }
                    MoreRow("Apple Health", "heart.fill") { AppleHealthView() }
                    MoreRow("Mi Band", "figure.walk.motion") { XiaomiBandView() }
                    MoreRow("Data Sources", "externaldrive.fill") { DataSourcesView() }
                    MoreRow("Backup & Sync", "externaldrive.fill.badge.icloud") { BackupSyncView() }
                    MoreRow("Shortcuts Export", "square.and.arrow.up.fill") { ShortcutExportSettingsView() }
                }
                moreSection("App") {
                    MoreRow("Alarms", "alarm.fill") { SmartAlarmView() }
                    MoreRow("Automations", "wand.and.stars") { AutomationsView() }
                    MoreRow("Test Centre", "stethoscope") { TestCentreView() }
                    MoreRow("Siri & Shortcuts", "mic.fill") { SiriShortcutsSettingsView() }
                    MoreRow("Settings", "gearshape.fill") { SettingsView() }
                    MoreRow("Support", "hands.clap.fill") { SupportView() }
                }
            }
            .toolbar(.hidden, for: .tabBar)
        }
        .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
    }

    @ViewBuilder
    private func moreSection<Rows: View>(
        _ title: String,
        @ViewBuilder rows: @escaping () -> Rows
    ) -> some View {
        let isOpen = expandedMoreSections.contains(title)
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) {
                    var open = expandedMoreSections
                    if isOpen { open.remove(title) } else { open.insert(title) }
                    expandedMoreSectionsCSV = MoreSectionPrefs.encode(open)
                }
            } label: {
                HStack(spacing: 6) {
                    SectionHeader(LocalizedStringKey(title))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .rotationEffect(.degrees(isOpen ? 0 : -90))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(isOpen ? String(localized: "Expanded") : String(localized: "Collapsed")))
            .accessibilityHint(Text(isOpen ? String(localized: "Double tap to collapse") : String(localized: "Double tap to expand")))

            if isOpen {
                PaperCard(padding: 0) {
                    VStack(spacing: 0) { rows() }
                        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
                }
            }
        }
    }
}

private struct MoreRow<Destination: View>: View {
    let title: LocalizedStringKey
    let icon: String
    @ViewBuilder let destination: () -> Destination

    init(
        _ title: LocalizedStringKey,
        _ icon: String,
        @ViewBuilder _ destination: @escaping () -> Destination
    ) {
        self.title = title
        self.icon = icon
        self.destination = destination
    }

    var body: some View {
        NavigationLink {
            destination()
                .background(StrandPalette.appCanvas.ignoresSafeArea())
                .environment(\.screenScaffoldNavigationRole, .detail)
                .toolbar(.hidden, for: .navigationBar)
        } label: {
            SettingsRow(icon: icon, title: title, showsChevron: true)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(StrandPalette.hairline)
                        .frame(height: 1)
                        .padding(.leading, 16)
                }
        }
        .buttonStyle(.plain)
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
            .frame(height: NoopMetrics.navBarHeight)
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
