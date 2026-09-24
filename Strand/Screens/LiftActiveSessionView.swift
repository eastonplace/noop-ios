import SwiftUI
import StrandDesign
import WhoopStore

/// The controller owns the session and persistence; dismissing this screen only minimizes it.
struct LiftActiveSessionView: View {
    @EnvironmentObject private var session: LiftSessionController
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(UnitPrefs.systemKey) private var systemRaw = UnitSystem.metric.rawValue
    @State private var selectedExercise = 0
    @State private var showReceipt = false
    @State private var completedReceipt: [LiftReceiptLine]?
    @State private var exerciseDetail: LiftExerciseDetailTarget?
    @State private var loadingPrevious = true
    @State private var previousSets: [String: [LiftSetRow]] = [:]
    @State private var saving = false
    @State private var confirmFinish = false
    @State private var confirmDiscard = false
    @State private var error: String?
    private var system: UnitSystem { UnitSystem(rawValue: systemRaw) ?? .metric }

    var body: some View {
        NavigationStack {
            Group {
                if let completedReceipt {
                    ScrollView {
                        LiftReceiptContent(title: session.programName ?? "Lift", subtitle: "WORKOUT SAVED",
                                           lines: completedReceipt, system: system, openExercise: { exerciseDetail = .init(name: $0) }).padding(20)
                    }
                } else if let engine = session.engine {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            VStack(spacing: 12) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("DURATION").font(.caption2.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary)
                                        TimelineView(.periodic(from: .now, by: 1)) { tick in
                                            Text(LiftFormat.duration(max(0, Int(tick.date.timeIntervalSince1970) - engine.startTs))).font(.title3.monospacedDigit())
                                        }
                                    }
                                    Spacer()
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("SETS").font(.caption2.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary)
                                        Text("\(engine.sets.count) / \(engine.allSlots.count)").font(.title3.monospacedDigit())
                                    }
                                    Spacer()
                                    Button { showReceipt = true } label: {
                                        Label("Receipt", systemImage: "list.bullet.rectangle").font(.subheadline.weight(.medium))
                                    }.buttonStyle(.bordered)
                                }
                                ProgressView(value: Double(engine.sets.count), total: Double(max(1, engine.allSlots.count)))
                                    .tint(StrandPalette.accent).accessibilityLabel("Workout set progress")
                            }
                            if engine.plan.indices.contains(selectedExercise) {
                                Text("CURRENT EXERCISE").font(.caption.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary)
                                NoopCard {
                                    VStack(alignment: .leading, spacing: 16) {
                                        LiftExerciseLink(name: engine.plan[selectedExercise].exercise) {
                                            exerciseDetail = .init(name: engine.plan[selectedExercise].exercise)
                                        }
                                        let slots = engine.slots(forExercise: selectedExercise)
                                        let done = slots.filter { engine.isCompleted($0) }.count
                                        LiftSetComparisonTable(rows: slots.map { slot in
                                            let recorded = engine.recordedSet(for: slot)
                                            let previous = previousSets[engine.plan[selectedExercise].exercise]?.first { $0.setIndex == slot.setIndex && !$0.isWarmup }
                                            return .init(id: slot.setIndex,
                                                previous: previous.map { "\(LiftFormat.weight($0.weightKg, system: system)) × \($0.reps.map(String.init) ?? "—")" } ?? "—",
                                                current: recorded.map { "\(LiftFormat.weight($0.weightKg, system: system)) × \($0.reps.map(String.init) ?? "—")" } ?? "—",
                                                done: recorded != nil)
                                        })
                                        Text("\(done) of \(slots.count) completed").font(.caption).foregroundStyle(StrandPalette.textSecondary)
                                        if let slot = slots.first(where: { !engine.isCompleted($0) }) {
                                            if loadingPrevious { ProgressView("Loading previous sets…") }
                                            else { LiftSetComposer(slot: slot, system: system).id(slot) }
                                        } else {
                                            Label("Added to your receipt", systemImage: "checkmark.circle.fill")
                                            Button("Add another set") { _ = session.addSet(toExercise: selectedExercise) }
                                                .disabled(engine.isFinished || engine.plan[selectedExercise].targetSets >= LiftSessionEngine.maxSetsPerExercise)
                                        }
                                    }
                                }
                            }
                            queue(engine, printed: false)
                            queue(engine, printed: true)
                            if let error { Text(error).foregroundStyle(StrandPalette.statusCritical) }
                            Button("Discard session", role: .destructive) { confirmDiscard = true }.disabled(saving)
                        }.padding(20)
                    }
                    .disabled(saving)
                    .safeAreaInset(edge: .bottom) { controls(engine) }
                } else {
                    ContentUnavailableView("No active session", systemImage: "dumbbell")
                }
            }
            .background(StrandPalette.appCanvas)
            .navigationTitle(session.programName ?? "Lift")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Minimize") { dismiss() }.disabled(saving || completedReceipt != nil) }
                ToolbarItem(placement: .confirmationAction) {
                    if completedReceipt != nil {
                        Button("Done") { session.finishedSaving(); dismiss() }
                    } else {
                        Button("Finish") { confirmFinish = true }.disabled(saving || session.engine?.sets.isEmpty != false)
                    }
                }
            }
            .confirmationDialog("Save completed sets?", isPresented: $confirmFinish, titleVisibility: .visible) {
                Button("Save session") { Task { await save() } }
            } message: { Text("Only sets you completed will be saved. Unstarted sets stay out of your history.") }
            .confirmationDialog("Discard this session?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { session.discard(); dismiss() }
            } message: { Text("This removes the active session and its unsaved sets.") }
            .interactiveDismissDisabled(saving || completedReceipt != nil)
        }
        .sheet(item: $exerciseDetail) { target in
            NavigationStack { LiftExerciseDetailView(name: target.name, owner: session.deviceId ?? repo.deviceId) }
        }
        .sheet(isPresented: $showReceipt) {
            NavigationStack { LiftLiveReceiptView() }
        }
        .task { await loadLastSession() }
    }

    private func controls(_ engine: LiftSessionEngine) -> some View {
        VStack(spacing: 10) {
            if let remaining = engine.restRemaining(now: session.now) {
                HStack {
                    Text("REST").font(.caption.weight(.semibold))
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { tick in
                        Text(LiftFormat.duration(engine.restRemaining(now: Int(tick.date.timeIntervalSince1970)) ?? remaining)).font(.title2.monospacedDigit())
                    }
                }
            }
            HStack(spacing: 12) {
                Button("Undo", systemImage: "arrow.uturn.backward") { session.undo() }
                    .buttonStyle(.bordered).disabled(!engine.canUndo || saving)
                Spacer()
                Text("Double-tap your strap to advance")
                    .font(.caption).foregroundStyle(StrandPalette.textSecondary)
            }
        }.padding(16).background(StrandPalette.surfaceBase)
    }
    private func queue(_ engine: LiftSessionEngine, printed: Bool) -> some View {
        let indices = engine.plan.indices.filter { index in
            index != selectedExercise && engine.slots(forExercise: index).allSatisfy { engine.isCompleted($0) } == printed
        }
        return VStack(alignment: .leading, spacing: 12) {
            if !indices.isEmpty {
                Text(printed ? "PRINTED" : "UP NEXT").font(.caption.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary)
                ForEach(indices, id: \.self) { index in
                    Button { selectedExercise = index } label: {
                        HStack(spacing: 14) {
                            NoopLiftExerciseArtwork(name: engine.plan[index].exercise, size: 48)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(engine.plan[index].exercise).font(.headline)
                                Text(printed ? "Added to receipt" : "\(engine.plan[index].targetSets) sets · Tap to compose")
                                    .font(.caption).foregroundStyle(StrandPalette.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption)
                        }.frame(minHeight: 56).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }
    private func loadLastSession() async {
        defer { loadingPrevious = false }
        guard let engine = session.engine, let owner = session.deviceId,
              let store = await repo.storeHandle() else { return }
        do {
            var values: [String: [Int: LiftSetCarry]] = [:]
            var history: [String: [LiftSetRow]] = [:]
            for exercise in Set(engine.plan.map(\.exercise)) {
                let rows = try await store.lastLiftSets(deviceId: owner, exercise: exercise, before: engine.startTs)
                history[exercise] = rows
                values[exercise] = Dictionary(rows.filter { !$0.isWarmup }.map { ($0.setIndex, LiftSetCarry(weightKg: $0.weightKg, reps: $0.reps)) }, uniquingKeysWith: { _, last in last })
            }
            guard !Task.isCancelled, session.engine?.startTs == engine.startTs else { return }
            previousSets = history
            session.setLastSession(values)
        } catch { self.error = "Previous sets couldn’t load. You can still log this session." }
    }
    private func save() async {
        guard !saving, let owner = session.deviceId, let sessionID = session.sessionId,
              let store = await repo.storeHandle() else {
            error = "Your log is unavailable. Your session is still saved on this device."; return
        }
        saving = true; defer { saving = false }
        session.finish()
        guard let engine = session.engine, !engine.sets.isEmpty else { return }
        let end = engine.stageStartedAt
        let row = LiftSessionRow(id: sessionID, deviceId: owner, startTs: engine.startTs, endTs: end,
                                 sport: "Strength Training", programId: session.programId,
                                 programName: session.programName, sessionRpe: nil, note: nil)
        let sets = engine.sets.enumerated().map { index, set in
            let item = engine.planItem(for: set.slot)
            return LiftSetRow(id: "\(sessionID)-\(set.exerciseIndex)-\(set.setIndex)", deviceId: owner,
                sessionId: sessionID, ord: index, exercise: item?.exercise ?? "Exercise",
                primaryMuscle: item?.primaryMuscle, secondaryMuscles: item?.secondaryMuscles ?? [],
                setIndex: set.setIndex, weightKg: set.weightKg, reps: set.reps, rpe: set.rpe,
                isWarmup: set.isWarmup, startTs: set.startTs, endTs: set.endTs, restSec: set.restSec, note: nil)
        }
        let workout = WorkoutRow(startTs: engine.startTs, endTs: end, sport: "Strength Training",
            source: "manual", durationS: Double(max(0, end - engine.startTs)), energyKcal: nil,
            avgHr: nil, maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil,
            notes: session.programName)
        do {
            try await store.saveLiftSession(session: row, sets: sets, workout: workout)
            completedReceipt = sets.enumerated().map { index, set in
                LiftReceiptLine(id: set.id, ordinal: set.setIndex, exercise: set.exercise,
                                weightKg: set.weightKg, reps: set.reps, isWarmup: set.isWarmup)
            }
            if repo.deviceId == owner {
                _ = await model.intelligence.analyzeRecent(maxDays: 1, startOffset: 0, refreshRepository: true)
            }
            _ = await repo.refresh(.currentDay)
        } catch { self.error = "Couldn’t save. Your session is retained; tap Finish to retry. \(error.localizedDescription)" }
    }
}

/// Valid drafts persist without creating completed sets; only Log Set records a set.
private struct LiftSetComposer: View {
    @EnvironmentObject private var session: LiftSessionController
    let slot: LiftSlot
    let system: UnitSystem
    @State private var weight = ""
    @State private var reps = ""
    @State private var loaded = false
    @State private var warmup = false
    @State private var effort: Double?
    private var valid: Bool {
        guard let load = LiftFormat.number(weight), let count = Int(reps) else { return false }
        return load.isFinite && (0...1000).contains(load) && (1...1000).contains(count)
    }
    var body: some View {
        VStack(spacing: 12) {
        LiftComposerContent(setIndex: slot.setIndex, weight: $weight, reps: $reps,
                            unit: LiftFormat.weightUnit(system), canLog: valid && session.engine?.isFinished != true,
                            setKind: warmup ? "Warm-up" : "Working set") {
            guard valid, let load = LiftFormat.number(weight), let count = Int(reps) else { return }
            session.updateSet(slot, weightKg: LiftFormat.kilograms(fromDisplay: load, system: system),
                              reps: count, rpe: effort, isWarmup: warmup)
            session.setWarmup(slot, warmup)
            if session.engine?.currentSlot != slot || !isWorking { session.start(slot) }
            session.advance()
        }
        HStack {
            Toggle("Warm-up", isOn: $warmup).font(.caption)
            Spacer(minLength: 20)
            Picker("Effort", selection: $effort) {
                Text("RPE —").tag(Double?.none)
                ForEach(1...10, id: \.self) { Text("RPE \($0)").tag(Optional(Double($0))) }
            }.pickerStyle(.menu).accessibilityLabel("Set effort, RPE")
        }.disabled(session.engine?.isFinished == true)
        }
        .onAppear {
            let carry = session.carry(for: slot)
            let entered = session.enteredValues(for: slot)
            weight = (entered.weightKg ?? carry.weightKg).map { LiftFormat.trim(LiftFormat.display(fromKilograms: $0, system: system)) } ?? "0"
            reps = (entered.reps ?? carry.reps).map(String.init) ?? "8"
            effort = entered.rpe
            warmup = session.isWarmup(slot)
            loaded = true
        }
        .onChange(of: effort) { _, _ in preserveDraft() }
        .onChange(of: warmup) { _, value in if loaded { session.setWarmup(slot, value) } }
        .onChange(of: weight) { _, _ in preserveDraft() }
        .onChange(of: reps) { _, _ in preserveDraft() }
    }
    private func preserveDraft() {
        guard loaded, valid, let load = LiftFormat.number(weight), let count = Int(reps),
              session.engine?.isCompleted(slot) == false else { return }
        let kg = LiftFormat.kilograms(fromDisplay: load, system: system)
        let existing = session.enteredValues(for: slot)
        guard existing.weightKg != kg || existing.reps != count || existing.rpe != effort else { return }
        session.updateSet(slot, weightKg: kg, reps: count, rpe: effort, isWarmup: warmup)
    }
    private var isWorking: Bool {
        if case .working = session.engine?.stage { return true }
        return false
    }
}

struct LiftLiveReceiptView: View {
    @State private var detail: LiftExerciseDetailTarget?
    @EnvironmentObject private var session: LiftSessionController
    @Environment(\.dismiss) private var dismiss
    @AppStorage(UnitPrefs.systemKey) private var systemRaw = UnitSystem.metric.rawValue
    var body: some View {
        ScrollView {
            if let engine = session.engine {
                LiftReceiptContent(title: session.programName ?? "Lift", subtitle: "LIVE RECEIPT",
                    lines: engine.sets.enumerated().map { index, set in
                        LiftReceiptLine(id: "\(set.exerciseIndex)-\(set.setIndex)", ordinal: set.setIndex,
                            exercise: engine.planItem(for: set.slot)?.exercise ?? "Exercise",
                            weightKg: set.weightKg, reps: set.reps, isWarmup: set.isWarmup)
                    }, system: UnitSystem(rawValue: systemRaw) ?? .metric, openExercise: { detail = .init(name: $0) })
                    .padding(20)
            }
        }.sheet(item: $detail) { target in
            NavigationStack { LiftExerciseDetailView(name: target.name, owner: session.deviceId ?? "") }
        }.background(StrandPalette.appCanvas).navigationTitle("Receipt").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}
