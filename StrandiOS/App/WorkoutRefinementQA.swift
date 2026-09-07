#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import StrandDesign
import WhoopProtocol
import WhoopStore

/// Explicit Simulator-only fixture route. Never compiled into Release or physical-device builds.
struct WorkoutRefinementQA: View {
    @EnvironmentObject private var model: AppModel
    @State private var ready = false
    @State private var row: WorkoutRow?
    @State private var error: String?
    private var mode: String { CommandLine.arguments.first(where: { $0.hasPrefix("--workout-review=") })?.components(separatedBy: "=").last ?? "indoor" }

    var body: some View {
        NavigationStack {
            if let error { Text(error) }
            else if ready {
                if mode == "summary", let row { WorkoutDetailView(row: row) }
                else if mode == "widget", let workout = model.activeWorkout {
                    VStack {
                        Text("Workout Live Activity").font(StrandFont.headline)
                        NOOPWorkoutLiveActivityView(title: workout.sport, startedAt: workout.start,
                                                   bpm: workout.currentBPM, strain: 8.4, strainBuilding: false,
                                                   calories: 210, hrSpark: workout.chartProjection.values.suffix(48).map { Int($0) },
                                                   maxHR: Double(model.profile.hrMax))
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                        Text("Simulator preview · synthetic readings").font(StrandFont.footnote)
                    }.padding()
                } else { LiveWorkoutView(onClose: {}) }
            } else { ProgressView("Preparing simulator workout") }
        }
        .task { await prepare() }
    }

    private func prepare() async {
        guard !ready else { return }
        let end = mode == "summary" ? 1_700_001_800 : Int(Date().timeIntervalSince1970)
        let start = end - 1800
        let sport = mode == "outdoor" ? "Running" : "Treadmill run"
        let samples = (0..<1800).filter { !(700..<820).contains($0) }.map { offset in
            HRSample(ts: start + offset, bpm: 102 + Int(70 * (sin(Double(offset) / 180) + 1) / 2))
        }
        let workout = AppModel.ActiveWorkout(start: Date(timeIntervalSince1970: Double(start)),
                                            sport: sport, maxHR: Double(model.profile.hrMax))
        workout.restore(samples: samples)
        model.activeWorkout = workout
        if mode == "outdoor" {
            model.gpsRecorder.seedDemoRoute(points: (0..<30).map { RouteMath.LatLng(40.76 + Double($0) * 0.0012, -73.98 + sin(Double($0) / 8) * 0.006) }, elapsedSeconds: 1800)
        }
        if mode == "summary" {
            let item = WorkoutRow(startTs: start, endTs: end, sport: sport, source: "manual", durationS: 1800,
                                  energyKcal: 210, avgHr: workout.avgHr, maxHr: workout.peakHr, strain: 35,
                                  distanceM: nil, zonesJSON: nil, notes: "Synthetic simulator review")
            do {
                guard let store = await model.repo.storeHandle() else { return }
                _ = try await store.insert(Streams(hr: samples), deviceId: model.repo.deviceId)
                _ = try await store.upsertWorkouts([item], deviceId: model.repo.deviceId)
                row = item
            } catch { self.error = error.localizedDescription; return }
        }
        ready = true
    }
}
#endif
