#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics
import UserNotifications

@main
struct StrandiOSApp: App {
    @StateObject private var model: AppModel
    @StateObject private var health: HealthKitBridge
    @StateObject private var router = NavRouter()
    @State private var liveActivity = LiveActivityController()
    @State private var workoutProjection = WorkoutLiveProjectionCache()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage(ChartStyle.storageKey) private var chartStyleRaw = ChartStyle.titanium.rawValue

    init() {
        #if DEBUG
        DemoDayHarness.applyLaunchArgsIfNeeded()
        #endif
        WidgetSnapshot.assertGroupProvisioned()
        ScheduledDebugExport.register()
        SmartAlarmScheduler.register()
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        _health = StateObject(wrappedValue: HealthKitBridge(
            repo: model.repo,
            appleDeviceId: model.appleDeviceId,
            noopDeviceId: model.deviceId
        ))
    }

    private var workoutActivityState: WorkoutLiveActivityState? {
        guard let workout = model.activeWorkout else { return nil }
        return workoutProjection.state(workout: workout, profile: model.profile)
    }

    private func driveLiveActivity(connected: Bool? = nil) {
        let isConnected = connected ?? model.live.connected
        let day = Repository.widgetAnchor(days: model.repo.days)
        liveActivity.update(
            bpm: isConnected ? (model.bpm ?? model.live.heartRate) : nil,
            recovery: day?.recovery.map { Int($0.rounded()) },
            connected: isConnected,
            effort: day
                .flatMap { model.repo.canonicalStrain(for: $0.day)?.storedValue }
                .map { StrainScale.displayValue(fromStored: $0) },
            workoutIsActive: model.activeWorkout != nil,
            workout: workoutActivityState
        )
    }

    var body: some Scene {
        WindowGroup {
            iOSRootView()
                .contentSurfacePresentation(.flat)
                .background(StrandPalette.appCanvas.ignoresSafeArea())
                .environmentObject(model)
                .environmentObject(model.ble)
                .environmentObject(model.live)
                .environmentObject(model.repo)
                .environmentObject(model.profile)
                .environmentObject(model.behavior)
                .environmentObject(model.intelligence)
                .environmentObject(model.coach)
                .environmentObject(health)
                .environmentObject(router)
                .environmentObject(UpdateStore.shared)
                .environment(\.stressNudgeCenter, model.stressNudgeCenter)
                .preferredColorScheme(AppearanceMode.resolve(appearanceRaw).colorScheme)
                .chartStyle(chartStyleRaw)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .onReceive(model.live.$heartRate) { _ in driveLiveActivity() }
                .onReceive(model.live.$connected) { driveLiveActivity(connected: $0) }
                .onReceive(model.$activeWorkout.dropFirst()) { workout in
                    if workout == nil { workoutProjection.reset() }
                    driveLiveActivity()
                    WidgetSnapshot.publishLive(from: model)
                }
                .onReceive(model.repo.$refreshSeq.dropFirst()) { _ in
                    guard scenePhase == .active else { return }
                    Task { await WidgetSnapshot.publish(from: model) }
                }
                .onReceive(model.repo.$canonicalStrainByDay.dropFirst()) { _ in
                    guard scenePhase == .active else { return }
                    driveLiveActivity()
                    WidgetSnapshot.publishLive(from: model)
                }
                .onReceive(model.live.$batteryPct.dropFirst()) { _ in
                    guard scenePhase == .active else { return }
                    WidgetSnapshot.publishLive(from: model)
                }
                .onReceive(model.live.$connected.dropFirst()) { _ in
                    guard scenePhase == .active else { return }
                    WidgetSnapshot.publishLive(from: model)
                }
                .onReceive(model.$bpm.dropFirst()) { _ in
                    guard scenePhase == .active else { return }
                    guard WidgetSnapshot.HRPublishThrottle.admit() else { return }
                    WidgetSnapshot.publishLive(from: model)
                }
                .onOpenURL { url in
                    if url.host == "import-health" { model.handleHealthImportURL(url) }
                }
                .task {
                    #if DEBUG
                    if CommandLine.arguments.contains("--component41-live-qa") {
                        await liveActivity.startComponent41QA()
                    }
                    #endif
                }
        }
        .onChange(of: scenePhase) { _, phase in
            model.setApplicationActiveOptimized(phase == .active)
            if phase == .active {
                model.drainPendingIntents()
                model.applySmartAlarm()
                model.ble.requestSync(.foreground)
                Task {
                    let trace = PerformanceTrace.begin("foreground_refresh")
                    defer { PerformanceTrace.end(trace) }
                    health.refreshAuthIfPreviouslyGranted()
                    await health.foregroundCatchUp()
                    await WidgetSnapshot.publish(from: model)
                }
            } else if phase == .background {
                Task { await WidgetSnapshot.publish(from: model) }
                Task { await ShortcutHealthExport.writeIfEnabled(repo: model.repo) }
            }
        }
    }
}

private struct iOSRootView: View {
    @AppStorage("noop.onboarded") private var onboarded = false
    @AppStorage("noop.lastSeenChangelogVersion") private var lastSeenChangelog = ""
    @AppStorage("noop.acceptedTermsVersion") private var acceptedTerms = ""
    @State private var showWhatsNew = false

    var body: some View {
        #if DEBUG
        if let demo = DemoScreens.requested {
            return AnyView(
                NavigationStack {
                    demo
                        .background(StrandPalette.appCanvas.ignoresSafeArea())
                        .navigationBarTitleDisplayMode(.inline)
                }
            )
        }
        #endif
        return AnyView(shell)
    }

    private var shell: some View {
        ZStack {
            RootTabView()
            if !onboarded && !demoBypass {
                OnboardingWizard(onFinished: {
                    onboarded = true
                    lastSeenChangelog = AppChangelog.currentVersion
                })
                .transition(.opacity)
                .zIndex(1)
            }
            if acceptedTerms != Terms.currentVersion && !demoBypass {
                TermsGateView(onAccept: { acceptedTerms = Terms.currentVersion })
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: onboarded)
        .animation(.easeInOut(duration: 0.35), value: acceptedTerms)
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView(onClose: {
                lastSeenChangelog = AppChangelog.currentVersion
                showWhatsNew = false
            })
        }
        .onAppear {
            showWhatsNewIfDue()
            UpdateStore.shared.seedWhatsNewIfNeeded()
        }
        .onChange(of: acceptedTerms) { _, _ in showWhatsNewIfDue() }
    }

    private var demoBypass: Bool {
        #if DEBUG
        return CommandLine.arguments.contains("--demo-seed")
        #else
        return false
        #endif
    }

    private func showWhatsNewIfDue() {
        if demoBypass { return }
        if onboarded && acceptedTerms == Terms.currentVersion
            && lastSeenChangelog != AppChangelog.currentVersion
        {
            showWhatsNew = true
        }
    }
}
#endif
