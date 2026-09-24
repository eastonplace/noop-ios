import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Reads only on source changes or completed saves. The ticking session is observed by a small child.
struct LiftLogView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: LiftSessionController
    @Environment(\.dismiss) private var dismiss
    @State private var programs: [LiftProgramRow] = []
    @State private var history: [LiftSessionRow] = []
    @State private var loading = true
    @State private var error: String?
    @State private var editor: LiftProgramTarget?
    @State private var detail: LiftHistoryTarget?
    @State private var preview: LiftProgramPreviewTarget?
    @State private var starting = false
    @State private var queuedStart: LiftProgramPreviewTarget?

    var body: some View {
        ScreenScaffold(title: "Lift", subtitle: "A plan for today. Progress you can see.",
                       onRefresh: { await load() }, lazy: true, backAction: { dismiss() }) {
            LiftResumeCard()
            if !history.isEmpty {
                let week = Calendar.current.dateInterval(of: .weekOfYear, for: Date())
                let recent = history.filter { row in week?.contains(Date(timeIntervalSince1970: Double(row.startTs))) == true }
                NoopCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("THIS WEEK").font(.caption.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary)
                            Text("\(recent.count) sessions").font(StrandFont.title2)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            Text("TRAINING TIME").font(.caption.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary)
                            Text("\(recent.reduce(0) { $0 + max(0, ($1.endTs ?? $1.startTs) - $1.startTs) } / 60) min").font(StrandFont.title2)
                        }
                    }
                }
            }
            HStack {
                Text("YOUR PROGRAMS").font(.caption.weight(.semibold))
                Spacer()
                Button("New program", systemImage: "plus") { editor = .init(program: nil) }
                    .buttonStyle(.bordered)
            }
            if loading { ProgressView("Loading your log…") }
            if let error {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).foregroundStyle(StrandPalette.statusCritical)
                    Button("Try again") { Task { await load() } }
                }
            }
            if !loading && programs.isEmpty {
                NoopCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "dumbbell.fill").font(.largeTitle)
                        Text("Make your first session yours.").font(StrandFont.title2)
                        Text("Choose your exercises, sets and rest. Log weight and reps as you train.")
                            .foregroundStyle(StrandPalette.textSecondary)
                        Button("Create program") { editor = .init(program: nil) }.buttonStyle(.noopPrimary)
                    }
                }
            }
            ForEach(programs, id: \.id) { program in
                LiftProgramCard(program: program,
                    canStart: session.engine == nil && model.activeWorkout == nil && !starting,
                    edit: { editor = .init(program: program) },
                    preview: { Task { await prepare(program) } })
            }
            Text("RECENT SESSIONS").font(.caption.weight(.semibold))
            if !loading && history.isEmpty {
                Text("Completed sessions will appear here.").foregroundStyle(StrandPalette.textSecondary)
            }
            ForEach(history, id: \.id) { row in
                Button { detail = .init(row: row) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(row.programName ?? "Strength training").font(.headline)
                            Text(Date(timeIntervalSince1970: Double(row.startTs)), style: .date)
                                .font(.caption).foregroundStyle(StrandPalette.textSecondary)
                        }
                        Spacer()
                        Text(LiftFormat.duration(max(0, (row.endTs ?? row.startTs) - row.startTs)))
                            .monospacedDigit()
                        Image(systemName: "chevron.right")
                    }.padding(.vertical, 12)
                }.buttonStyle(.plain)
            }
        }
        .task(id: "\(repo.deviceId)-\(repo.refreshSeq)-\(session.savedSessions)") { await load() }
        .sheet(item: $preview, onDismiss: beginQueuedSession) { target in
            NavigationStack {
                LiftProgramPreview(program: target.program, plan: target.plan) {
                    guard session.engine == nil, model.activeWorkout == nil, target.program.deviceId == repo.deviceId else { return }
                    queuedStart = target
                    preview = nil
                }
            }
        }
        .sheet(isPresented: $session.isPresented) { LiftActiveSessionView() }
        .sheet(item: $editor) { target in
            NavigationStack { LiftProgramEditor(program: target.program) { await load() } }
        }
        .sheet(item: $detail) { target in
            NavigationStack { LiftHistoryView(row: target.row) }
        }
    }

    private func beginQueuedSession() {
        guard let target = queuedStart else { return }
        queuedStart = nil
        guard session.engine == nil, model.activeWorkout == nil, target.program.deviceId == repo.deviceId else { return }
        session.start(plan: target.plan, programId: target.program.id,
                      programName: target.program.name, deviceId: target.program.deviceId)
    }

    private func load() async {
        let owner = repo.deviceId
        guard let store = await repo.storeHandle() else { error = "Your log is unavailable. Try again."; loading = false; return }
        do {
            let plans = try await store.liftPrograms(deviceId: owner)
            let now = Int(Date().timeIntervalSince1970)
            let rows = try await store.liftSessions(deviceId: owner, fromTs: now - 365 * 86400, toTs: now + 1)
            guard !Task.isCancelled, owner == repo.deviceId else { return }
            programs = plans
            history = rows.filter { $0.endTs != nil }.sorted { $0.startTs > $1.startTs }
            error = nil
        } catch { self.error = "Couldn’t load your log: \(error.localizedDescription)" }
        loading = false
    }

    private func prepare(_ program: LiftProgramRow) async {
        guard session.engine == nil, model.activeWorkout == nil, !starting, let store = await repo.storeHandle() else { return }
        starting = true; defer { starting = false }
        do {
            let rows = try await store.liftProgramItems(programId: program.id)
            guard session.engine == nil, model.activeWorkout == nil, program.deviceId == repo.deviceId else { return }
            guard !rows.isEmpty else { editor = .init(program: program); return }
            let plan = rows.map { LiftPlanItem(exercise: $0.exercise, targetSets: $0.targetSets,
                restSec: $0.restSec, targetRepsLow: $0.targetRepsLow, targetRepsHigh: $0.targetRepsHigh,
                targetRpe: $0.targetRpe, targetWeightKg: $0.targetWeightKg, note: $0.note, programItemId: $0.id) }
            preview = .init(program: program, plan: plan)
        } catch { self.error = "Couldn’t start: \(error.localizedDescription)" }
    }
}

private struct LiftProgramTarget: Identifiable {
    let id = UUID()
    let program: LiftProgramRow?
}
private struct LiftHistoryTarget: Identifiable {
    var id: String { row.id }
    let row: LiftSessionRow
}

/// This leaf alone observes the live timer; the log's database reads remain task-driven.
struct LiftResumeCard: View {
    @State private var showSession = false
    @EnvironmentObject private var session: LiftSessionController
    var body: some View {
        if let engine = session.engine {
            Button { showSession = true } label: {
                HStack {
                    Image(systemName: "dumbbell.fill")
                    VStack(alignment: .leading) {
                        Text(session.programName ?? "Your session").font(.headline)
                        Text("\(engine.completedWorkingSets) sets logged · Resume").font(.caption)
                    }
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { tick in
                        Text(LiftFormat.duration(max(0, Int(tick.date.timeIntervalSince1970) - engine.startTs))).monospacedDigit()
                    }
                }.padding(16).background(StrandPalette.inset, in: RoundedRectangle(cornerRadius: 16))
            }.buttonStyle(.plain).accessibilityHint("Open your active lifting session")
                .sheet(isPresented: $showSession) { LiftActiveSessionView() }
        }
    }
}

private struct LiftExerciseDraft: Identifiable {
    var id: String = UUID().uuidString
    var name = ""
    var sets = 3
    var reps = 8
    var rest = 120
}

private struct LiftProgramEditor: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    let program: LiftProgramRow?
    let saved: () async -> Void
    @State private var name = ""
    @State private var exercises = [LiftExerciseDraft()]
    @State private var busy = false
    @State private var error: String?
    @State private var programID = UUID().uuidString
    @State private var owner = ""
    @State private var originals: [String: LiftProgramItemRow] = [:]
    @State private var discard = false
    @State private var showLibrary = false
    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !exercises.isEmpty
            && exercises.allSatisfy { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    var body: some View {
        Form {
            Section("Program") { TextField("Upper body, Lower body…", text: $name) }
            ForEach($exercises) { $exercise in
                Section {
                    HStack(spacing: 12) {
                        NoopLiftExerciseArtwork(name: exercise.name, size: 56)
                        TextField("Exercise", text: $exercise.name)
                    }
                    Stepper("\(exercise.sets) sets", value: $exercise.sets, in: 1...20)
                    Stepper("\(exercise.reps) reps", value: $exercise.reps, in: 1...100)
                    Stepper("\(exercise.rest) seconds rest", value: $exercise.rest, in: 0...600, step: 15)
                    Button("Remove exercise", role: .destructive) { exercises.removeAll { $0.id == exercise.id } }
                }
            }
            Button("Add from exercise library", systemImage: "plus") { showLibrary = true }.disabled(exercises.count >= 30)
            if let error { Text(error).foregroundStyle(.red) }
        }
        .sheet(isPresented: $showLibrary) {
            NavigationStack {
                LiftExerciseLibraryView { name in
                    if exercises.count == 1 && exercises[0].name.isEmpty { exercises[0].name = name }
                    else { exercises.append(.init(name: name)) }
                }
            }
        }
        .navigationTitle(program == nil ? "New program" : "Edit program")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { discard = true }.disabled(busy) }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(!valid || busy) }
        }
        .interactiveDismissDisabled()
        .confirmationDialog("Discard changes?", isPresented: $discard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { dismiss() }
        }
        .task {
            owner = program?.deviceId ?? repo.deviceId
            guard let program else { return }
            name = program.name; programID = program.id; busy = true
            defer { busy = false }
            do {
                guard let store = await repo.storeHandle() else { return }
                let stored = try await store.liftProgramItems(programId: program.id)
                originals = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                exercises = stored.map {
                    LiftExerciseDraft(id: $0.id, name: $0.exercise, sets: max(1, $0.targetSets ?? 3),
                                      reps: max(1, $0.targetRepsLow ?? 8), rest: max(0, $0.restSec ?? 120))
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func save() async {
        guard valid, !busy, !owner.isEmpty, let store = await repo.storeHandle() else { return }
        busy = true; defer { busy = false }
        let now = Int(Date().timeIntervalSince1970)
        let row = LiftProgramRow(id: programID, deviceId: owner, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                 note: program?.note, createdAt: program?.createdAt ?? now, updatedAt: now, archived: false)
        let items = exercises.enumerated().map { index, item in
            let original = originals[item.id]
            return LiftProgramItemRow(id: item.id, deviceId: owner, programId: programID, ord: index,
                exercise: item.name.trimmingCharacters(in: .whitespacesAndNewlines), targetSets: item.sets,
                targetRepsLow: item.reps, targetRepsHigh: original?.targetRepsLow == item.reps ? original?.targetRepsHigh : item.reps,
                targetRpe: original?.targetRpe, targetWeightKg: original?.targetWeightKg,
                restSec: item.rest, note: original?.note)
        }
        do {
            try await store.saveLiftProgram(program: row, items: items)
            await saved(); dismiss()
        } catch { self.error = "Couldn’t save. Your changes are still here. \(error.localizedDescription)" }
    }
}

private struct LiftHistoryView: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    let row: LiftSessionRow
    @State private var sets: [LiftSetRow] = []
    @State private var detail: LiftExerciseDetailTarget?
    @State private var error: String?
    @AppStorage(UnitPrefs.systemKey) private var systemRaw = UnitSystem.metric.rawValue
    private var system: UnitSystem { UnitSystem(rawValue: systemRaw) ?? .metric }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LiftReceiptContent(title: row.programName ?? "Strength training", subtitle: "COMPLETED RECEIPT",
                    lines: sets.enumerated().map { index, set in
                        LiftReceiptLine(id: set.id, ordinal: set.setIndex, exercise: set.exercise,
                                        weightKg: set.weightKg, reps: set.reps, isWarmup: set.isWarmup)
                    }, system: system, openExercise: { detail = .init(name: $0) })
                Text(Date(timeIntervalSince1970: Double(row.startTs)), style: .date)
                Text(LiftFormat.duration(max(0, (row.endTs ?? row.startTs) - row.startTs)))
                if let error { Text(error).foregroundStyle(.red) }
            }.padding(20)
        }.background(StrandPalette.appCanvas)
        .sheet(item: $detail) { target in
            NavigationStack { LiftExerciseDetailView(name: target.name, owner: row.deviceId) }
        }
        .navigationTitle(row.programName ?? "Session")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task {
            do { if let store = await repo.storeHandle() { sets = try await store.liftSets(sessionId: row.id) } }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct LiftProgramPreviewTarget: Identifiable {
    var id: String { program.id }
    let program: LiftProgramRow
    let plan: [LiftPlanItem]
}

private struct LiftProgramPreview: View {
    @EnvironmentObject private var repo: Repository
    @State private var detail: LiftExerciseDetailTarget?
    @Environment(\.dismiss) private var dismiss
    let program: LiftProgramRow
    let plan: [LiftPlanItem]
    let begin: () -> Void
    var body: some View {
        ScrollView {
            LiftRoutinePreviewContent(title: program.name, exercises: plan.map {
                .init(name: $0.exercise, sets: $0.targetSets, reps: $0.targetRepsLow, restSeconds: $0.restSec)
            }, openExercise: { detail = .init(name: $0) }).padding(20)
        }.background(StrandPalette.appCanvas)
            .sheet(item: $detail) { target in
                NavigationStack { LiftExerciseDetailView(name: target.name, owner: repo.deviceId) }
            }
            .navigationTitle("Your session").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                Button("Begin workout", systemImage: "play.fill", action: begin)
                    .buttonStyle(.noopPrimary).padding(20).background(StrandPalette.surfaceBase)
            }
    }
}

private struct LiftProgramCard: View {
    @EnvironmentObject private var repo: Repository
    let program: LiftProgramRow
    let canStart: Bool
    let edit: () -> Void
    let preview: () -> Void
    @State private var items: [LiftProgramItemRow] = []
    @State private var error: String?
    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(program.name).font(StrandFont.title2)
                        if !items.isEmpty {
                            Text("\(items.count) exercises · \(items.reduce(0) { $0 + ($1.targetSets ?? 1) }) sets")
                                .font(.subheadline).foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    Spacer()
                    Button(action: edit) { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                        .accessibilityLabel("Edit \(program.name)")
                }
                if !items.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(Array(items.prefix(4)), id: \.id) { item in
                            NoopLiftExerciseArtwork(name: item.exercise, size: 56)
                        }
                        Spacer(minLength: 0)
                    }
                    Text(items.prefix(3).map(\.exercise).joined(separator: " · "))
                        .font(.caption).foregroundStyle(StrandPalette.textSecondary).lineLimit(2)
                }
                if let note = program.note, !note.isEmpty { Text(note).font(.subheadline).foregroundStyle(StrandPalette.textSecondary) }
                if let error { Text(error).font(.caption).foregroundStyle(StrandPalette.statusCritical) }
                Button("Preview workout", systemImage: "arrow.right", action: preview)
                    .buttonStyle(.noopPrimary).disabled(!canStart)
            }
        }
        .task(id: "\(program.id)|\(program.updatedAt)") {
            do {
                guard let store = await repo.storeHandle() else { return }
                let fetched = try await store.liftProgramItems(programId: program.id)
                guard !Task.isCancelled else { return }
                items = fetched
            } catch { self.error = "Exercise preview couldn’t load." }
        }
    }
}
