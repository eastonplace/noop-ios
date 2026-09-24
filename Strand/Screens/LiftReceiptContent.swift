import SwiftUI
import StrandDesign

struct LiftReceiptLine: Identifiable {
    let id: String
    let ordinal: Int
    let exercise: String
    let weightKg: Double?
    let reps: Int?
    var isWarmup = false
}

/// Shared by the live receipt and saved history. Uses NOOP surfaces and type, with Lift's hierarchy.
struct LiftReceiptContent: View {
    let title: String
    let subtitle: String
    let lines: [LiftReceiptLine]
    let system: UnitSystem
    var openExercise: (String) -> Void = { _ in }
    private var names: [String] { lines.reduce(into: []) { if !$0.contains($1.exercise) { $0.append($1.exercise) } } }
    private var volume: Double {
        lines.filter { !$0.isWarmup }.reduce(0) { $0 + max(0, $1.weightKg ?? 0) * Double(max(0, $1.reps ?? 0)) }
    }
    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(subtitle).font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    Image(systemName: "list.bullet.rectangle").foregroundStyle(StrandPalette.accent)
                }
                Text(title).font(StrandFont.largeTitle)
                HStack(spacing: 24) {
                    summary("SETS", "\(lines.count)")
                    summary("EXERCISES", "\(names.count)")
                    summary("VOLUME", volume > 0 ? "\(Int(LiftFormat.display(fromKilograms: volume, system: system).rounded()).formatted()) \(LiftFormat.weightUnit(system))" : "—")
                }
                Divider()
                if lines.isEmpty {
                    Text("Your first set starts the receipt.").foregroundStyle(StrandPalette.textSecondary).padding(.vertical, 24)
                }
                ForEach(names, id: \.self) { name in
                    VStack(alignment: .leading, spacing: 12) {
                        Button { openExercise(name) } label: {
                            HStack(spacing: 12) {
                                NoopLiftExerciseArtwork(name: name, size: 48)
                                Text(name).font(.headline)
                                Spacer()
                                Image(systemName: "chart.xyaxis.line").foregroundStyle(StrandPalette.accent)
                            }
                        }.buttonStyle(.plain).accessibilityLabel("\(name), view progress")
                        ForEach(lines.filter { $0.exercise == name }) { line in
                            HStack {
                                Text(line.isWarmup ? "Warm-up" : "Set \(line.ordinal)").foregroundStyle(StrandPalette.textSecondary)
                                Spacer()
                                Text("\(LiftFormat.weight(line.weightKg, system: system)) × \(line.reps.map(String.init) ?? "—")")
                                Image(systemName: "checkmark").foregroundStyle(StrandPalette.accent)
                            }.font(.subheadline.monospacedDigit())
                        }
                    }
                    Divider()
                }
                Text("Every line is a completed set. Tap an exercise to see its history.")
                    .font(.caption).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }
    private func summary(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary)
            Text(value).font(.headline.monospacedDigit())
        }
    }
}

struct LiftComposerContent: View {
    let setIndex: Int
    @Binding var weight: String
    @Binding var reps: String
    let unit: String
    let canLog: Bool
    var setKind = "Working set"
    let log: () -> Void
    @FocusState private var editing: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("LOG SET \(setIndex)").font(.caption.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Text(setKind).font(.caption).foregroundStyle(StrandPalette.textSecondary)
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("WEIGHT (\(unit.uppercased()))").font(.caption.weight(.semibold))
                    TextField("0", text: $weight).focused($editing)
                        .frame(minHeight: 44)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                        .accessibilityLabel("Weight in \(unit)")
                    HStack {
                        Button { adjustWeight(-5) } label: { Image(systemName: "minus").frame(maxWidth: .infinity, minHeight: 44) }.accessibilityLabel("Decrease weight by five \(unit)")
                        Button { adjustWeight(5) } label: { Image(systemName: "plus").frame(maxWidth: .infinity, minHeight: 44) }.accessibilityLabel("Increase weight by five \(unit)")
                    }.buttonStyle(.bordered)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("REPS").font(.caption.weight(.semibold))
                    TextField("8", text: $reps).focused($editing)
                        .frame(minHeight: 44)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .accessibilityLabel("Repetitions")
                    HStack {
                        Button { reps = String(max(1, (Int(reps) ?? 8) - 1)) } label: { Image(systemName: "minus").frame(maxWidth: .infinity, minHeight: 44) }.accessibilityLabel("Decrease reps")
                        Button { reps = String(min(1000, (Int(reps) ?? 8) + 1)) } label: { Image(systemName: "plus").frame(maxWidth: .infinity, minHeight: 44) }.accessibilityLabel("Increase reps")
                    }.buttonStyle(.bordered)
                }
            }.textFieldStyle(.roundedBorder)
            Button("Log set", systemImage: "plus") { editing = false; log() }
                .buttonStyle(.noopPrimary).disabled(!canLog)
        }
        #if os(iOS)
        .toolbar {
            if editing { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { editing = false } } }
        }
        #endif
    }
    private func adjustWeight(_ delta: Double) {
        let value = LiftFormat.number(weight) ?? 0
        weight = LiftFormat.trim(min(1000, max(0, value.isFinite ? value + delta : 0)))
    }

}

struct LiftRoutinePreviewContent: View {
    struct Exercise {
        let name: String
        let sets: Int
        let reps: Int?
        let restSeconds: Int
    }
    let title: String
    let exercises: [Exercise]
    var openExercise: (String) -> Void = { _ in }
    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 22) {
                Text("ROUTINE PREVIEW").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(StrandPalette.textSecondary)
                Text(title).font(StrandFont.largeTitle)
                Divider()
                ForEach(exercises.indices, id: \.self) { index in
                    Button { openExercise(exercises[index].name) } label: {
                    HStack(alignment: .center, spacing: 14) {
                        NoopLiftExerciseArtwork(name: exercises[index].name, size: 56)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(exercises[index].name).font(.headline)
                            Text("\(exercises[index].sets) sets · \(exercises[index].reps.map(String.init) ?? "—") reps · \(exercises[index].restSeconds)s rest")
                                .font(.subheadline).foregroundStyle(StrandPalette.textSecondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                    }.buttonStyle(.plain).accessibilityLabel("\(exercises[index].name), instructions and progress")
                }
                Divider()
                Text("\(exercises.count) exercises · \(exercises.reduce(0) { $0 + $1.sets }) planned sets").font(.subheadline)
            }
        }
    }
}
