#if DEBUG && os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// DEBUG-only screenshot harness, intentionally separated from the production app/lifecycle entry point.
enum DemoScreens {
    static let routeNames: [String] = [
        "today", "trends", "trendslastweek", "fullday", "sleep", "live", "stress", "workouts",
        "workoutdetail", "health", "atoms", "insights", "insightshub", "intelligence", "explore",
        "compare", "coach", "settings", "applehealth", "storage", "trendsreport", "fused",
        "scoringguide", "updates", "whatsnew", "hownoopworks", "xiaomi", "intervals", "hydration",
        "breathing", "manualworkout", "journal", "checkin", "behaviorsettings", "quickadd", "journalcard",
        "caffeinecard", "stresscheckin", "skintempcards", "autoworkoutcard", "mindsection", "hrvsnapshot",
        "watchsetup", "watchabout", "dashboardeditor", "keymetricseditor", "data", "backup", "support",
        "labbook", "automations", "alarms", "testcentre", "rhythmconsent", "rhythm", "liveworkout",
        "preworkout", "recoverydetail", "straindetail", "sleepdetail", "devices", "devicescatalog",
        "fitnessage", "fitnessagedetail", "vitality", "addwizard", "ouraonboarding", "ouradevice",
        "component41", "component41home", "component41large", "component41lock", "component41live",
        "onboarding",
    ]

    @MainActor
    static var requested: AnyView? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--demo-screen"), index + 1 < args.count else { return nil }
        return view(named: args[index + 1])
    }

    @MainActor
    static func view(named name: String) -> AnyView? {
        if name.lowercased().hasPrefix("onboarding-") {
            let suffix = name.dropFirst("onboarding-".count)
            if let step = Int(suffix), (1...12).contains(step) {
                return AnyView(OnboardingWizard(onFinished: {}, initialStepIndex: step - 1))
            }
        }
        switch name.lowercased() {
        case "today": return AnyView(TodayView())
        case "trends": return AnyView(TrendsView())
        case "trendslastweek": return AnyView(TrendsView(initialWeekOffset: -1))
        case "fullday": return AnyView(FullDayChartView())
        case "sleep": return AnyView(SleepView())
        case "live": return AnyView(LiveView())
        case "stress": return AnyView(StressView())
        case "workouts": return AnyView(WorkoutsView())
        case "workoutdetail": return AnyView(WorkoutDetailDemoHost())
        case "health": return AnyView(HealthView())
        case "atoms": return AnyView(DesignLabAtomGallery())
        case "component41": return AnyView(Component41QAGallery())
        case "component41home": return AnyView(Component41QAShot(kind: .home))
        case "component41large": return AnyView(Component41QAShot(kind: .large))
        case "component41lock": return AnyView(Component41QAShot(kind: .lock))
        case "component41live": return AnyView(Component41QAShot(kind: .live))
        case "insights", "insightshub": return AnyView(InsightsHubView())
        case "journal": return AnyView(CoachingRootView())
        case "checkin": return AnyView(NavigationStack { CoachingCheckInView() })
        case "behaviorsettings": return AnyView(NavigationStack { CoachingBehaviorSettingsView() })
        case "quickadd": return AnyView(NavigationStack { CoachingQuickAddView() })
        case "stackdetail": return AnyView(NavigationStack { CoachingStackDemoRoute() })
        case "intelligence": return AnyView(IntelligenceView())
        case "explore": return AnyView(MetricExplorerView())
        case "compare": return AnyView(CompareView())
        case "coach": return AnyView(CoachView())
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
        case "recoverydetail": return AnyView(PaperPillarDetailView(
            kind: .charge, anchorDayKey: Repository.logicalDayKey(Date())))
        case "straindetail": return AnyView(PaperPillarDetailView(
            kind: .effort, anchorDayKey: Repository.logicalDayKey(Date())))
        case "sleepdetail": return AnyView(SleepView())
        case "devices", "bondrefused": return AnyView(DevicesView())
        case "devicescatalog": return AnyView(DeviceCardCatalog())
        case "fitnessage": return AnyView(FitnessAgeDemoScreen())
        case "fitnessagedetail": return AnyView(NavigationStack { FitnessAgeDetailView() })
        case "vitality": return AnyView(VitalityDemoScreen())
        case "addwizard": return AnyView(AddWizardDemoHost())
        case "ouraonboarding": return AnyView(OuraOnboardingDemoHost())
        case "ouradevice": return AnyView(OuraDeviceDemoScreen())
        case "onboarding": return AnyView(OnboardingWizard(onFinished: {}))
        default: return nil
        }
    }

    private static var cleanupAuditFusedRecord: FusedRecord {
        let contributors = [
            ContributingSource(
                source: .whoopImport, value: 58, tier: 0, sourcePriority: 0,
                reason: "comes directly from the overnight record"),
            ContributingSource(
                source: .appleHealth, value: 71, tier: 1, sourcePriority: 0,
                reason: "is the best available secondary source"),
        ]
        let point = FusedMetricPoint(
            metric: "resting_hr", value: 58, winningSource: .whoopImport,
            contributors: contributors, agreement: .conflict)
        return FusedRecord(
            rows: [FusedRow(point: point, label: "Resting HR")],
            dayOwner: .whoopImport,
            contributingSourceCount: 2)
    }
}

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
                        WorkoutRoute(
                            polyline: RouteMath.encode(points),
                            distanceM: RouteMath.totalMeters(points)),
                        startTs: row.startTs,
                        sport: row.sport)
                }
                routeRevision = 1
            }
    }
}

private struct LiveWorkoutDemoHost: View {
    @EnvironmentObject private var model: AppModel
    @State private var seeded = false
    var body: some View {
        LiveWorkoutView(onClose: {})
            .task {
                guard !seeded else { return }
                seeded = true
                await Task.yield()
                let elapsed = 32.0 * 60.0 + 47.0
                let start = Date().addingTimeInterval(-elapsed)
                var samples = (0..<180).map { index -> HRSample in
                    let phase = Double(index)
                    let bpm = Int((143.0 + 9.0 * sin(phase / 10.0) + 4.0 * sin(phase / 3.7)).rounded())
                    return HRSample(ts: Int(start.timeIntervalSince1970) + index * 11, bpm: bpm)
                }
                samples[samples.count - 1] = HRSample(
                    ts: Int(Date().timeIntervalSince1970), bpm: 152)
                var workout = AppModel.ActiveWorkout(
                    start: start, sport: "Running", maxHR: Double(model.profile.hrMax))
                workout.samples = samples
                workout.strainAccumulator = .init(
                    samples: samples, maxHR: Double(model.profile.hrMax))
                workout.liveStrainState = .scored(storedValue: 54.3)
                workout.avgHr = 144
                workout.peakHr = 171
                model.activeWorkout = workout
                model.bpm = 152
                model.live.sensorCadence = 168
                model.gpsRecorder.seedDemoRoute(
                    points: PaperRunDemoRoute.liveRoute,
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
    static let liveRoute = loop + Array(loop.dropFirst()) + Array(loop.dropFirst().prefix(6))
}

private struct AddWizardDemoHost: View {
    @EnvironmentObject var live: LiveState
    var body: some View { AddDeviceWizard(live: live, onClose: {}) }
}

private struct OuraOnboardingDemoHost: View {
    @EnvironmentObject var live: LiveState
    var body: some View { AddDeviceWizard(live: live, onClose: {}, startAt: (.oura, .prep)) }
}

private struct WorkoutDetailDemoHost: View {
    @EnvironmentObject private var repo: Repository
    @State private var row: WorkoutRow?
    var body: some View {
        Group {
            if let row { WorkoutDetailView(row: row) }
            else { ProgressView().task { row = await repo.workoutRows(days: 4_000).first } }
        }
    }
}

private struct JournalCardDemoHost: View {
    @State private var dayOffset = 0
    var body: some View {
        ScrollView {
            JournalLogCard(
                importedQuestions: [], answers: [:], dayOffset: $dayOffset, onChanged: {})
                .padding(NoopMetrics.screenPadding)
        }
        .background(StrandPalette.surfaceBase)
    }
}

private struct CaffeineCardDemoHost: View {
    var body: some View {
        ScrollView { CaffeineLogCard().padding(NoopMetrics.screenPadding) }
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
                    result: .init(
                        phase: .luteal, confidence: .solid,
                        cycleDayLow: 20, cycleDayHigh: 24, cycleLengthDays: 28,
                        nextPeriodWindow: .init(
                            earliestDay: "2026-07-18", latestDay: "2026-07-22"),
                        shiftMarkers: [],
                        note: "Temperature is running above your baseline."),
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
                avgBpm: 148, peakBpm: 171, durationMin: 27))
                .padding(NoopMetrics.screenPadding)
        }
        .background(StrandPalette.surfaceBase)
        .onAppear { UserDefaults.standard.set(true, forKey: PuffinExperiment.autoDetectWorkoutsKey) }
    }
}

private struct MindSectionDemoHost: View {
    var body: some View {
        ScrollView { MindSection().padding(NoopMetrics.screenPadding) }
            .background(StrandPalette.surfaceBase)
    }
}
#endif
