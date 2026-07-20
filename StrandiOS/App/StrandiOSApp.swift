#if os(iOS)
import SwiftUI
import StrandDesign
import WhoopStore
import WhoopProtocol
import StrandAnalytics
import UserNotifications

/// iOS entry point. Unlike the macOS app (which adds a `MenuBarExtra` scene), iOS uses a single
/// `WindowGroup`; the glanceable menu-bar role is filled by the Home/Lock-Screen widget instead.
///
/// The iOS shell is `RootTabView` (a `TabView`), NOT the macOS `ContentView`. `ContentView` embeds
/// `RootView()` — the `NavigationSplitView` sidebar shell — and `RootView.swift` is excluded from the
/// iOS target in `project.yml` (the sidebar has no iPhone analogue), so `ContentView` cannot compile
/// on iOS. The first-run onboarding/pairing wizard, the Terms acknowledgment gate, and the post-update
/// "What's New" sheet that `ContentView` layers on are reproduced here as `iOSRootView`, wrapped around
/// `RootTabView` so the iOS app keeps the same gating without depending on the macOS-only shell.
@main
struct StrandiOSApp: App {
    @StateObject private var model: AppModel
    @StateObject private var health: HealthKitBridge
    /// The phone→watch link. Built + activated here so the watch app actually receives snapshots on a
    /// real device; without an owner that pushes it, the watch only ever shows placeholder data.
    @StateObject private var watch = WatchSessionBridge()
    /// Shared cross-screen navigation hook (e.g. Live → Devices). The iOS shell (`RootTabView`)
    /// observes it and presents the Devices manager.
    @StateObject private var router = NavRouter()
    @State private var liveActivity = LiveActivityController()
    @Environment(\.scenePhase) private var scenePhase
    /// Appearance preference (System/Light/Dark). Default follows the OS; the Settings picker writes it.
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    /// Chart data-colour style (Titanium / Classic throwback). Re-colours gauges + charts.
    @AppStorage(ChartStyle.storageKey) private var chartStyleRaw = ChartStyle.titanium.rawValue

    init() {
        #if DEBUG
        // DEBUG-only promo-screenshot harness: when launched with `--demo-hour <Int>`, pin Today to that
        // hour's day-cycle scene + a per-hour stat frame. No-op (active stays nil) when the arg is absent.
        // MUST live here, not in StrandApp.swift — that is the macOS @main and is excluded from the iOS
        // target, so the hook there never runs on iOS.
        DemoDayHarness.applyLaunchArgsIfNeeded()
        #endif
        // Debug-only canary: trips if the App Group entitlement is missing on this target before any
        // silent no-op (PendingIntents, WidgetSnapshot.publish, Live Activity) can mask the issue as
        // "the widget doesn't show anything yet." No-op in Release.
        WidgetSnapshot.assertGroupProvisioned()
        // #510: register the scheduled debug auto-export's BGTask handler BEFORE launch finishes — iOS
        // only delivers a background task whose identifier was registered at launch AND listed in the
        // target's BGTaskSchedulerPermittedIdentifiers (project.yml). Without this the overnight drop
        // never fires; the macOS timer, foreground catch-up, and "Run now" already work without it.
        ScheduledDebugExport.register()
        // Foreground presentation: without a delegate, iOS suppresses a notification's banner while the app
        // is open, so a user testing the wind-down reminder with NOOP foregrounded sees nothing. Register
        // before the first scene so any early-fired notification is presented.
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
        let strain: Double?
        let building: Bool
        switch workout.liveStrainState {
        case .building:
            strain = nil
            building = true
        case .scored(let storedValue):
            strain = StrainScale.displayValue(fromStored: storedValue)
            building = false
        }
        let samples = workout.samples
        let calories: Int?
        if samples.count >= 2 {
            let profile = UserProfile(weightKg: model.profile.weightKg, heightCm: model.profile.heightCm,
                                      age: Double(model.profile.age), sex: model.profile.sex)
            let estimate = Calories.estimateBoutCalories(
                samples, profile: profile, hrmax: Double(model.profile.hrMax), restingHR: nil).0
            calories = estimate > 0 ? Int(estimate.rounded()) : nil
        } else {
            calories = nil
        }
        let zones = HRZones.timeInZone(
            samples, zoneSet: HRZones.zones(maxHR: Double(model.profile.hrMax), source: "profile"))
        return WorkoutLiveActivityState(
            sport: workout.sport, startedAt: workout.start, strain: strain, strainBuilding: building,
            calories: calories, hrTrace: Array(samples.suffix(48).map(\.bpm)),
            zoneSeconds: zones.seconds.map { Int($0.rounded()) })
    }

    var body: some Scene {
        WindowGroup {
            iOSRootView()
                .contentSurfacePresentation(.flat)
                .background(StrandPalette.appCanvas.ignoresSafeArea())
                .environmentObject(model)
                .environmentObject(model.ble)   // #334: Today pull-to-sync reads BLEManager (no HR churn)
                .environmentObject(model.live)
                .environmentObject(model.repo)
                .environmentObject(model.profile)
                .environmentObject(model.behavior)
                .environmentObject(model.intelligence)
                .environmentObject(model.coach)
                .environmentObject(health)
                .environmentObject(router)
                .environmentObject(UpdateStore.shared)
                // v5 L3: the shared stress check-in nudge surface, so the Breathe screen's passive
                // card observes the SAME instance the central detector (AppModel.evaluateStress) posts to.
                .environment(\.stressNudgeCenter, model.stressNudgeCenter)
                .preferredColorScheme(AppearanceMode.resolve(appearanceRaw).colorScheme)
                .chartStyle(chartStyleRaw)
                // Dynamic Type now scales the prose/label roles (StrandFont). Cap the upper end so the
                // fixed-geometry tiles/gauges stay legible at the largest accessibility sizes rather than
                // clipping; the common Larger-Text range still scales fully.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .onReceive(model.live.$heartRate) { _ in
                    // #911: anchor the Live Activity on the SAME shared `Repository.widgetAnchor` the
                    // Home/Lock widget and the watch snapshot use, so this fourth surface can't drift to a
                    // different day at the rollover (it previously read `days.last(where: recovery != nil)`,
                    // which kept pointing at yesterday's scored row after Today had moved on).
                    let day = Repository.widgetAnchor(days: model.repo.days)
                    liveActivity.update(
                        bpm: model.live.connected ? (model.bpm ?? model.live.heartRate) : nil,
                        recovery: day?.recovery.map { Int($0.rounded()) },
                        connected: model.live.connected,
                        effort: day
                            .flatMap { model.repo.canonicalStrain(for: $0.day)?.storedValue }
                            .map { StrainScale.displayValue(fromStored: $0) },
                        workout: workoutActivityState
                    )
                }
                // End the Live Activity the moment the link drops, even if no further HR tick arrives.
                .onReceive(model.live.$connected) { isConnected in
                    // #911: same shared anchor as the heartRate site above, so the Live Activity, the
                    // widget, the watch and Today never disagree about which day they describe.
                    let day = Repository.widgetAnchor(days: model.repo.days)
                    liveActivity.update(
                        bpm: isConnected ? (model.bpm ?? model.live.heartRate) : nil,
                        recovery: day?.recovery.map { Int($0.rounded()) },
                        connected: isConnected,
                        effort: day
                            .flatMap { model.repo.canonicalStrain(for: $0.day)?.storedValue }
                            .map { StrainScale.displayValue(fromStored: $0) },
                        workout: workoutActivityState
                    )
                }
                .onReceive(model.$activeWorkout.dropFirst()) { _ in
                    let day = Repository.widgetAnchor(days: model.repo.days)
                    liveActivity.update(
                        bpm: model.live.connected ? (model.bpm ?? model.live.heartRate) : nil,
                        recovery: day?.recovery.map { Int($0.rounded()) },
                        connected: model.live.connected,
                        effort: day.flatMap { model.repo.canonicalStrain(for: $0.day)?.storedValue }
                            .map { StrainScale.displayValue(fromStored: $0) },
                        workout: workoutActivityState)
                    WidgetSnapshot.publishLive(from: model)
                }
                // #911/#759: republish the Home/Lock-Screen widget whenever the dashboard caches actually
                // change mid-session. The only other publish site is the scenePhase .active handler, so
                // during a long foreground session the widget froze at the last-foreground snapshot while
                // Today and the Live Activity kept updating. `refreshSeq` is diff-guarded (Repository.refresh
                // skips the bump when the merged caches are byte-identical) and refresh() assigns every cache
                // BEFORE bumping the seq, so this publish always reads fresh data. `dropFirst()` skips the
                // publisher's attach-time replay of the current value; the .active publish already covers
                // launch. BUDGET: this app runs with bluetooth-central, so the process is NOT suspended in
                // the background, and the 15-minute analyze tick + backfill-completion refreshes bump the
                // seq back there too, where WidgetKit reloads DO count against the daily budget. Hence the
                // foreground gate: publish only while .active (foreground-initiated reloads are budget
                // exempt); a background bump is covered by the widget's own 15-minute timeline policy and
                // by the .active republish on return.
                .onReceive(model.repo.$refreshSeq.dropFirst()) { _ in
                    guard scenePhase == .active else { return }
                    Task { await WidgetSnapshot.publish(from: model) }
                    // The watch rides the same active-only hook because the bridge now SELF-THROTTLES
                    // (30-minute spacing + headline-change dedup, both must pass, see WatchSessionBridge),
                    // so a refresh storm can't burn the ~50/day complication transfer budget.
                    Task { await watch.pushLatest(from: model) }
                }
                // Live V2 can advance without a full repository refresh. Propagate the same
                // canonical headline to every glance surface while the app is foregrounded.
                .onReceive(model.repo.$canonicalStrainByDay.dropFirst()) { _ in
                    guard scenePhase == .active else { return }
                    let day = Repository.widgetAnchor(days: model.repo.days)
                    liveActivity.update(
                        bpm: model.live.connected ? (model.bpm ?? model.live.heartRate) : nil,
                        recovery: day?.recovery.map { Int($0.rounded()) },
                        connected: model.live.connected,
                        effort: day
                            .flatMap { model.repo.canonicalStrain(for: $0.day)?.storedValue }
                            .map { StrainScale.displayValue(fromStored: $0) },
                        workout: workoutActivityState
                    )
                    WidgetSnapshot.publishLive(from: model)
                    Task { await watch.pushLatest(from: model) }
                }
                // #114: strap battery % and connection are LIVE (model.live), not repo-cache, so they never
                // bump refreshSeq — the widget's battery would otherwise never move while the app is open
                // (the "battery not updating" report). Republish on those too, foreground-gated. Both are
                // low-frequency (battery ~every 8 min; connection flips are rare), so no throttle is needed
                // and foreground-initiated reloads are budget-exempt. dropFirst() skips the attach replay.
                .onReceive(model.live.$batteryPct.dropFirst()) { _ in
                    guard scenePhase == .active else { return }
                    WidgetSnapshot.publishLive(from: model)
                }
                .onReceive(model.live.$connected.dropFirst()) { _ in
                    guard scenePhase == .active else { return }
                    WidgetSnapshot.publishLive(from: model)
                }
                // #114 (follow-up): `WidgetSnapshot.bpm` reads `model.bpm` (WidgetPublish.swift), the
                // smoothed live HR — same LIVE-not-repo-cache category as battery/connected above, so it
                // has the same gap: nothing bumped `refreshSeq` while a heart-rate stream was live, so the
                // widget's HR froze at the last foreground snapshot for the rest of the session. UNLIKE
                // battery/connection, HR is HIGH-frequency (the smoothed median moves every few seconds
                // under activity), so — unlike the ungated hooks above — this one is throttled through
                // `HRPublishThrottle` (60 s, mirroring Android's PushGate HR cadence) so it can't re-run
                // publish's `exploreSeries` read + `reloadAllTimelines()` on every tick.
                .onReceive(model.$bpm.dropFirst()) { _ in
                    guard scenePhase == .active else { return }
                    guard WidgetSnapshot.HRPublishThrottle.admit() else { return }
                    WidgetSnapshot.publishLive(from: model)
                }
                // #581: the `noop://import-health` deep link the iOS Shortcut opens after building the
                // HealthKit-free payload. Filter on the host so other future schemes don't trip the
                // importer; macOS never registers the scheme so this stays iOS-only.
                .onOpenURL { url in
                    if url.host == "import-health" {
                        model.handleHealthImportURL(url)
                    }
                }
                // Bring the watch link up once at launch (WCSession ignores a redundant activate), then
                // push the first snapshot so a watch that's already on-wrist gets current scores without
                // waiting for the next foreground. activate() is idempotent + a no-op where WC isn't
                // supported, so this is safe on every device/simulator combination.
                .task {
                    watch.activate()
                    await watch.pushLatest(from: model)
                    #if DEBUG
                    if CommandLine.arguments.contains("--component41-live-qa") {
                        await liveActivity.startComponent41QA()
                    }
                    #endif
                }
        }
        // HealthKit authorization is intentionally NOT requested on launch. The system permission
        // dialog without prior in-app rationale violates Apple HIG / App Review guidance — the user
        // sees the prompt before any context. It is requested from an explicit user action instead:
        // the "Enable Apple Health" affordance in AppleHealthView (More → Data → Apple Health).
        // Below, `refreshAuthIfPreviouslyGranted` re-primes `auth` for users who already granted
        // access (it only reads write/share status, never prompts) so background syncs resume; and
        // HealthKitBridge.sync guards on `auth == .authorized`, so the scenePhase trigger stays a
        // safe no-op until the user opts in.
        .onChange(of: scenePhase) { _, phase in
            model.setApplicationActive(phase == .active)
            if phase == .active {
                model.drainPendingIntents()
                // Re-arm the strap's smart alarm on foreground: the firmware alarm is a single instant
                // and iOS can't re-arm it while suspended, so it would otherwise fire once and stop.
                model.applySmartAlarm()
                // #267: pull a reasonably fresh sync on open rather than waiting for the 900s periodic
                // timer or an incidental reconnect. Floored at 90s and never clock/empty-streak-suppressed
                // (BackfillPolicy.shouldRun's .foreground case), so this is a safe no-op on rapid re-opens.
                model.ble.requestSync(.foreground)
                Task {
                    let trace = PerformanceTrace.begin("foreground_refresh")
                    defer { PerformanceTrace.end(trace) }
                    health.refreshAuthIfPreviouslyGranted()
                    await health.foregroundCatchUp()
                    await WidgetSnapshot.publish(from: model)
                    // Push the wrist on the SAME refresh as the Home-screen widget so the watch, the
                    // widget and Today never disagree about which day they describe. Without this the
                    // watch only ever holds placeholder data on a real device.
                    await watch.pushLatest(from: model)
                }
            } else if phase == .background {
                model.flushActiveWorkoutSnapshot()
                // #114: capture the LAST in-app live state on the way out so the Home widget matches what
                // the user just saw — its battery/HR/score otherwise lag to the last FOREGROUND refreshSeq
                // bump. One reload per app-exit is low-frequency and well within WidgetKit's daily budget.
                Task { await WidgetSnapshot.publish(from: model) }
                // #155: refresh the Documents/noop_sync.txt drop file the user's Siri Shortcut logs
                // into Apple Health. Gated inside writeIfEnabled on the opt-in default (OFF) — a
                // no-op until the user turns on Shortcuts Export.
                Task { await ShortcutHealthExport.writeIfEnabled(repo: model.repo) }
            }
        }
    }
}

/// iOS root — the `RootTabView` shell with the first-run onboarding/pairing wizard overlaid until
/// complete, the Terms acknowledgment gate over everything until the current version is accepted, and
/// a "What's New" changelog sheet shown automatically after an update.
///
/// This mirrors the macOS `ContentView` (same `@AppStorage` keys, same gate ordering) but swaps the
/// excluded `RootView()` sidebar for `RootTabView()`. The shared `OnboardingWizard`, `TermsGateView`,
/// `WhatsNewView`, `AppChangelog`, and `Terms` symbols all compile into the iOS target unchanged.
private struct iOSRootView: View {
    @AppStorage("noop.onboarded") private var onboarded = false
    @AppStorage("noop.lastSeenChangelogVersion") private var lastSeenChangelog = ""
    @AppStorage("noop.acceptedTermsVersion") private var acceptedTerms = ""
    @State private var showWhatsNew = false

    var body: some View {
        #if DEBUG
        // DEBUG-only: `--demo-screen <name>` renders one screen full-bleed (gates bypassed) so a
        // seeded simulator build can be screenshotted deterministically for verification + marketing.
        // No-op in Release (whole branch is #if DEBUG) and when the arg is absent.
        if let demo = DemoScreens.requested {
            // Inherit the app appearance (set via the Theme picker, or `-theme.appearance light|dark`
            // in the launch arguments) so demo/marketing shots can be taken in either scheme.
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
                    // A brand-new user just saw the expectations in onboarding — don't also pop the
                    // changelog at them; mark them current.
                    lastSeenChangelog = AppChangelog.currentVersion
                })
                .transition(.opacity)
                .zIndex(1)
            }
            // Terms acknowledgment gate — over EVERYTHING (before onboarding/pairing/Bluetooth) until
            // the current terms version is accepted; re-appears if the terms materially change.
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
        // The Terms gate must stay "over everything" — don't pop What's New on top of it after a
        // combined terms+version update. Gate on terms being current, and re-check when they're
        // accepted (onAppear already fired before acceptance), so What's New shows right after.
        .onAppear {
            showWhatsNewIfDue()
            // Seed the current What's New into the Updates inbox (idempotent per version) so the bell
            // collects it even if the user dismisses the auto sheet.
            UpdateStore.shared.seedWhatsNewIfNeeded()
        }
        .onChange(of: acceptedTerms) { _, _ in showWhatsNewIfDue() }
    }

    /// DEBUG: launched with --demo-seed, skip the first-run gates (onboarding / terms / What's New) so the
    /// FULL shell with the tab bar renders populated for verification + screenshots. No-op in Release.
    private var demoBypass: Bool {
        #if DEBUG
        return CommandLine.arguments.contains("--demo-seed")
        #else
        return false
        #endif
    }

    private func showWhatsNewIfDue() {
        if demoBypass { return }
        // Existing users who updated: their last-seen version is behind the current one.
        if onboarded && acceptedTerms == Terms.currentVersion
            && lastSeenChangelog != AppChangelog.currentVersion {
            showWhatsNew = true
        }
    }
}

#if DEBUG
/// DEBUG-only screenshot harness. Maps `--demo-screen <name>` to a single screen so a seeded
/// simulator build can be captured deterministically (verification + marketing). Stripped from Release.
enum DemoScreens {
    static let routeNames: [String] = [
        "today", "trends", "trendslastweek", "fullday", "sleep", "live", "stress", "workouts", "workoutdetail", "health", "atoms",
        "insights", "insightshub", "intelligence", "explore", "compare", "coach", "settings", "applehealth",
        "storage", "trendsreport", "fused", "scoringguide", "updates", "whatsnew", "hownoopworks", "xiaomi",
        "intervals", "hydration", "breathing", "manualworkout", "journal", "checkin", "behaviorsettings", "quickadd", "journalcard", "caffeinecard", "stresscheckin", "skintempcards", "autoworkoutcard", "mindsection", "hrvsnapshot", "watchsetup", "watchabout", "dashboardeditor",
        "keymetricseditor", "data", "backup", "support", "labbook", "automations",
        "alarms", "testcentre", "rhythmconsent", "rhythm", "liveworkout",
        "preworkout", "recoverydetail", "straindetail", "sleepdetail", "devices",
        "devicescatalog", "fitnessage", "fitnessagedetail", "vitality", "addwizard", "ouraonboarding",
        "ouradevice", "component41", "component41home", "component41large", "component41lock", "component41live", "onboarding",
    ]

    /// The screen named by `--demo-screen <name>`, or nil if the arg is absent/unknown.
    @MainActor
    static var requested: AnyView? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--demo-screen"), i + 1 < args.count else { return nil }
        return view(named: args[i + 1])
    }

    /// Pure route resolver used by both the launch harness and the iOS smoke test.
    @MainActor
    static func view(named name: String) -> AnyView? {
        if name.lowercased().hasPrefix("onboarding-") {
            let suffix = name.dropFirst("onboarding-".count)
            if let step = Int(suffix), (1...12).contains(step) {
                return AnyView(OnboardingWizard(onFinished: {}, initialStepIndex: step - 1))
            }
        }
        switch name.lowercased() {
        case "today":    return AnyView(TodayView())
        case "trends":   return AnyView(TrendsView())
        case "trendslastweek": return AnyView(TrendsView(initialWeekOffset: -1))
        case "fullday": return AnyView(FullDayChartView())
        case "sleep":    return AnyView(SleepView())
        case "live":     return AnyView(LiveView())
        case "stress":   return AnyView(StressView())
        case "workouts": return AnyView(WorkoutsView())
        case "workoutdetail": return AnyView(WorkoutDetailDemoHost())
        case "health":   return AnyView(HealthView())
        case "atoms":    return AnyView(DesignLabAtomGallery())
        case "component41": return AnyView(Component41QAGallery())
        case "component41home": return AnyView(Component41QAShot(kind: .home))
        case "component41large": return AnyView(Component41QAShot(kind: .large))
        case "component41lock": return AnyView(Component41QAShot(kind: .lock))
        case "component41live": return AnyView(Component41QAShot(kind: .live))
        case "insights": return AnyView(InsightsHubView())
        case "journal": return AnyView(CoachingRootView())
        case "checkin": return AnyView(NavigationStack { CoachingCheckInView() })
        case "behaviorsettings": return AnyView(NavigationStack { CoachingBehaviorSettingsView() })
        case "quickadd": return AnyView(NavigationStack { CoachingQuickAddView() })
        case "stackdetail": return AnyView(NavigationStack { CoachingStackDemoRoute() })
        case "insightshub": return AnyView(InsightsHubView())
        case "intelligence": return AnyView(IntelligenceView())
        case "explore":  return AnyView(MetricExplorerView())
        case "compare":  return AnyView(CompareView())
        case "coach":    return AnyView(CoachView())
        case "settings": return AnyView(SettingsView())
        case "applehealth": return AnyView(AppleHealthView())
        case "storage": return AnyView(StorageView())
        case "trendsreport": return AnyView(TrendsReportSheet(days: []))
        case "fused": return AnyView(FusedRecordView(record: cleanupAuditFusedRecord))
        case "scoringguide": return AnyView(ScoringGuideView(onClose: {}))
        case "updates": return AnyView(UpdatesInboxView(onClose: {}))
        case "whatsnew": return AnyView(WhatsNewView(onClose: {}))
        case "hownoopworks": return AnyView(HowNoopWorksView(onClose: {}))
        case "xiaomi": return AnyView(XiaomiBandView())
        case "intervals": return AnyView(IntervalTimerView())
        case "hydration": return AnyView(HydrationView())
        case "breathing": return AnyView(BreathingView())
        case "manualworkout": return AnyView(ManualWorkoutSheet { _, _ in })
        case "journalcard": return AnyView(JournalCardDemoHost())
        case "caffeinecard": return AnyView(CaffeineCardDemoHost())
        case "stresscheckin": return AnyView(StressCheckInDemoHost())
        case "skintempcards": return AnyView(SkinTempCardsDemoHost())
        case "autoworkoutcard": return AnyView(AutoWorkoutCardDemoHost())
        case "mindsection": return AnyView(MindSectionDemoHost())
        case "hrvsnapshot": return AnyView(HRVSnapshotView())
        case "watchsetup": return AnyView(AppleWatchSetupView(onClose: {}))
        case "watchabout": return AnyView(AppleWatchAboutView())
        case "dashboardeditor": return AnyView(DashboardCardsEditorSheet(selectionRaw: .constant("")))
        case "keymetricseditor": return AnyView(KeyMetricsEditorSheet(layoutRaw: .constant("")))
        case "data": return AnyView(DataSourcesView())
        case "backup": return AnyView(BackupSyncView())
        case "support": return AnyView(SupportView())
        case "labbook": return AnyView(LabBookView())
        case "automations": return AnyView(AutomationsView())
        case "alarms": return AnyView(SmartAlarmView())
        case "testcentre": return AnyView(TestCentreView())
        case "rhythmconsent": return AnyView(RhythmConsentGate(onAccept: {}))
        case "rhythm": return AnyView(RhythmEmptyDemoHost())
        case "liveworkout": return AnyView(LiveWorkoutDemoHost())
        case "preworkout": return AnyView(PreWorkoutDemoHost())
        // C10/T56: pillar deep links land on the canonical Paper details (same surface the
        // Today trio opens), not the generic trend explorer.
        case "recoverydetail": return AnyView(PaperPillarDetailView(
            kind: .charge, anchorDayKey: Repository.logicalDayKey(Date())
        ))
        case "straindetail": return AnyView(PaperPillarDetailView(
            kind: .effort, anchorDayKey: Repository.logicalDayKey(Date())
        ))
        case "sleepdetail": return AnyView(SleepView())
        case "devices":  return AnyView(DevicesView())
        case "devicescatalog": return AnyView(DeviceCardCatalog())
        case "fitnessage": return AnyView(FitnessAgeDemoScreen())
        case "fitnessagedetail": return AnyView(NavigationStack { FitnessAgeDetailView() })
        case "vitality": return AnyView(VitalityDemoScreen())
        case "addwizard": return AnyView(AddWizardDemoHost())
        // Oura onboarding: the Add-device wizard deep-linked straight to the Oura factory-reset-and-adopt
        // prep step (the Beta banner + get/lose card + the red irreversible-consent gate), screenshot-able
        // WITHOUT a ring.
        case "ouraonboarding": return AnyView(OuraOnboardingDemoHost())
        // Oura device card: the locally-adopted Oura ring card (Beta chip + per-gen honest capability copy
        // + battery + local-state note), rendered with mock data, no ring required.
        case "ouradevice": return AnyView(OuraDeviceDemoScreen())
        case "onboarding": return AnyView(OnboardingWizard(onFinished: {}))
        // The retired standalone bond-refusal demo no longer exists; keep the debug route useful by
        // landing on the canonical Devices surface where the live pairing guidance is rendered.
        case "bondrefused": return AnyView(DevicesView())
        default:         return nil
        }
    }

    /// DEBUG-only multi-source conflict fixture for the cleanup interaction audit.
    private static var cleanupAuditFusedRecord: FusedRecord {
        let contributors = [
            ContributingSource(source: .whoopImport, value: 58, tier: 0, sourcePriority: 0,
                               reason: "comes directly from the overnight record"),
            ContributingSource(source: .appleHealth, value: 71, tier: 1, sourcePriority: 0,
                               reason: "is the best available secondary source"),
        ]
        let point = FusedMetricPoint(metric: "resting_hr", value: 58, winningSource: .whoopImport,
                                     contributors: contributors, agreement: .conflict)
        return FusedRecord(rows: [FusedRow(point: point, label: "Resting HR")],
                           dayOwner: .whoopImport, contributingSourceCount: 2)
    }
}

/// Populated D15 pre-run proof. The route is written through the real `RouteStore` and
/// keyed to a real seeded workout; this fixture is DEBUG-only and stripped from Release.
private struct PreWorkoutDemoHost: View {
    @EnvironmentObject private var repo: Repository
    @State private var routeRevision = 0

    var body: some View {
        StartWorkoutSheet(initialSport: "Running", onStart: { _ in })
            .id(routeRevision)
            .task(id: repo.refreshSeq) {
                guard routeRevision == 0 else { return }
                let rows = await repo.workoutRows(days: 365)
                guard let row = rows.first(where: { ($0.distanceM ?? 0) > 0 }) else { return }
                if RouteStore.load(startTs: row.startTs, sport: row.sport) == nil {
                    let points = PaperRunDemoRoute.loop
                    RouteStore.store(
                        WorkoutRoute(polyline: RouteMath.encode(points),
                                     distanceM: RouteMath.totalMeters(points)),
                        startTs: row.startTs,
                        sport: row.sport)
                }
                routeRevision = 1
            }
    }

}

/// Populated D15 live-run proof. Production still receives every value from the live
/// sensor/GPS engines; this host exists only in DEBUG screenshot builds.
private struct LiveWorkoutDemoHost: View {
    @EnvironmentObject private var model: AppModel
    @State private var seeded = false

    var body: some View {
        LiveWorkoutView(onClose: {})
            .task {
                guard !seeded else { return }
                seeded = true
                // Let LiveWorkoutView arm realtime first (which clears stale smoothing), then
                // publish the deterministic populated state used by the screenshot gate.
                await Task.yield()
                let elapsed = 32.0 * 60.0 + 47.0
                let start = Date().addingTimeInterval(-elapsed)
                var samples = (0..<180).map { index -> HRSample in
                    let phase = Double(index)
                    let slowWave = 9.0 * sin(phase / 10.0)
                    let fastWave = 4.0 * sin(phase / 3.7)
                    let bpm = Int((143.0 + slowWave + fastWave).rounded())
                    return HRSample(ts: Int(start.timeIntervalSince1970) + index * 11, bpm: bpm)
                }
                samples[samples.count - 1] = HRSample(ts: Int(Date().timeIntervalSince1970), bpm: 152)
                var demoWorkout = AppModel.ActiveWorkout(
                    start: start, sport: "Running", maxHR: Double(model.profile.hrMax))
                demoWorkout.samples = samples
                demoWorkout.strainAccumulator = .init(
                    samples: samples, maxHR: Double(model.profile.hrMax))
                demoWorkout.liveStrainState = .scored(storedValue: 54.3)
                demoWorkout.avgHr = 144
                demoWorkout.peakHr = 171
                model.activeWorkout = demoWorkout
                model.bpm = 152
                model.live.sensorCadence = 168
                model.gpsRecorder.seedDemoRoute(points: PaperRunDemoRoute.liveRoute,
                                                elapsedSeconds: elapsed)
            }
    }
}

private enum PaperRunDemoRoute {
    static let loop: [RouteMath.LatLng] = [
        .init(40.80058, -73.97010), .init(40.80258, -73.97149),
        .init(40.80502, -73.97326), .init(40.80738, -73.97486),
        .init(40.80956, -73.97331), .init(40.80829, -73.97027),
        .init(40.80582, -73.96872), .init(40.80335, -73.96729),
        .init(40.80119, -73.96805), .init(40.80058, -73.97010),
    ]

    /// Roughly 6 km while keeping the map framed on the same honest loop.
    static let liveRoute = loop + Array(loop.dropFirst()) + Array(loop.dropFirst().prefix(6))
}
#endif
#endif

#if DEBUG
/// DEBUG-only host so `--demo-screen addwizard` can render the multi-step Add-a-device wizard.
/// A SwiftUI View body is main-actor, so it can pull the injected LiveState and hand it to the
/// wizard's `init(live:)` (the nonisolated DemoScreens switch can't construct a LiveState itself).
private struct AddWizardDemoHost: View {
    @EnvironmentObject var live: LiveState
    var body: some View { AddDeviceWizard(live: live, onClose: {}) }
}

/// DEBUG-only host so `--demo-screen ouraonboarding` renders the Add-device wizard deep-linked to the
/// Oura factory-reset-and-adopt prep step (the Beta banner + what-you-get/what-you-lose card + the red
/// irreversible-consent gate). A SwiftUI View body is main-actor, so it can pull the injected LiveState
/// and seed the wizard's `startAt` into the Oura prep step without a ring present.
private struct OuraOnboardingDemoHost: View {
    @EnvironmentObject var live: LiveState
    var body: some View {
        AddDeviceWizard(live: live, onClose: {}, startAt: (.oura, .prep))
    }
}
#endif


/// Screenshot-harness host for the tabbed workout summary (craft 003): loads the most
/// recent workout row and presents its detail directly — the sheet is otherwise only
/// reachable by tapping a Workouts row, which simctl can't script.
private struct WorkoutDetailDemoHost: View {
    @EnvironmentObject private var repo: Repository
    @State private var row: WorkoutRow?
    var body: some View {
        Group {
            if let row {
                WorkoutDetailView(row: row)
            } else {
                ProgressView().task {
                    row = await repo.workoutRows(days: 4000).first
                }
            }
        }
    }
}

#if DEBUG
private struct JournalCardDemoHost: View {
    @State private var dayOffset = 0
    var body: some View {
        ScrollView {
            JournalLogCard(importedQuestions: [], answers: [:], dayOffset: $dayOffset, onChanged: {})
                .padding(NoopMetrics.screenPadding)
        }
        .background(StrandPalette.surfaceBase)
    }
}

private struct CaffeineCardDemoHost: View {
    var body: some View {
        ScrollView {
            CaffeineLogCard().padding(NoopMetrics.screenPadding)
        }
        .background(StrandPalette.surfaceBase)
    }
}

@MainActor
private struct StressCheckInDemoHost: View {
    @StateObject private var center = StressNudgeCenter()
    var body: some View {
        ScrollView {
            StressCheckInCard(center: center, onBreatheNow: {})
                .padding(NoopMetrics.screenPadding)
        }
        .background(StrandPalette.surfaceBase)
        .task { center.present(fastRMSSD: 42, baselineRMSSD: 68) }
    }
}

private struct SkinTempCardsDemoHost: View {
    var body: some View {
        ScrollView {
            VStack(spacing: NoopMetrics.sectionGap) {
                CycleAwarenessCard(
                    result: .init(phase: .luteal, confidence: .solid,
                                  cycleDayLow: 20, cycleDayHigh: 24, cycleLengthDays: 28,
                                  nextPeriodWindow: .init(earliestDay: "2026-07-18", latestDay: "2026-07-22"),
                                  shiftMarkers: [], note: "Temperature is running above your baseline."),
                    curve: (0..<40).map { 0.1 * sin(Double($0) / 8) + 0.04 },
                    onLogPeriod: {}, onOpenDetail: {})
                HeadsUpCard(result: .init(
                    score: 64, level: .raised,
                    firedSignals: ["RHR +6", "HRV −22%", "skin temp +0.7 °C"],
                    suppressedBy: [], signalCount: 3,
                    copy: "Heads-up — your body looks strained. On-device estimate — not a diagnosis."))
            }
            .padding(NoopMetrics.screenPadding)
        }
        .background(StrandPalette.surfaceBase)
    }
}

private struct AutoWorkoutCardDemoHost: View {
    var body: some View {
        ScrollView {
            AutoWorkoutCard(demoCandidate: DetectedWorkout(
                startSec: Int(Date().addingTimeInterval(-42 * 60).timeIntervalSince1970),
                endSec: Int(Date().addingTimeInterval(-15 * 60).timeIntervalSince1970),
                avgBpm: 148,
                peakBpm: 171,
                durationMin: 27
            ))
            .padding(NoopMetrics.screenPadding)
        }
        .background(StrandPalette.surfaceBase)
        .onAppear { UserDefaults.standard.set(true, forKey: PuffinExperiment.autoDetectWorkoutsKey) }
    }
}

private struct MindSectionDemoHost: View {
    var body: some View {
        ScrollView {
            MindSection().padding(NoopMetrics.screenPadding)
        }
        .background(StrandPalette.surfaceBase)
    }
}
#endif
