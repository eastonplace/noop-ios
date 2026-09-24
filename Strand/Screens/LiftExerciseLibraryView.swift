import SwiftUI
import StrandDesign

struct LiftExerciseLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var repo: Repository
    let selected: (String) -> Void
    @State private var query = ""
    @State private var equipment = "All equipment"
    @State private var detail: LiftExerciseDetailTarget?
    private var equipmentOptions: [String] {
        ["All equipment"] + Set(NoopLiftCatalog.entries.map(\.equipment)).sorted()
    }
    private var results: [NoopLiftCatalog.Entry] {
        NoopLiftCatalog.entries.filter {
            (equipment == "All equipment" || $0.equipment == equipment)
                && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                    || $0.muscle.localizedCaseInsensitiveContains(query))
        }
    }
    var body: some View {
        List {
            Section {
                Picker("Equipment", selection: $equipment) {
                    ForEach(equipmentOptions, id: \.self) { Text($0.capitalized).tag($0) }
                }
            }
            Section("\(results.count) exercises") {
                ForEach(results) { exercise in
                    HStack(spacing: 12) {
                        Button { detail = .init(name: exercise.name) } label: {
                            NoopLiftExerciseArtwork(name: exercise.name, size: 56)
                        }.buttonStyle(.plain).accessibilityLabel("View \(exercise.name) instructions and progress")
                        Button {
                            selected(exercise.name); dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(exercise.name).font(.headline).foregroundStyle(StrandPalette.textPrimary)
                                    Text("\(exercise.muscle.capitalized) · \(exercise.equipment.capitalized)")
                                        .font(.caption).foregroundStyle(StrandPalette.textSecondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "plus.circle").foregroundStyle(StrandPalette.accent)
                            }.frame(minHeight: 56).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Add \(exercise.name)")
                    }.listRowBackground(StrandPalette.card)
                }
            }
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Use “\(query)” as a custom exercise") {
                    selected(query.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss()
                }
            }
        }.scrollContentBackground(.hidden).background(StrandPalette.appCanvas)
            .navigationTitle("Exercise library").searchable(text: $query, prompt: "Exercise or muscle")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(item: $detail) { target in
                NavigationStack { LiftExerciseDetailView(name: target.name, owner: repo.deviceId) }
            }
    }
}
