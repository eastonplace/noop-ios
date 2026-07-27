#if os(iOS)
import SwiftUI
import Combine
import StrandDesign
import StrandAnalytics
import UserNotifications

/// A manual workout republishes the same reference after every accepted HR sample. External surfaces need
/// immediate start/end transitions, not another lifecycle callback for every mutation of that same session.
enum WorkoutLifecycleProjection {
    static func identity(_ workout: AppModel.ActiveWorkout?) -> ObjectIdentifier? {
        workout.map(ObjectIdentifier.init)
    }
}

/// Repository-backed fields needed by widgets/Live Activity. Rebuilt only when repository state changes
/// (or the logical day rolls), never on a raw heart-rate callback.
struct ExternalSurfaceDayProjection: Equatable {
    let logicalDayKey: String
    let recovery: Int?
    let effort: Double?

    static func recoveryValue(_ value: Double?) -> Int? {
        guard let value, value.isFinite, (0...100).contains(value) else { return nil }
        // A bounds comparison against Double(Int.max) is insufficient on 64-bit platforms because
        // Double(Int.max) rounds to 2^63. Exact conversion is the only non-trapping representability gate.
        return Int(exactly: value.rounded())
    }

    static func effortValue(_ storedValue: Double?) -> Double? {
        guard let storedValue, storedValue.isFinite else { return nil }
        let display = StrainScale.displayValue(fromStored: storedValue)
        return display.isFinite ? display : nil
    }

    @MainActor
    static func make(repository: Repository, now: Date = Date()) -> Self {
        let day = Repository.widgetAnchor(days: repository.days, now: now)
        return Self(
            logicalDayKey: Repository.logicalDayKey(now),
            recovery: recoveryValue(day?.recovery),
            effort: effortValue(day.flatMap { repository.canonicalStrain(for: $0.day)?.storedValue })
        )
    }
}

@main
struct StrandiOSApp: App {
    @StateObject private var model: AppModel
    @StateObject private var health: HealthKitBridge
    @StateObject private var alarmMode: SmartAlarmAdaptiveModeStore
    @StateObject private var alarmRuntime: SmartAlarmRuntimeController
    @StateObject private var router = NavRouter()
    @State private var liveActivity = LiveActivityController()
    @State private var workoutProjection = WorkoutLiveProjectionCache()
    @State private var externalSurfaceDay = ExternalSurfaceDayProjection(
        logicalDayKey: "", recovery: nil, effort: nil
    )
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage(ChartStyle.storageKey) private var chartStyleRaw = ChartStyle.titanium.rawValue

    init() {
        #if DEBUG
        DemoDayHarness.applyLaunchArgsIfNeeded()
        #endif
        WidgetSnapshot.assertGroupProvisioned()
        ScheduledDebugExport.register()
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
        let model = AppModel()
        let alarmMode = SmartAlarmAdaptiveModeStore(legacy: model.behavior)
        let alarmRuntime = SmartAlarmRuntimeController(model: model, modeStore: alarmMode)
        SmartAlarmBackgroundTaskRegistrar.install(alarmRuntime)
        _model = StateObject(wrappedValue: model)
        _alarmMode = StateObject(wrappedValue: alarmMode)
        _alarmRuntime = StateObject(wrappedValue: alarmRuntime)
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
        if externalSurfaceDay.logicalDayKey != Repository.logicalDayKey(Date()) {
            refreshExternalSurfaceDay()
        }
        let isConnected = connected ?? model.live.connected
        liveActivity.update(
            bpm: isConnected ? (model.bpm ?? model.live.heartRate) : nil,
            recovery: externalSurfaceDay.recovery,
            connected: isConnected,
            effort: externalSurfaceDay.effort,
            workoutIsActive: model.activeWorkout != nil,
            workout: workoutActivityState
        )
    }

    private func refreshExternalSurfaceDay() {
        externalSurfaceDay = ExternalSurfaceDayProjection.make(repository: model.repo)
    }

    /// A HealthKit sync is not complete for product surfaces when SQLite alone has changed. Score the exact
    /// committed civil-day window through the same serialized IntelligenceEngine admission used by strap
    /// backfill, publish one Repository generation that includes both imported inputs and derived Recovery,
    /// then update every external surface even if the app is backgrounded.
    @MainActor
    private func publishCommittedHealthWindow(_ window: HealthKitSyncWindow) async {
        let range = HealthKitAnalysisRange(window: window)
        await model.intelligence.analyzeRecent(
            maxDays: range.maxDays,
            startOffset: range.startOffset,
            refreshRepository: false)
        _ = await model.repo.refresh(.recentDashboard(days: range.publicationDays))
        refreshExternalSurfaceDay()
        driveLiveActivity()
        await WidgetSnapshot.publish(from: model)
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
                .environmentObject(alarmMode)
                .environmentObject(alarmRuntime)
                .environmentObject(model.intelligence)
                .environmentObject(model.coach)
                .environmentObject(health)
                .environmentObject(router)
                .environmentObject(UpdateStore.shared)
                .environment(\.stressNudgeCenter, model.stressNudgeCenter)
                .preferredColorScheme(AppearanceMode.resolve(appearanceRaw).colorScheme)
                .chartStyle(chartStyleRaw)
                .onReceive(model.live.$heartRate) { _ in driveLiveActivity() }
                .onReceive(model.live.$connected) { driveLiveActivity(connected: $0) }
                .onReceive(model.live.$connectSettled.removeDuplicates().dropFirst()) { settled in
                    guard settled != 0 else { return }
                    Task { await model.correctSeededWhoopModelIfNeeded() }
                }
                .onReceive(
                    model.$activeWorkout
                        .map(WorkoutLifecycleProjection.identity)
                        .removeDuplicates()
                        .dropFirst()
                ) { identity in
                    if identity == nil { workoutProjection.reset() }
                    driveLiveActivity()
                    WidgetSnapshot.publishLive(from: model)
                }
                .onReceive(model.repo.$refreshSeq.dropFirst()) { _ in
                    guard scenePhase == .active else { return }
                    refreshExternalSurfaceDay()
                    Task { await WidgetSnapshot.publish(from: model) }
                }
                .onReceive(TodayDayBoundaryScheduler.shared.$presentationGeneration.dropFirst()) { _ in
                    guard scenePhase == .active else { return }
                    // The midnight/04:00 transition can be purely temporal: no store
                    // row needs to change for the Home, widget, and Live Activity day
                    // labels to become stale. Publish from the same boundary source
                    // that invalidated Today instead of waiting for the next sync.
                    refreshExternalSurfaceDay()
                    driveLiveActivity()
                    Task { await WidgetSnapshot.publish(from: model) }
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: HealthKitSyncPublication.name)
                ) { notification in
                    guard let window = HealthKitSyncPublication.window(from: notification) else { return }
                    Task { @MainActor in
                        await publishCommittedHealthWindow(window)
                    }
                }
                .onReceive(model.repo.$canonicalStrainByDay.dropFirst()) { _ in
                    guard scenePhase == .active else { return }
                    refreshExternalSurfaceDay()
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
                    // SwiftUI does not guarantee an initial scenePhase onChange edge. Arm the clock owner on
                    // first mount so a continuously-foregrounded fresh launch still invalidates at midnight
                    // and 04:00. Scene changes continue to re-arm it through the lifecycle bridge below.
                    TodayDayBoundaryScheduler.shared.setActive(
                        scenePhase == .active,
                        repository: model.repo)
                    refreshExternalSurfaceDay()
                    alarmRuntime.start()
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
                alarmRuntime.handleForeground()
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
        shell
    }

    private var shell: some View {
        ZStack {
            RootTabView()
            if !onboarded {
                OnboardingWizard(onFinished: {
                    onboarded = true
                    lastSeenChangelog = AppChangelog.currentVersion
                })
                .transition(.opacity)
                .zIndex(1)
            }
            if acceptedTerms != Terms.currentVersion {
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

    private func showWhatsNewIfDue() {
        if onboarded && acceptedTerms == Terms.currentVersion
            && lastSeenChangelog != AppChangelog.currentVersion
        {
            showWhatsNew = true
        }
    }
}
#endif
