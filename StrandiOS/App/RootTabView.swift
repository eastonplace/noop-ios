#if os(iOS)
import SwiftUI
import StrandDesign

/// iOS navigation shell. macOS uses a `NavigationSplitView` sidebar (`RootView`); on iPhone the
/// natural analogue is a `TabView` with the most-used screens as tabs and everything else under a
/// "More" list. Every screen is the same `StrandDesign`-built view the macOS app uses.
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
    /// Selected tab — bound so tab switches can crossfade (README §Motion: ~240ms opacity swap
    /// between tab roots, calm easing). Defaults to Today.
    @State private var selectedTab: Int
    /// Which More-tab groups are expanded (S2). Insights + Body stay open at rest; Data + App collapse to
    /// just their header until tapped. Persisted (#860 item 2): the user's open/closed choice must SURVIVE
    /// leaving and re-entering the More tab (and relaunch), not reset to the seed every visit. Backed by an
    /// `@AppStorage` CSV string (keyed identically to the Android `MoreSectionPrefs`), bridged to a
    /// `Set<String>` through `MoreSectionPrefs` so the section logic below is unchanged.
    @AppStorage(MoreSectionPrefs.storageKey) private var expandedMoreSectionsCSV = MoreSectionPrefs.defaultCSV
    private var expandedMoreSections: Set<String> { MoreSectionPrefs.decode(expandedMoreSectionsCSV) }

    /// R7: Paper is the sole Today surface.
    private var todayTabRoot: some View { TodayView() }

    init() {
        var initialTab = 0
        #if DEBUG
        // Screenshot/QA harness: launch directly into a tab without UI automation permissions.
        // Release builds always retain the normal Today default.
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
                .onEnded { v in
                    guard selectedTab != 0 else { return }
                    let dx = v.translation.width, dy = v.translation.height
                    guard abs(dx) > 60, abs(dx) > abs(dy) * 1.6 else { return }
                    let next = min(3, max(0, selectedTab + (dx < 0 ? 1 : -1)))
                    if next != selectedTab {
                        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = next }
                    }
                }
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PaperTabBar(selection: $selectedTab, onReselect: { _ in
                // Re-tapping the active tab refreshes that page's data (2026-07-02).
                Task { await repo.refresh() }
            }, onQuickActions: {
                withAnimation(Self.sheetEase) { quickAction = .menu }
            })
        }
        .task {
            await repo.refresh()
            // Backup & Sync: on-launch catch-up (see RootView). Detached + utility priority so a
            // 100MB+ whole-DB ZIP never blocks startup; gated on the auto toggle (default OFF). (Must-fix #4.)
            let backupRepo = repo
            Task.detached(priority: .utility) {
                await FolderBackup.catchUpIfDue(checkpoint: { await backupRepo.checkpointForBackup() })
            }
        }
        // Quick-action sheet presents with the calm easing (~0.42s) per the README sheet spec —
        // the easing is applied where `quickAction` is set (see `presentQuickAction`), keeping the
        // animation scoped to the sheet rather than the whole shell.
        .sheet(item: $quickAction) { action in
            quickActionDestination(action)
        }
        // Live's "Manage devices" affordance (and any future cross-screen link to Devices) routes here:
        // present the Devices manager in its own nav stack, the same way the quick-action screens do.
        .sheet(isPresented: $showDevices) {
            devicesScreen
        }
        // v5 pillar deep-links (Insights hub / Lab Book / fused record / Rhythm) present as a sheet in
        // their own nav stack — the same idiom the quick-action + Devices screens use on iPhone.
        .sheet(item: $routedPillar) { dest in
            pillarScreen(dest)
        }
        // Honour a router request: Devices keeps its dedicated sheet; the v5 pillars route through the
        // shared pillar sheet. Cleared so the same tap can fire again later.
        .onChange(of: router.requestedDestination) { _, dest in
            switch dest {
            case .devices:
                showDevices = true
                router.requestedDestination = nil
            case .insightsHub, .labBook, .fusedRecord, .rhythm, .settings, .updates:
                routedPillar = dest
                router.requestedDestination = nil
            case .trends:
                // Trends is a primary tab on iPhone (not a pillar sheet) — switch to it.
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 1 }
                router.requestedDestination = nil
            case .activeWorkout:
                // The Today active-workout indicator opens Live through the quick-action Live sheet; once
                // it's up, LiveView consumes the one-shot `presentActiveWorkout` flag and presents the
                // in-exercise screen. Calm sheet easing, matching the other quick-action presents.
                withAnimation(Self.sheetEase) { quickAction = .live }
                router.requestedDestination = nil
            case .liveSession:
                // Live Sessions is presented from Today's own Start entry (a cover, not a routed sheet),
                // so a deep-link lands on the Today tab where that entry lives.
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 0 }
                router.requestedDestination = nil
            case nil:
                break
            }
        }
        // A screen's top-bar "+" routes here: open the quick-action sheet, then clear the flag.
        .onChange(of: router.quickActionsRequested) { _, req in
            if req {
                withAnimation(Self.sheetEase) { quickAction = .menu }
                router.quickActionsRequested = false
            }
        }
    }

    /// A routed v5 pillar screen wrapped in its own nav stack + Done button (mirrors `quickScreen`).
    @ViewBuilder
    private func pillarScreen(_ dest: NavRouter.Destination) -> some View {
        NavigationStack {
            Group {
                switch dest {
                case .insightsHub: InsightsHubView()
                case .labBook: LabBookView()
                case .fusedRecord: FusedRecordHost()
                case .rhythm: RhythmHost(onClose: { routedPillar = nil })
                case .devices: DevicesView()
                // .trends is never presented as a pillar sheet on iPhone (it's a primary tab — the
                // requestedDestination handler switches `selectedTab` instead), but the switch must stay
                // exhaustive. Fall back to Trends inside the sheet host if it ever arrives here.
                case .trends: TrendsView()
                // .activeWorkout routes through the quick-action Live sheet (handled above); this keeps the
                // switch exhaustive and falls back to Live if it ever reaches the pillar host.
                case .activeWorkout: LiveView()
                // .liveSession routes to the Today tab (handled above — its Start entry owns the cover);
                // this keeps the switch exhaustive and falls back to Today if it ever reaches the host.
                case .liveSession: TodayView()
                case .settings: SettingsView()
                case .updates: UpdatesInboxView(onClose: { routedPillar = nil })
                }
            }
            .background(StrandPalette.appCanvas.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            // #1027: same fix as quickScreen — the pillar screens draw the full-bleed liquid sky, so a
            // transparent nav bar keeps it edge-to-edge instead of an opaque band clipping the top on scroll.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { routedPillar = nil }
                        .foregroundStyle(StrandPalette.accent)
                }
            }
        }
    }

    /// Calm-easing curve (cubic-bezier(0.22,1,0.36,1)) at the README sheet-present duration.
    private static let sheetEase = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.42)

    // MARK: - Quick-action sheet

    /// Routes a chosen quick action to the existing screen, or shows the action menu itself.
    @ViewBuilder
    private func quickActionDestination(_ action: QuickAction) -> some View {
        switch action {
        case .menu:
            QuickActionSheet { picked in
                // Swap the menu for the chosen destination on the next runloop so the sheet
                // re-presents cleanly (avoids dismiss/re-present races). Calm easing on re-present.
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

    /// Wraps a routed quick-action screen in its own nav stack so it has a title bar + the
    /// shared surface background, matching how the More-tab links present these same views.
    private func quickScreen<V: View>(_ view: V) -> some View {
        NavigationStack {
            view
                .background(StrandPalette.appCanvas.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                // #1027: these screens draw a full-bleed liquid sky (ScreenScaffold topBackground) that runs
                // edge-to-edge under a transparent bar — exactly how the tab roots present it. An OPAQUE
                // surfaceBase toolbar background sat on top of that sky and, as the content scrolled up, its
                // extended status-bar band CLIPPED the sky + the in-content header ("Live Body Console").
                // Hiding the bar background lets the sky stay continuous under the floating Done button.
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { quickAction = nil }
                            .foregroundStyle(StrandPalette.accent)
                    }
                }
        }
    }

    /// The Devices manager wrapped in its own nav stack + Done button (mirrors `quickScreen`, but
    /// dismisses the dedicated `showDevices` sheet rather than the quick-action item).
    private var devicesScreen: some View {
        NavigationStack {
            DevicesView()
                .background(StrandPalette.appCanvas.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                // #1027: same fix as quickScreen — Devices draws the full-bleed liquid sky, so a transparent
                // nav bar keeps it edge-to-edge instead of an opaque band clipping the top on scroll.
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showDevices = false }
                            .foregroundStyle(StrandPalette.accent)
                    }
                }
        }
    }

    private func tab<V: View>(_ view: V, _ title: LocalizedStringKey, _ icon: String) -> some View {
        // Each primary tab gets its OWN NavigationStack so the in-content NavigationLinks (e.g. the Today
        // dashboard card rows) both navigate AND render opaque. An ORPHANED NavigationLink (no
        // NavigationStack ancestor) renders its whole label in a disabled/translucent state — that was
        // washing the Today cards over the hero scene and dimming their text to grey (2026-06-23).
        // The root view hides the system nav bar (each screen draws its own in-content header); pushed
        // detail screens get their own nav bar + back button.
        NavigationStack {
            view
                .background(StrandPalette.appCanvas.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
        }
        .toolbar(.hidden, for: .tabBar)   // we draw our own PaperTabBar
        .tabItem { Label(title, systemImage: icon) }
    }

    // The "More" tab is the app's catch-all index. It was a plain SwiftUI `List` with system large-title
    // + system title-case section headers, so it didn't match any other page (which all use ScreenScaffold
    // + SectionHeader's UPPERCASE overline + the 28pt section rhythm). Rebuilt on the shared page chrome:
    // ScreenScaffold for the title1 "More" + subtitle, a `SectionHeader` overline per group, and the group's
    // rows in a single grouped NoopCard with hairline dividers — the same row idiom Settings/Health use.
    private var moreTab: some View {
        NavigationStack {
            ScreenScaffold(title: "More", subtitle: "Everything else, one tap away",
                           onRefresh: { await repo.refresh() },
                           topBackground: nil) {
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
                    // Experimental beat-to-beat regularity visualization — self-gates on its own consent.
                    MoreRow("Rhythm", "waveform.path") { RhythmHost() }
                }
                moreSection("Data") {
                    MoreRow("Your Data, Fused", "square.stack.3d.up.fill") { FusedRecordHost() }
                    MoreRow("Apple Health", "heart.fill") { AppleHealthView() }
                    MoreRow("Mi Band", "figure.walk.motion") { XiaomiBandView() }
                    MoreRow("Data Sources", "externaldrive.fill") { DataSourcesView() }
                    MoreRow("Backup & Sync", "externaldrive.fill.badge.icloud") { BackupSyncView() }
                    // #155: HealthKit-free Apple Health path for sideloaded installs (Siri Shortcut
                    // reads the opt-in Documents/noop_sync.txt drop file).
                    MoreRow("Shortcuts Export", "square.and.arrow.up.fill") { ShortcutExportSettingsView() }
                }
                moreSection("App") {
                    // #805/#811: the v7.3.1 #766 alarm consolidation moved Smart Alarm under a single
                    // "Alarms" sidebar entry (RootView .smartAlarm) but the regression dropped the row
                    // from the iPhone More list, leaving Alarms unreachable on iPhone. Restore it here
                    // (route to SmartAlarmView, the cross-platform iOS/macOS surface).
                    //
                    // Notifications (RootView .notifications) is deliberately NOT added: that screen is
                    // macOS-only (it picks which Mac apps tap your wrist via NSWorkspace, imports AppKit,
                    // and project.yml excludes Screens/NotificationSettingsView.swift from the iOS target),
                    // so it can't compile or apply on iPhone. iPhone's wrist-alert controls live on the
                    // Automations screen instead. Its absence from the iPhone More list is correct.
                    MoreRow("Alarms", "alarm.fill") { SmartAlarmView() }
                    MoreRow("Automations", "wand.and.stars") { AutomationsView() }
                    // The Test Centre (the diagnostics + bug-report hub) gets a first-class home here, not
                    // just buried in Settings, so the feedback loop is one tap from the More tab.
                    MoreRow("Test Centre", "stethoscope") { TestCentreView() }
                    MoreRow("Siri & Shortcuts", "mic.fill") { SiriShortcutsSettingsView() }
                    MoreRow("Settings", "gearshape.fill") { SettingsView() }
                    MoreRow("Support", "hands.clap.fill") { SupportView() }
                }
            }
            .toolbar(.hidden, for: .tabBar)   // we draw our own PaperTabBar
        }
        .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
    }

    /// One titled, COLLAPSIBLE group in the More index (S2): the app's overline (UPPERCASE) becomes a
    /// tappable header with a disclosure chevron; tapping it expands/collapses the grouped rows card.
    /// Insights + Body default open, Data + App default collapsed (the `expandedMoreSections` seed) so the
    /// list is shorter at rest without dropping a single row. The grouped card is unchanged: a single
    /// `NoopCard` holding a `VStack(spacing: 0)` whose `MoreRow`s draw their own hairlines, clipped to the
    /// card's rounded shape so the last divider is trimmed inside the corners. Same idiom Settings/Health use.
    @ViewBuilder
    private func moreSection<Rows: View>(_ title: String,
                                         @ViewBuilder rows: @escaping () -> Rows) -> some View {
        let isOpen = expandedMoreSections.contains(title)
        VStack(alignment: .leading, spacing: 10) {
            // Tappable overline header: the same ALL-CAPS tracked label as before, now with a trailing
            // chevron that rotates open. A plain Button (not a SwiftUI DisclosureGroup) so the header keeps
            // the exact strandOverline styling and the card layout below stays identical to before.
            Button {
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) {
                    // Persist the toggle via the CSV-backed @AppStorage so the choice survives leaving and
                    // re-entering the More tab and relaunch (#860 item 2). MoreSectionPrefs owns encode/decode.
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
                // Zero internal padding so each MoreRow owns its own comfortable insets + height; the rows
                // supply their own hairline separators (drawn at the bottom of every row but the last via the
                // divider overlay) so the group reads as one continuous grouped list, matching Settings/Health.
                PaperCard(padding: 0) {
                    VStack(spacing: 0) { rows() }
                        // Clip the rows column to the card's rounded shape so the last row's bottom hairline is
                        // trimmed inside the corners (the card draws its surface in the BACKGROUND and doesn't
                        // clip content itself, so without this the final divider would run past the rounded edge).
                        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
                }
            }
        }
    }
}

/// One tappable destination row in the More index. A `NavigationLink` whose label is the standard app row:
/// the SF Symbol icon tinted `StrandPalette.accent`, the title in the body text colour, a `Spacer`, and a
/// trailing `chevron.right` in `textTertiary`. ~44pt min height + the card's row insets keep the whole row a
/// comfortable tap target. Each destination keeps the per-screen wrapper the old `link()` applied
/// (`surfaceBase` background, inline title-bar, toolbar background) so pushed pages look identical to before.
private struct MoreRow<Destination: View>: View {
    let title: LocalizedStringKey
    let icon: String
    @ViewBuilder let destination: () -> Destination

    init(_ title: LocalizedStringKey, _ icon: String,
         @ViewBuilder _ destination: @escaping () -> Destination) {
        self.title = title; self.icon = icon; self.destination = destination
    }

    var body: some View {
        NavigationLink {
            destination()
                .background(StrandPalette.appCanvas.ignoresSafeArea())
                // Pushed app pages use ScreenScaffold's own expanded/compact header and back action.
                // Quick-action, pillar and device sheets intentionally keep their native Done toolbars.
                .environment(\.screenScaffoldNavigationRole, .detail)
                .toolbar(.hidden, for: .navigationBar)
        } label: {
            SettingsRow(icon: icon, title: title, showsChevron: true)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Hairline under every row; the grouped container clips the last one's overflow so the bottom
            // edge stays clean (the divider sits inside the card's rounded corners).
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

// MARK: - Quick actions (centre FAB)

/// The destinations the centre FAB can present. `.menu` is the action sheet itself; the rest
/// route to existing screens. `Identifiable` so it drives `.sheet(item:)`.
private enum QuickAction: Int, Identifiable {
    case menu, live, workout, journal, breathe
    var id: Int { rawValue }
}

/// Paper quick actions: the four existing routes, presented as quiet full-width rows.
private struct QuickActionSheet: View {
    /// Called with the picked destination (the host swaps the menu for that screen).
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

    private func row(_ title: LocalizedStringKey, subtitle: LocalizedStringKey,
                     icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.10), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(StrandFont.body.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                    Text(subtitle).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
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

// MARK: - Paper tab bar

private struct PaperTabBar: View {
    @Binding var selection: Int
    /// Fires when the user taps the ALREADY-active tab (2026-07-02: re-tap should refresh).
    var onReselect: (Int) -> Void = { _ in }
    /// Opens the Quick Actions sheet from the centre-docked FAB (board v2, spec 003 D4).
    var onQuickActions: () -> Void = {}

    private struct Item: Identifiable { let title: LocalizedStringKey; let icon: String; let tag: Int; var id: Int { tag } }
    private let nav = [Item(title: "Today", icon: "square.grid.2x2", tag: 0),
                       Item(title: "Trends", icon: "chart.bar", tag: 1),
                       Item(title: "Sleep", icon: "moon", tag: 2),
                       Item(title: "More", icon: "ellipsis", tag: 3)]

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

    /// Centre-docked ink FAB (board v2): sits inline in the bar, same Quick Actions sheet
    /// the old floating button opened.
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
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selection = item.tag }
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
