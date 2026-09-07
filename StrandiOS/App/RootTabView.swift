#if os(iOS)
import SwiftUI
import StrandDesign

struct RootTabView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var router: NavRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var quickAction: QuickAction?
    @State private var pendingQuickAction: QuickAction?
    @State private var showDevices = false
    @State private var routedPillar: NavRouter.Destination?
    @State private var selectedTab: Int
    private var todayTabRoot: some View { TodayView() }

    init() {
        var initialTab = 0
        #if DEBUG
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
        .animation(reduceMotion ? nil : Self.navigationEase, value: selectedTab)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PaperTabBar(selection: $selectedTab, onReselect: { tab in
                guard tab == 0 else { return }
                Task { _ = await repo.refresh(.currentDay) }
            }, onQuickActions: {
                withAnimation(reduceMotion ? nil : Self.sheetEase) { quickAction = .menu }
            })
        }
        .background {
            SmartAlarmCommandReconciler().allowsHitTesting(false).accessibilityHidden(true)
        }
        .task {
            let backupRepo = repo
            Task.detached(priority: .utility) {
                await FolderBackup.catchUpIfDue(checkpoint: { await backupRepo.checkpointForBackup() })
            }
        }
        .sheet(item: $quickAction, onDismiss: {
            // Present only after the menu finished dismissing. A timed 50 ms delay races UIKit.
            if let pending = pendingQuickAction {
                pendingQuickAction = nil
                quickAction = pending
            }
        }) { action in quickActionDestination(action) }
        .sheet(isPresented: $showDevices) { devicesScreen }
        .sheet(item: $routedPillar) { destination in pillarScreen(destination) }
        .onChange(of: router.requestedDestination) { _, destination in
            switch destination {
            case .devices:
                showDevices = true
                router.requestedDestination = nil
            case .insightsHub, .labBook, .fusedRecord, .rhythm, .updates:
                routedPillar = destination
                router.requestedDestination = nil
            case .settings:
                withAnimation(reduceMotion ? nil : Self.navigationEase) { selectedTab = 3 }
                router.requestedDestination = nil
            case .trends:
                withAnimation(reduceMotion ? nil : Self.navigationEase) { selectedTab = 1 }
                router.requestedDestination = nil
            case .activeWorkout:
                router.presentActiveWorkout = false
                quickAction = .activeWorkout
                router.requestedDestination = nil
            case .liveSession:
                withAnimation(reduceMotion ? nil : Self.navigationEase) { selectedTab = 0 }
                router.requestedDestination = nil
            case nil: break
            }
        }
        .onChange(of: router.quickActionsRequested) { _, requested in
            if requested {
                quickAction = .menu
                router.quickActionsRequested = false
            }
        }
    }

    @ViewBuilder private func pillarScreen(_ destination: NavRouter.Destination) -> some View {
        if destination == .activeWorkout {
            LiveWorkoutView(onClose: { routedPillar = nil })
        } else {
            NavigationStack {
                Group {
                    switch destination {
                    case .insightsHub: InsightsHubView()
                    case .labBook: LabBookView()
                    case .fusedRecord: FusedRecordHost()
                    case .rhythm: RhythmHost(onClose: { routedPillar = nil })
                    case .devices: DevicesView()
                    case .trends: TrendsView()
                    case .activeWorkout: EmptyView()
                    case .liveSession: TodayView()
                    case .settings: SettingsView()
                    case .updates: UpdatesInboxView(onClose: { routedPillar = nil })
                    }
                }
                .background(StrandPalette.appCanvas.ignoresSafeArea())
                .noopFocusedTask()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { routedPillar = nil }.foregroundStyle(StrandPalette.accent)
                    }
                }
            }
        }
    }
    private static let sheetEase = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.42)
    private static let navigationEase = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)

    @ViewBuilder private func quickActionDestination(_ action: QuickAction) -> some View {
        switch action {
        case .menu:
            QuickActionSheet { picked in
                pendingQuickAction = picked
                quickAction = nil
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        case .live: quickScreen(LiveView())
        case .activeWorkout: LiveWorkoutView(onClose: { quickAction = nil })
        case .workout: QuickWorkoutFlow(onClose: { quickAction = nil })
        case .journal: CoachingRootView()
        case .breathe: quickScreen(BreathingView())
        case .intervals: quickScreen(IntervalTimerView())
        }
    }
    private func quickScreen<V: View>(_ view: V) -> some View {
        NavigationStack {
            view
                .background(StrandPalette.appCanvas.ignoresSafeArea())
                .noopFocusedTask()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { quickAction = nil }.foregroundStyle(StrandPalette.accent)
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
    private var settingsTab: some View {
        NavigationStack {
            SettingsView().background(Color(.systemGroupedBackground).ignoresSafeArea())
        }
        .environment(\.screenScaffoldPresentation, .settingsDetail)
        .environment(\.appHeaderChromeVisibility, .hidden)
        .toolbar(.hidden, for: .tabBar)
        .tabItem { Label("Settings", systemImage: "gearshape") }
    }
    private func tab<V: View>(_ view: V, _ title: LocalizedStringKey, _ icon: String) -> some View {
        NavigationStack {
            view.background(StrandPalette.appCanvas.ignoresSafeArea()).toolbar(.hidden, for: .navigationBar)
        }
        .toolbar(.hidden, for: .tabBar)
        .tabItem { Label(title, systemImage: icon) }
    }
}

private enum QuickAction: Int, Identifiable {
    case menu, live, activeWorkout, workout, journal, breathe, intervals
    var id: Int { rawValue }
}

private struct QuickWorkoutFlow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    let onClose: () -> Void
    @State private var showLiveWorkout = false
    @State private var failedToStart = false
    var body: some View {
        StartWorkoutSheet(dismissAfterStart: false) { sport in
            model.startWorkout(sport: sport)
            showLiveWorkout = model.activeWorkout != nil
            failedToStart = !showLiveWorkout
        }
        .sheet(isPresented: $showLiveWorkout, onDismiss: onClose) {
            LiveWorkoutView(onClose: { showLiveWorkout = false })
                .environmentObject(model).environmentObject(live)
        }
        .onAppear { if model.activeWorkout != nil { showLiveWorkout = true } }
        .alert("Workout did not start", isPresented: $failedToStart) {
            Button("OK", role: .cancel) {}
        } message: { Text("The recording could not start. Review the current workout state and try again.") }
    }
}

private struct QuickActionSheet: View {
    let onPick: (QuickAction) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Quick Actions").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textPrimary).frame(width: 44, height: 44)
                        .background(StrandPalette.inset, in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("Close quick actions")
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            Divider().overlay(StrandPalette.hairline)
            ScrollView {
                LazyVStack(spacing: 0) {
                    row("Live HR", subtitle: "Start live heart rate", icon: "heart.fill", tint: StrandPalette.liveRed) { onPick(.live) }
                    row("Start workout", subtitle: "Track a workout", icon: "figure.run", tint: StrandPalette.ink) { onPick(.workout) }
                    row("Log journal", subtitle: "Review your daily check-in", icon: "square.and.pencil", tint: StrandPalette.journalAccent) { onPick(.journal) }
                    row("Breathe", subtitle: "Guided breathing", icon: "wind", tint: StrandPalette.chargeAccent) { onPick(.breathe) }
                    row("Intervals", subtitle: "Run an interval timer", icon: "timer", tint: StrandPalette.strainAccent) { onPick(.intervals) }
                }
            }.scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(StrandPalette.card.ignoresSafeArea())
    }
    private func row(_ title: LocalizedStringKey, subtitle: LocalizedStringKey, icon: String,
                     tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 38, height: 38).background(tint.opacity(0.10), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(StrandFont.body.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                    Text(subtitle).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.horizontal, 20).frame(minHeight: 68)
            .overlay(alignment: .bottom) { Rectangle().fill(StrandPalette.hairline).frame(height: 1).padding(.leading, 52) }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct PaperTabBar: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            .frame(height: dynamicTypeSize.isAccessibilitySize ? 92 : NoopMetrics.navBarHeight)
        }.background(StrandPalette.card)
    }
    private var quickActionsButton: some View {
        Button(action: onQuickActions) {
            Image(systemName: "plus").font(.system(size: 20, weight: .semibold))
                .foregroundStyle(StrandPalette.onInk).frame(width: 44, height: 44)
                .background(StrandPalette.ink, in: Circle())
                .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Quick Actions")
    }
    private func tabButton(_ item: Item) -> some View {
        let active = selection == item.tag
        return Button {
            if active { onReselect(item.tag) }
            else {
                withAnimation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selection = item.tag }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: item.icon).font(.system(size: 18, weight: active ? .semibold : .regular))
                Text(item.title).font(StrandFont.micro.weight(active ? .semibold : .regular))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(active ? StrandPalette.ink : StrandPalette.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(item.title)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}
#endif
