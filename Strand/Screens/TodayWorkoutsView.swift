import SwiftUI
import StrandDesign
import WhoopStore

enum TodayWorkoutsProjection {
    static func rows(_ rows: [WorkoutRow], on day: Date, calendar: Calendar = .current) -> [WorkoutRow] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return rows.filter {
            let date = Date(timeIntervalSince1970: TimeInterval($0.startTs))
            return date >= start && date < end
        }.sorted { $0.startTs > $1.startTs }
    }
}

/// What a day's workouts add up to, for the summary strip.
struct TodayWorkoutsSummary: Equatable {
    let sessions: Int
    let activeSeconds: Double
    let energyKcal: Double

    init(sessions: Int, activeSeconds: Double, energyKcal: Double) {
        self.sessions = sessions
        self.activeSeconds = activeSeconds
        self.energyKcal = energyKcal
    }

    init(rows: [WorkoutRow]) {
        self.init(
            sessions: rows.count,
            activeSeconds: rows.reduce(0) { $0 + (WorkoutFacts.activeSeconds($1) ?? 0) },
            energyKcal: rows.reduce(0) { $0 + max(0, $1.energyKcal ?? 0) })
    }
}

/// Read-only, day-focused workout route used only by Today's at-a-glance row. The full WorkoutsView
/// remains the management/history destination everywhere else.
struct TodayWorkoutsView: View {
    let day: Date

    @EnvironmentObject private var repo: Repository
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @State private var rows: [WorkoutRow] = []
    @State private var traces: [String: [Double]] = [:]
    @State private var loaded = false

    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    var body: some View {
        ScreenScaffold(title: "Workouts", lazy: true, headerContext: DrillInFormat.headerDate(day)) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !loaded {
                    loading
                } else if rows.isEmpty {
                    WorkoutEmptyState(
                        symbol: "figure.cooldown", title: "Rest day",
                        message: "No workouts were recorded for this day.")
                } else {
                    summary(TodayWorkoutsSummary(rows: rows))
                    FlatSectionSeparator.beforeRows
                    sessions
                }
            }
        }
        .task(id: Calendar.current.startOfDay(for: day)) { await load() }
    }

    /// Sessions, active time and calories for the day, in one quiet strip.
    private func summary(_ totals: TodayWorkoutsSummary) -> some View {
        StatFooter(items: [
            (label: String(localized: "Sessions"), value: totals.sessions.formatted()),
            (label: String(localized: "Active"), value: WorkoutFormat.duration(totals.activeSeconds)),
            (label: String(localized: "Calories"),
             value: totals.energyKcal > 0 ? WorkoutFormat.energy(totals.energyKcal) : WidgetMetrics.missingValue),
        ], style: .compact)
        .accessibilityElement(children: .combine)
    }

    private var sessions: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.listID) { index, row in
                if index > 0 { WorkoutRowSeparator() }
                NavigationLink {
                    WorkoutDetailView(row: row)
                        .environment(\.screenScaffoldNavigationRole, .detail)
                } label: {
                    WorkoutRowContent(
                        presentation: .make(row, unitSystem: unitSystem, when: .time, detail: .full, includesSource: true),
                        heartRate: traces[row.listID] ?? [],
                        showsChevron: true)
                }
                .buttonStyle(PaperPressStyle())
                .accessibilityHint("Opens workout detail")
            }
        }
    }

    /// The day's strip and rows, before they arrive: quiet placeholders in the shape of the real ones.
    private var loading: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary(TodayWorkoutsSummary(sessions: 2, activeSeconds: 3_900, energyKcal: 640))
            FlatSectionSeparator.beforeRows
            ForEach(0..<2, id: \.self) { index in
                if index > 0 { WorkoutRowSeparator() }
                WorkoutRowContent(presentation: WorkoutRowPresentation(
                    title: "Running", symbol: "figure.run", primary: "5.0 km",
                    lines: [["6:00 PM", "Manual"], ["30m", "300 kcal"]],
                    strain: .noop("10.0"), source: .manual))
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading your sessions…")
    }

    @MainActor private func load() async {
        let start = Calendar.current.startOfDay(for: day)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else {
            loaded = true
            return
        }
        let all = await repo.workoutRows(
            from: Int(start.timeIntervalSince1970),
            to: Int(end.timeIntervalSince1970)
        )
        let projected = TodayWorkoutsProjection.rows(all, on: day)
        rows = projected
        loaded = true
        var loadedTraces: [String: [Double]] = [:]
        for row in projected {
            if Task.isCancelled { return }
            let buckets = await repo.workoutHrBuckets(from: row.startTs, to: row.endTs).map(\.bpm)
            loadedTraces[row.listID] = WorkoutTrace.downsampled(buckets, to: WorkoutTrace.rowPoints)
            traces = loadedTraces
        }
    }
}
