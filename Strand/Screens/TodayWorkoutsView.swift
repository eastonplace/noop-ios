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

/// Read-only, day-focused workout route used only by Today's at-a-glance row. The full WorkoutsView
/// remains the management/history destination everywhere else.
struct TodayWorkoutsView: View {
    let day: Date

    @EnvironmentObject private var repo: Repository
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.whoop.rawValue
    @State private var rows: [WorkoutRow] = []
    @State private var traces: [String: [Double]] = [:]
    @State private var loaded = false

    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    var body: some View {
        ScreenScaffold(title: "Workouts", subtitle: LocalizedStringKey(Self.dayTitle.string(from: day)), lazy: true) {
            summary
            if !loaded {
                PaperCard { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 28) }
            } else if rows.isEmpty {
                restDay
            } else {
                ForEach(rows, id: \.naturalID) { row in
                    NavigationLink {
                        WorkoutDetailView(row: row)
                            .environment(\.screenScaffoldNavigationRole, .detail)
                    } label: {
                        TodayWorkoutRow(model: rowModel(row))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task(id: Calendar.current.startOfDay(for: day)) { await load() }
    }

    private var summary: some View {
        let duration = rows.reduce(0.0) { $0 + ($1.durationS ?? Double(max(0, $1.endTs - $1.startTs))) }
        let calories = rows.compactMap(\.energyKcal).reduce(0, +)
        return PaperCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("DAY SUMMARY").strandOverline()
                HStack(spacing: 8) {
                    StatTile(label: "Sessions", value: "\(rows.count)")
                    StatTile(label: "Active", value: Self.duration(duration))
                    StatTile(label: "Calories", value: calories > 0 ? "\(Int(calories.rounded()))" : "—")
                }
            }
        }
    }

    private var restDay: some View {
        PaperCard {
            VStack(spacing: 10) {
                Image(systemName: "figure.cooldown").font(.system(size: 28)).foregroundStyle(StrandPalette.textTertiary)
                Text("Rest day").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                Text("No workouts were recorded for this day.")
                    .font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 26)
        }
        .accessibilityElement(children: .combine)
    }

    private func rowModel(_ row: WorkoutRow) -> TodayWorkoutRowModel {
        let duration = row.durationS ?? Double(max(0, row.endTs - row.startTs))
        var parts = [Self.time.string(from: Date(timeIntervalSince1970: TimeInterval(row.startTs))), Self.duration(duration)]
        if let kcal = row.energyKcal, kcal > 0 { parts.append("\(Int(kcal.rounded())) kcal") }
        if let hr = row.avgHr { parts.append("\(hr) bpm") }
        parts.append(Self.sourceLabel(row.source))
        let storedStrain = StrainResolver.canonicalWorkout(row)?.storedValue
        let strain = storedStrain
            .map { UnitFormatter.effortValue($0, scale: effortScale) }
            .map { String(format: "%.1f", $0) } ?? "—"
        return TodayWorkoutRowModel(
            id: row.naturalID, sport: WorkoutSource.displaySport(row.sport),
            subtitle: parts.joined(separator: " · "), strain: strain,
            heartRate: traces[row.naturalID] ?? []
        )
    }

    @MainActor private func load() async {
        let all = await repo.workoutRows()
        let projected = TodayWorkoutsProjection.rows(all, on: day)
        rows = projected
        loaded = true
        var loadedTraces: [String: [Double]] = [:]
        for row in projected {
            if Task.isCancelled { return }
            loadedTraces[row.naturalID] = await repo.workoutHrBuckets(from: row.startTs, to: row.endTs).map(\.bpm)
            traces = loadedTraces
        }
    }

    private static func duration(_ seconds: Double) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    private static func sourceLabel(_ source: String) -> String {
        switch WorkoutSource.classify(source) {
        case .whoop: return "WHOOP"
        case .apple: return "Apple Health"
        case .detected: return "Detected"
        case .manual: return "NOOP"
        case .lifting: return "Lifting import"
        case .activityFile: return "Activity file"
        }
    }

    private static let dayTitle: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return formatter
    }()
    private static let time: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("jm")
        return formatter
    }()
}

private extension WorkoutRow {
    var naturalID: String { "\(startTs)|\(sport)|\(source)" }
}
