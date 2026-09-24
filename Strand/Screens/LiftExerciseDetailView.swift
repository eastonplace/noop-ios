import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore

struct LiftExerciseDetailView: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    let name: String
    let owner: String
    @State private var tab = "Progress"
    @State private var metric = "Strength"
    @State private var rows: [LiftSetRow] = []
    @State private var loading = true
    @State private var error: String?
    @AppStorage(UnitPrefs.systemKey) private var systemRaw = UnitSystem.metric.rawValue
    private var system: UnitSystem { UnitSystem(rawValue: systemRaw) ?? .metric }
    private var working: [LiftSetRow] { rows.filter { !$0.isWarmup } }
    private var best: Double? { working.compactMap { LiftMetrics.estimatedOneRepMaxKg(weightKg: $0.weightKg, reps: $0.reps) }.max() }
    private var points: [LiftProgressPoint] {
        Dictionary(grouping: working, by: \.sessionId).compactMap { id, sets in
            guard let timestamp = sets.compactMap(\.startTs).min() else { return nil }
            let value = metric == "Volume" ? LiftMetrics.volumeLoadKg(sets) : sets.compactMap {
                LiftMetrics.estimatedOneRepMaxKg(weightKg: $0.weightKg, reps: $0.reps)
            }.max()
            guard let value else { return nil }
            return LiftProgressPoint(id: id, date: Date(timeIntervalSince1970: Double(timestamp)),
                                     value: LiftFormat.display(fromKilograms: value, system: system))
        }.sorted { $0.date < $1.date }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    NoopLiftExerciseArtwork(name: name, size: 112)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(name).font(StrandFont.title2)
                        if let entry = NoopLiftCatalog.resolve(name: name) {
                            Text(entry.muscle.capitalized).font(.subheadline)
                            Text(entry.equipment.capitalized).font(.caption).foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
                Picker("Exercise details", selection: $tab) {
                    Text("Progress").tag("Progress"); Text("History").tag("History"); Text("How to").tag("How to")
                }.pickerStyle(.segmented)
                if tab == "How to" {
                    NoopCard {
                        VStack(alignment: .leading, spacing: 16) {
                            NoopLiftExerciseArtwork(name: name, size: 220).frame(maxWidth: .infinity)
                            Text(NoopLiftCatalog.resolve(name: name)?.instructions ?? "No instructions linked to this custom exercise.")
                                .font(.body).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else if loading { ProgressView("Loading exercise history…") }
                else if let error { Text(error).foregroundStyle(StrandPalette.statusCritical) }
                else if tab == "Progress" {
                    NoopCard {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("BEST EST. 1RM · RECENT").font(.caption.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary)
                                    Text(LiftFormat.weight(best, system: system)).font(.system(size: 32, weight: .semibold, design: .rounded))
                                }
                                Spacer()
                                Text("\(Set(working.map(\.sessionId)).count) sessions").font(.caption)
                            }
                            Picker("Progress metric", selection: $metric) {
                                Text("Strength").tag("Strength"); Text("Volume").tag("Volume")
                            }.pickerStyle(.segmented)
                            LiftProgressChart(points: points, unit: LiftFormat.weightUnit(system), isVolume: metric == "Volume")
                            Text(metric == "Volume" ? "Total weight × reps per session. Warm-ups are excluded." : "Estimated from logged working sets of 1–12 reps. This is an estimate, not a measured maximum.")
                                .font(.caption).foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    Text("RECENT WORKING SETS").font(.caption.weight(.semibold))
                    recentSets(Array(working.prefix(8)))
                } else { recentSets(rows) }
            }.padding(20)
        }.background(StrandPalette.appCanvas).navigationTitle("Exercise").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: "\(owner)|\(name)") {
                loading = true
                defer { loading = false }
                do {
                    guard let store = await repo.storeHandle() else { error = "Your exercise history is unavailable."; return }
                    let fetched = try await store.liftExerciseHistory(deviceId: owner, exercise: name, limit: 60)
                    guard !Task.isCancelled else { return }
                    rows = fetched; error = nil
                } catch { self.error = "Couldn’t load your history. \(error.localizedDescription)" }
            }
    }
    private func recentSets(_ sets: [LiftSetRow]) -> some View {
        VStack(spacing: 0) {
            if sets.isEmpty { ContentUnavailableView("No saved sets yet", systemImage: "chart.xyaxis.line", description: Text("Log this exercise to start tracking progress.")) }
            ForEach(sets, id: \.id) { set in
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        if let stamp = set.startTs {
                            Text(Date(timeIntervalSince1970: Double(stamp)), style: .date).font(.subheadline)
                        } else { Text("Date not recorded").font(.subheadline) }
                        Text(set.isWarmup ? "Warm-up" : "Set \(set.setIndex)").font(.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer()
                    Text("\(LiftFormat.weight(set.weightKg, system: system)) × \(set.reps.map(String.init) ?? "—")").font(.subheadline.monospacedDigit())
                }.padding(.vertical, 12)
                Divider()
            }
        }
    }
}

