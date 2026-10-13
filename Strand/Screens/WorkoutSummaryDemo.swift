#if DEBUG && os(iOS)
import Foundation
import WhoopStore

// MARK: - Screenshot fixtures for the journey's summary (DEBUG only)
//
// `--noop-qa-route start-workout --demo-seed --demo-journey-summary run|strength|short|rowing` opens the journey straight on its summary
// for one of the demo week's workouts: a run with its route and a dense heart-rate trace, a strength session with no route, a
// 41-second session with no heart rate, or (made up, with no stored readings) a 42-minute row with its distance. `--demo-journey-summary-legacy` draws the summary the way it was before the redesign (the
// shared workout detail screen with its Done button), so a before/after pair comes from one build.

enum WorkoutSummaryDemo {
    enum Scenario: String {
        case run, strength, short, rowing
    }

    static var requested: Scenario? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--demo-journey-summary"), arguments.indices.contains(flag + 1) else { return nil }
        return Scenario(rawValue: arguments[flag + 1])
    }

    static var usesLegacySummary: Bool {
        ProcessInfo.processInfo.arguments.contains("--demo-journey-summary-legacy")
    }

    /// The workout the scenario names. The demo week is written at launch and the repository may not have read it yet, so look for it
    /// for a few seconds before giving up.
    @MainActor static func row(for scenario: Scenario, in repo: Repository) async -> WorkoutRow? {
        if scenario == .rowing {
            // A route sport that is not a run, to see its pace read as it was on the live screen.
            let end = Int(Date().timeIntervalSince1970) - 300
            return WorkoutRow(startTs: end - 2_520, endTs: end, sport: "Rowing", source: "recorded", durationS: 2_520,
                              energyKcal: 436, avgHr: 142, maxHr: 171, strain: 48, distanceM: 8_400, zonesJSON: nil, notes: nil,
                              strainVersion: 2)
        }
        if scenario == .short {
            let end = Int(Date().timeIntervalSince1970) - 20
            return WorkoutRow(startTs: end - 41, endTs: end, sport: "Strength Training", source: "manual", durationS: 41,
                              energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil, notes: nil)
        }
        for _ in 0..<20 {
            let rows = await repo.workoutRows(days: 30)
            let found = rows.first { row in
                switch scenario {
                case .run: row.sport == "Running" && row.source == "manual"
                case .strength: row.sport == "Strength Training" && row.source == "manual"
                case .short, .rowing: false
                }
            }
            if let found { return found }
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return nil }
        }
        return nil
    }
}
#endif
