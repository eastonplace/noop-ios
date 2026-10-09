#if DEBUG && os(iOS)
import SwiftUI
import StrandDesign

/// Screenshot/QA harness, DEBUG only: `--noop-qa-route <route>` opens a deep screen straight from launch so
/// it can be captured without UI automation. Each route is presented the way the app normally reaches it:
/// pushed inside the owning tab's navigation stack, the same full-screen cover or sheet, or through the shell's
/// quick-action / routed-pillar sheets. Pair it with `--demo-seed` (demo data) and, optionally, `--demo-tab`.
///
/// Routes: stress, hr-timeline, pillar-recovery, pillar-strain, sleep, workouts, today-workouts, health,
/// metric-explorer, metric-detail-hrv, compare, trends-explore, insights, intelligence, scoring-guide, updates,
/// live-hr, breathe, journal, intervals, start-workout, rhythm, smart-alarm, hydration, fitness-age, coupled,
/// lab-book, trends-report.
enum QARoute: String, CaseIterable {
    case stress
    case hrTimeline = "hr-timeline"
    case pillarRecovery = "pillar-recovery"
    case pillarStrain = "pillar-strain"
    case sleep
    case workouts
    case todayWorkouts = "today-workouts"
    case health
    case metricExplorer = "metric-explorer"
    case metricDetailHRV = "metric-detail-hrv"
    case compare
    case trendsExplore = "trends-explore"
    case insights
    case intelligence
    case scoringGuide = "scoring-guide"
    case updates
    case liveHR = "live-hr"
    case breathe
    case journal
    case intervals
    case startWorkout = "start-workout"
    case rhythm
    case smartAlarm = "smart-alarm"
    case hydration
    case fitnessAge = "fitness-age"
    case coupled
    case labBook = "lab-book"
    case trendsReport = "trends-report"

    /// The tab whose navigation stack, cover or sheet presents the route.
    enum Tab: Int { case today = 0, trends = 1, sleep = 2 }

    /// What the app shell (`RootTabView`) presents itself, for routes that live in its sheets.
    enum ShellTarget { case updates, rhythm, liveHR, breathe, journal, intervals, startWorkout }

    enum Presentation {
        case push(Tab)
        case cover(Tab)
        case sheet(Tab)
        case shell(ShellTarget)
    }

    var presentation: Presentation {
        switch self {
        case .stress, .hrTimeline, .workouts, .todayWorkouts, .health, .hydration, .fitnessAge, .coupled:
            return .push(.today)
        case .pillarRecovery, .pillarStrain, .sleep:
            return .cover(.today)
        case .scoringGuide:
            return .sheet(.today)
        case .metricExplorer, .metricDetailHRV, .compare, .trendsExplore, .insights, .intelligence, .labBook:
            return .push(.trends)
        case .trendsReport:
            return .sheet(.trends)
        case .smartAlarm:
            return .push(.sleep)
        case .updates: return .shell(.updates)
        case .rhythm: return .shell(.rhythm)
        case .liveHR: return .shell(.liveHR)
        case .breathe: return .shell(.breathe)
        case .journal: return .shell(.journal)
        case .intervals: return .shell(.intervals)
        case .startWorkout: return .shell(.startWorkout)
        }
    }

    /// The tab the app should launch on so the route is presented over the right root.
    var launchTab: Tab {
        switch presentation {
        case .push(let tab), .cover(let tab), .sheet(let tab): return tab
        case .shell: return .today
        }
    }

    /// Logged once the route is on screen, so a capture script knows when to start waiting for a stable frame.
    func logPresented() { NSLog("[qa-route] presented %@", rawValue) }

    /// True while any modal is presented over the app's root view controller (the shell's quick-action and
    /// routed-pillar sheets), which is how the shell route knows its sheet was not dropped.
    @MainActor static var modalIsPresented: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { $0.rootViewController?.presentedViewController != nil }
    }

    static let requested: QARoute? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--noop-qa-route"),
              arguments.indices.contains(index + 1) else { return nil }
        return QARoute(rawValue: arguments[index + 1].lowercased())
    }()
}

/// Screenshot helper: scrolls the screen's main vertical scroll view to an exact offset on request, so a capture
/// script can take overlapping frames and stitch a full-length image without UI automation. Enabled by
/// `--noop-qa-scroll-poll`; the script writes the wanted offset in points (0 = top) to `/tmp/noop-qa-scroll.txt`
/// and reads the `[qa-scroll] ...` line the app logs once the offset is applied.
enum QAScrollDriver {
    static let requestPath = "/tmp/noop-qa-scroll.txt"
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--noop-qa-scroll-poll") }

    @MainActor static func run() async {
        guard enabled else { return }
        var last: String?
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(400))
            guard let raw = try? String(contentsOfFile: requestPath, encoding: .utf8) else { continue }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text != last, let points = Double(text) else { continue }
            last = text
            apply(points)
        }
    }

    @MainActor private static func apply(_ points: Double) {
        guard let scroll = mainScrollView() else {
            NSLog("[qa-scroll] requested=%.1f no-scroll-view", points)
            return
        }
        let top = -scroll.adjustedContentInset.top
        let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        let maxY = max(top, bottom)
        let y = min(max(top + points, top), maxY)
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: false)
        NSLog("[qa-scroll] requested=%.1f applied=%.1f max=%.1f insetTop=%.1f insetBottom=%.1f",
              points, y - top, maxY - top, scroll.adjustedContentInset.top, scroll.adjustedContentInset.bottom)
    }

    /// The topmost vertically scrollable, full-width scroll view under the middle of the screen.
    @MainActor private static func mainScrollView() -> UIScrollView? {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else { return nil }
        let center = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        var found: UIScrollView?
        func visit(_ view: UIView) {
            if view.isHidden || view.alpha < 0.01 { return }
            if let scroll = view as? UIScrollView,
               scroll.contentSize.height > scroll.bounds.height + 1,
               scroll.bounds.width >= window.bounds.width * 0.8,
               scroll.convert(scroll.bounds, to: window).contains(center) {
                found = scroll
            }
            view.subviews.forEach(visit)
        }
        visit(window)
        return found
    }
}

/// Presents the requested QA route over a tab root. Attach it to the tab's root view so its covers and sheets
/// inherit the same environment the root's own presentations do.
private struct QARouteHost: ViewModifier {
    let tab: QARoute.Tab
    @EnvironmentObject private var repo: Repository
    @State private var pushed = false
    @State private var covered = false
    @State private var sheeted = false
    @State private var arrived = false

    private var route: QARoute? {
        guard let route = QARoute.requested else { return nil }
        switch route.presentation {
        case .push(tab), .cover(tab), .sheet(tab): return route
        default: return nil
        }
    }

    func body(content: Content) -> some View {
        content
            .navigationDestination(isPresented: $pushed) { pushDestination.onAppear(perform: arrive) }
            .fullScreenCover(isPresented: $covered) {
                coverDestination.environment(\.screenScaffoldNavigationRole, .detail).onAppear(perform: arrive)
            }
            .sheet(isPresented: $sheeted) { sheetDestination.onAppear(perform: arrive) }
            .task {
                guard let route else { return }
                // A presentation issued while the tab root is still laying out (or while a transition is in
                // flight, on a loaded machine) can be silently dropped, so retry until the screen appears.
                for attempt in 0..<10 {
                    try? await Task.sleep(for: .milliseconds(attempt == 0 ? 1500 : 3000))
                    if arrived { return }
                    pushed = false; covered = false; sheeted = false
                    try? await Task.sleep(for: .milliseconds(400))
                    switch route.presentation {
                    case .push: pushed = true
                    case .cover: covered = true
                    case .sheet: sheeted = true
                    case .shell: return
                    }
                }
            }
    }

    private func arrive() {
        guard !arrived, let route else { return }
        arrived = true
        route.logPresented()
    }

    private var anchorDayKey: String {
        repo.today?.day ?? Repository.localDayKey(Repository.logicalDay(Date()))
    }

    @ViewBuilder private var pushDestination: some View {
        switch route {
        case .stress: StressView()
        case .hrTimeline: FullDayChartView()
        case .workouts: WorkoutsView()
        case .todayWorkouts: TodayWorkoutsView(day: Repository.logicalDay(Date()))
        case .health: HealthView()
        case .hydration: HydrationView()
        case .fitnessAge: FitnessAgeDetailView()
        case .coupled: CoupledView()
        case .metricExplorer: MetricExplorerView()
        case .metricDetailHRV:
            if let metric = MetricCatalog.all.first(where: { $0.key == "hrv" }) { MetricDetailView(metric: metric) }
        case .compare: CompareView()
        case .trendsExplore: TrendsExploreHubView()
        case .insights: InsightsHubView()
        case .intelligence: IntelligenceView()
        case .labBook: LabBookView()
        case .smartAlarm: SmartAlarmView()
        default: EmptyView()
        }
    }

    @ViewBuilder private var coverDestination: some View {
        switch route {
        case .pillarRecovery: PaperPillarDetailView(kind: .charge, anchorDayKey: anchorDayKey)
        case .pillarStrain: PaperPillarDetailView(kind: .effort, anchorDayKey: anchorDayKey)
        case .sleep: SleepView()
        default: EmptyView()
        }
    }

    @ViewBuilder private var sheetDestination: some View {
        switch route {
        case .scoringGuide: ScoringGuideView(onClose: { sheeted = false })
        case .trendsReport: TrendsReportSheet(days: repo.canonicalDays)
        default: EmptyView()
        }
    }
}

extension View {
    /// DEBUG QA hook: presents `--noop-qa-route` over this tab root when the route belongs to `tab`.
    func qaRouteHost(_ tab: QARoute.Tab) -> some View { modifier(QARouteHost(tab: tab)) }
}
#endif
