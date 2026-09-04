#if os(iOS)
import SwiftUI
import Combine
import NoopPhase34Core
import StrandDesign
import StrandAnalytics
import WhoopStore
import UserNotifications

/// A manual workout republishes the same reference after every accepted HR sample. External surfaces need
/// immediate start/end transitions, not another lifecycle callback for every mutation of that same session.
enum WorkoutLifecycleProjection {
    static func identity(_ workout: AppModel.ActiveWorkout?) -> ObjectIdentifier? {
        workout.map(ObjectIdentifier.init)
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
    @State private var externalSurface: ExternalSurfaceProjection?
    @State private var externalPublicationWorker: ExternalPublicationWorker
    private let sourcePrivacyCleanupCoordinator: SourcePrivacyCleanupCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage(ChartStyle.storageKey) private var chartStyleRaw = ChartStyle.titanium.rawValue

    @MainActor
    init() {
        #if DEBUG
        DemoDayHarness.applyLaunchArgsIfNeeded()
        #endif
        WidgetSnapshot.assertGroupProvisioned()
        ScheduledDebugExport.register()
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared

        // Restore the durable HealthKit scoring journal and close the Repository publication fence BEFORE
        // AppModel schedules launch's initial refresh. Otherwise a process killed after HealthKit import could
        // relaunch, publish the imported HRV/RHR immediately, and only calculate its Recovery moments later.
        _ = HealthKitScoringCoordinator.shared

        let model = AppModel()
        let alarmMode = SmartAlarmAdaptiveModeStore(legacy: model.behavior)
        let alarmRuntime = SmartAlarmRuntimeController(model: model, modeStore: alarmMode)
        SmartAlarmBackgroundTaskRegistrar.install(alarmRuntime)
        _model = StateObject(wrappedValue: model)
        _alarmMode = StateObject(wrappedValue: alarmMode)
        _alarmRuntime = StateObject(wrappedValue: alarmRuntime)
        let workoutProjectionCache = WorkoutLiveProjectionCache()
        _workoutProjection = State(initialValue: workoutProjectionCache)
        let healthBridge = HealthKitBridge(
            repo: model.repo,
            appleDeviceId: model.appleDeviceId,
            noopDeviceId: model.deviceId
        )
        let cleanupCoordinator = SourcePrivacyCleanupCoordinator(
            storeProvider: { [repo = model.repo] in
                await repo.storeHandle()
            },
            healthKitBridge: healthBridge
        )
        sourcePrivacyCleanupCoordinator = cleanupCoordinator
        _ = SourcePrivacyCleanupBackgroundTaskRegistrar.install(
            recover: { [weak model, weak healthBridge, cleanupCoordinator] in
                // BG execution may resume a process with a fresh `.unknown` bridge. Read the existing
                // grant first, but never request new permissions while the app is backgrounded.
                await healthBridge?.refreshAuthIfPreviouslyGranted(requestNewTypes: false)
                await model?.recoverPendingSourceTransition()
                guard let model,
                      let store = await model.repo.storeHandle() else {
                    return
                }
                do {
                    let latestTransition = try await store.latestSourceTransitionRecovery()
                    guard SourcePrivacyCleanupIndependentDrainPolicy.shouldDrain(
                        latestTransition: latestTransition
                    ) else { return }
                    _ = try await cleanupCoordinator.drainOldestUnresolved()
                } catch let error as SourcePrivacyCleanupCoordinatorError {
                    SourcePrivacyCleanupBackgroundTaskRegistrar.scheduleRetry(
                        for: error
                    )
                } catch {
                    SourcePrivacyCleanupBackgroundTaskRegistrar.schedule(.ready)
                }
            },
            pendingState: { [repo = model.repo] in
                guard let store = await repo.storeHandle() else {
                    throw SourcePrivacyCleanupCoordinatorError.storeUnavailable
                }
                let now = Date()
                let candidates = try await store.sourcePrivacyCleanupDrainCandidates(
                    now: now,
                    limit: 100
                )
                return SourcePrivacyCleanupBackgroundState.pendingState(
                    for: candidates.first,
                    now: now
                )
            }
        )
        model.attachSourcePrivacyCleanupDrain { [cleanupCoordinator] cleanupWorkId in
            do {
                try await cleanupCoordinator.drain(cleanupWorkId: cleanupWorkId)
            } catch let error as SourcePrivacyCleanupCoordinatorError {
                await MainActor.run {
                    SourcePrivacyCleanupBackgroundTaskRegistrar.scheduleRetry(for: error)
                }
                if SourcePrivacyCleanupTransitionHandoffPolicy.completesTransition(
                    after: error
                ) {
                    return
                }
                throw error
            }
        }
        let liveActivityController = LiveActivityController()
        let sinkLifecycle = IOSVerifiedSinkLifecycle(liveActivity: liveActivityController)
        model.attachVerifiedSinkLifecycle(sinkLifecycle)
        let worker = ExternalPublicationWorker(
            dependencies: ExternalPublicationWorkerDependencies(
                leaseNext: { owner, now, leaseDuration, preferredDestination in
                    guard let store = await model.repo.storeHandle() else {
                        throw HistoricalPipelineRuntimeError.storeUnavailable
                    }
                    return try await store.leaseNextExternalPublication(
                        owner: owner,
                        now: now,
                        leaseDuration: leaseDuration,
                        preferredDestination: preferredDestination)
                },
                applyEvent: { key, event, now in
                    guard let store = await model.repo.storeHandle() else {
                        throw HistoricalPipelineRuntimeError.storeUnavailable
                    }
                    return try await store.applyExternalPublicationEvent(
                        idempotencyKey: key, event: event, now: now)
                },
                loadBundle: { contextId, generation in
                    guard let store = await model.repo.storeHandle() else {
                        throw HistoricalPipelineRuntimeError.storeUnavailable
                    }
                    return try await store.verifiedExternalProjectionBundle(
                        contextId: contextId, generation: generation)
                },
                publishWidget: { bundle in
                    guard let expected = model.repo.activeVerifiedSinkContextId else {
                        return .superseded
                    }
                    return try await WidgetSnapshot.publish(
                        from: model,
                        verifiedBundle: bundle,
                        expectedActiveContextId: expected)
                },
                publishLiveActivity: { bundle in
                    let projection = bundle.projection
                    let surface = ExternalSurfaceProjection(projection)
                    guard let expected = model.repo.activeVerifiedSinkContextId else {
                        return .superseded
                    }
                    return try await liveActivityController.publishVerified(
                        projection: projection,
                        expectedActiveContextId: expected,
                        bpm: model.bpm ?? model.live.heartRate,
                        recovery: surface.recovery,
                        connected: model.live.connected,
                        effort: surface.effort,
                        workoutIsActive: model.activeWorkout != nil,
                        workoutProjection: {
                            model.activeWorkout.map {
                                workoutProjectionCache.state(workout: $0, profile: model.profile)
                            }
                        }
                    )
                },
                publishHealthKitWriteOnly: { payload in
                    guard let store = await model.repo.storeHandle() else {
                        throw HistoricalPipelineRuntimeError.storeUnavailable
                    }
                    let eligible = try await store.eligibleHealthKitMutationDaysBatched(
                        contextId: payload.contextId,
                        deviceId: payload.deviceId,
                        days: payload.changedDays,
                        analysisGeneration: payload.analysisGeneration
                    )
                    guard let restricted = try payload.restricted(to: eligible) else {
                        return .superseded
                    }
                    try await healthBridge.publishExactHealthKit(payload: restricted)
                    try await store.recordHealthKitMutationDeliveryIdentitySafe(
                        contextId: payload.contextId,
                        deviceId: payload.deviceId,
                        days: restricted.changedDays,
                        analysisGeneration: restricted.analysisGeneration,
                        now: Date()
                    )
                    return .published
                },
                publishWatch: { _ in
                    // project.yml has no watchOS target. This row is intentionally
                    // non-applicable, not a fake write.
                    return .notApplicable
                },
                classifyError: { error in
                    if let error = error as? ExactPublicationError {
                        switch error {
                        case .authorizationUnavailable:
                            return PipelineFailureClassification(
                                code: "authorization_unavailable", disposition: .blocked)
                        case .storeUnavailable:
                            return PipelineFailureClassification(
                                code: "store_unavailable", disposition: .retryable)
                        case .invalidTimeZone:
                            return PipelineFailureClassification(
                                code: "invalid_time_zone", disposition: .permanent)
                        }
                    }
                    if error is WidgetPublicationError {
                        return PipelineFailureClassification(code: "widget_sink_write_failed", disposition: .retryable)
                    }
                    if error is LiveActivityPublicationError {
                        return PipelineFailureClassification(code: "live_activity_sink_failed", disposition: .retryable)
                    }
                    if let error = error as? ExternalPublicationWorkerError {
                        switch error {
                        case .destinationUnavailable, .payloadMissingOrMismatched:
                            return PipelineFailureClassification(
                                code: String(describing: error),
                                disposition: .permanent
                            )
                        case .bundleMissing, .projectionMismatch, .leaseRenewalFailed:
                            return PipelineFailureClassification(
                                code: String(describing: error),
                                disposition: .retryable
                            )
                        }
                    }
                    return PipelineFailureClassification(
                        code: String(describing: error),
                        disposition: .retryable
                    )
                },
                pruneCompleted: {
                    guard let store = await model.repo.storeHandle() else {
                        throw HistoricalPipelineRuntimeError.storeUnavailable
                    }
                    _ = try await store.pruneCompletedVerifiedProjections()
                },
                report: { message in
                    NSLog("NOOP external publication: %@", message)
                },
                now: Date.init
            )
        )
        model.attachExternalPublicationWorker(worker)
        _liveActivity = State(initialValue: liveActivityController)
        _health = StateObject(wrappedValue: healthBridge)
        _externalPublicationWorker = State(initialValue: worker)
    }

    private var workoutActivityState: WorkoutLiveActivityState? {
        guard let workout = model.activeWorkout else { return nil }
        return workoutProjection.state(workout: workout, profile: model.profile)
    }

    private func driveLiveActivity(connected: Bool? = nil) {
        let isConnected = connected ?? model.live.connected
        liveActivity.update(
            bpm: isConnected ? (model.bpm ?? model.live.heartRate) : nil,
            recovery: externalSurface?.recovery,
            connected: isConnected,
            effort: externalSurface?.effort,
            verifiedContextId: externalSurface?.contextId,
            verifiedProjectionGeneration: externalSurface?.generation,
            workoutIsActive: model.activeWorkout != nil,
            workout: workoutActivityState
        )
    }

    private func refreshExternalSurface() {
        externalSurface = model.repo.verifiedHealthProjection.map(ExternalSurfaceProjection.init)
    }

    @MainActor
    private func schedulePrivacyCleanupIfPending() async {
        guard let store = await model.repo.storeHandle(),
              let candidates = try? await store.sourcePrivacyCleanupDrainCandidates(
                  now: Date(),
                  limit: 100
              ) else { return }
        let now = Date()
        let state = SourcePrivacyCleanupBackgroundState.pendingState(
            for: candidates.first,
            now: now
        )
        SourcePrivacyCleanupBackgroundTaskRegistrar.schedule(state, now: now)
    }

    @MainActor
    private func drainOldestSourcePrivacyCleanup() async {
        do {
            guard let store = await model.repo.storeHandle() else { return }
            let latestTransition = try await store.latestSourceTransitionRecovery()
            guard SourcePrivacyCleanupIndependentDrainPolicy.shouldDrain(
                latestTransition: latestTransition
            ) else { return }
            _ = try await sourcePrivacyCleanupCoordinator.drainOldestUnresolved()
        } catch let error as SourcePrivacyCleanupCoordinatorError {
            SourcePrivacyCleanupBackgroundTaskRegistrar.scheduleRetry(for: error)
        } catch {
            SourcePrivacyCleanupBackgroundTaskRegistrar.schedule(.ready)
        }
    }

    @MainActor
    private func resumeBlockedWork(includeHealthKit: Bool) async {
        guard let store = await model.repo.storeHandle() else { return }
        _ = try? await store.resumeEnvironmentalBlockedHistoricalAnalysisWork(now: Date())
        _ = try? await store.resumeEnvironmentalBlockedExternalPublications(
            destinations: [.widget, .liveActivity],
            now: Date()
        )
        if includeHealthKit, health.auth == .authorized {
            _ = try? await store.resumeEnvironmentalBlockedExternalPublications(
                destinations: [.healthKit],
                now: Date()
            )
        }
        await model.resumeEnvironmentalBlockedHistoricalWorkAndDrain()
    }

    /// Drain the crash-safe HealthKit → Intelligence handoff. The scoring coordinator retains the widest
    /// committed window until its exact analysis completes, every newly calculated Recovery is verified in
    /// durable storage, and Repository/Home/widgets publish while the HealthKit import lease and Repository
    /// fence exclude every newer writer or unrelated refresh.
    @MainActor
    private func drainCommittedHealthScoring() async {
        await HealthKitScoringCoordinator.shared.runAndWait(
            analyze: { window in
                let range = HealthKitAnalysisRange(window: window)
                return await model.intelligence.analyzeRecentForPublication(
                    maxDays: range.maxDays,
                    startOffset: range.startOffset,
                    refreshRepository: false,
                    verifyDurableRecovery: { results in
                        await IntelligenceRecoveryPersistenceReceipt.verify(
                            results: results,
                            reconciledDays: range.reconciledDays(),
                            repository: model.repo).complete
                    })
            },
            publish: { window in
                // The scoring coordinator is the exclusive publication owner here. Call the underlying coherent
                // refresh directly: routing through the normal typed queue would correctly defer behind this
                // same fence and deadlock its owner. Every non-owner publisher remains fenced and replayed.
                // The exact HealthKit analysis above owns the historical changed-day set. This narrow refresh
                // only hydrates the current-day snapshot; it never widens historical publication to 120 days.
                guard await model.repo.refresh(days: 1) else { return false }
                refreshExternalSurface()
                driveLiveActivity()
                _ = await WidgetSnapshot.publish(from: model)
                await externalPublicationWorker.signal()
                return true
            })
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if let component41Shot = Component41QAShot.requestedKind {
                    Component41QAShot(kind: component41Shot)
                } else if AppleDemoSeeder.devicesQARequested {
                    NavigationStack { DevicesView() }
                } else if CommandLine.arguments.contains("--storage-recovery-qa") {
                    StorageView()
                } else {
                    iOSRootView()
                }
                #else
                iOSRootView()
                #endif
            }
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
                    refreshExternalSurface()
                    Task { await WidgetSnapshot.publish(from: model) }
                }
                .onReceive(TodayDayBoundaryScheduler.shared.$presentationGeneration.dropFirst()) { _ in
                    guard scenePhase == .active else { return }
                    // The midnight/04:00 transition can be purely temporal: no store row needs to change for
                    // Home, widget, and Live Activity day labels to become stale. Publish from the same boundary
                    // source that invalidated Today instead of waiting for the next sync.
                    refreshExternalSurface()
                    driveLiveActivity()
                    Task { await WidgetSnapshot.publish(from: model) }
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: HealthKitSyncPublication.name,
                        object: HealthKitScoringCoordinator.shared)
                ) { _ in
                    Task { @MainActor in
                        await drainCommittedHealthScoring()
                    }
                }
                .onReceive(model.repo.$verifiedHealthProjection.dropFirst()) { _ in
                    guard scenePhase == .active else { return }
                    refreshExternalSurface()
                    driveLiveActivity()
                    WidgetSnapshot.publishLive(from: model)
                }
                .onReceive(model.live.$batteryPct.dropFirst()) { _ in
                    guard WidgetLivePublicationContext.shouldPublish(
                        sceneIsActive: scenePhase == .active,
                        hasActiveWorkout: model.activeWorkout != nil
                    ) else { return }
                    WidgetSnapshot.publishLive(from: model)
                }
                .onReceive(model.live.$connected.dropFirst()) { _ in
                    guard WidgetLivePublicationContext.shouldPublish(
                        sceneIsActive: scenePhase == .active,
                        hasActiveWorkout: model.activeWorkout != nil
                    ) else { return }
                    WidgetSnapshot.publishLive(from: model)
                }
                .onReceive(model.$bpm.dropFirst()) { _ in
                    guard WidgetLivePublicationContext.shouldPublish(
                        sceneIsActive: scenePhase == .active,
                        hasActiveWorkout: model.activeWorkout != nil
                    ) else { return }
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
                    refreshExternalSurface()
                    alarmRuntime.start()
                    await health.refreshAuthIfPreviouslyGranted(
                        requestNewTypes: scenePhase == .active
                    )
                    await model.recoverPendingSourceTransition()
                    await drainOldestSourcePrivacyCleanup()
                    await schedulePrivacyCleanupIfPending()
                    await drainCommittedHealthScoring()
                    await externalPublicationWorker.signal()
                    #if DEBUG
                    if CommandLine.arguments.contains("--component41-live-qa") {
                        await liveActivity.startComponent41QA()
                    }
                    #endif
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.protectedDataDidBecomeAvailableNotification
                    )
                ) { _ in
                    Task { @MainActor in
                        await health.refreshAuthIfPreviouslyGranted(
                            requestNewTypes: scenePhase == .active
                        )
                        await model.recoverPendingSourceTransition()
                        await drainOldestSourcePrivacyCleanup()
                        await schedulePrivacyCleanupIfPending()
                        await resumeBlockedWork(includeHealthKit: health.auth == .authorized)
                        await externalPublicationWorker.signal()
                    }
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
                    await health.refreshAuthIfPreviouslyGranted()
                    await model.recoverPendingSourceTransition()
                    await drainOldestSourcePrivacyCleanup()
                    await schedulePrivacyCleanupIfPending()
                    await resumeBlockedWork(includeHealthKit: false)
                    await resumeBlockedWork(includeHealthKit: health.auth == .authorized)
                    await health.foregroundCatchUp()
                    // Observer delivery can be suspended or its notification can land before this view's
                    // subscription is active. Foreground is the second deterministic drain, not a blind widget
                    // publish: wait for the durable scoring journal to settle first, then publish the snapshot.
                    await drainCommittedHealthScoring()
                    await externalPublicationWorker.signal()
                    _ = await WidgetSnapshot.publish(from: model)
                }
            } else if phase == .background {
                Task {
                    await schedulePrivacyCleanupIfPending()
                    await externalPublicationWorker.signal()
                    _ = await WidgetSnapshot.publish(from: model)
                }
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
