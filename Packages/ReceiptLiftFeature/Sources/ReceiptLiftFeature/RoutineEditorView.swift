import SwiftUI

struct RoutineEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @EnvironmentObject private var store: LiftStore
  @State private var draft: RoutineDraft
  @State private var editingPlanID: UUID?
  @State private var showsExercisePicker = false

  init(routine: LiftRoutine?) {
    _draft = State(initialValue: RoutineDraft(routine: routine))
  }

  var body: some View {
    NavigationStack {
      List {
        Section("Routine") {
          editorField("Name", text: $draft.name, prompt: "Upper A")
          editorField("Notes", text: $draft.notes, prompt: "Training notes", axis: .vertical)
          Picker("Training Mode", selection: $draft.trainingMode) {
            ForEach(TrainingMode.allCases) { mode in
              Text(mode.title).tag(mode)
            }
          }
          .pickerStyle(.segmented)
        }

        Section("Order") {
          if draft.plans.isEmpty {
            Text("NO EXERCISES YET")
              .font(.receipt(11, weight: .bold))
              .foregroundStyle(LiftTheme.inkSecondary)
          }
          ForEach(draft.plans) { plan in
            Button {
              editingPlanID = plan.id
            } label: {
              planRow(plan)
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .accessibilityHint("Edits sets, reps, rest, effort, and notes")
          }
          .onDelete { draft.plans.remove(atOffsets: $0) }
          .onMove { source, destination in
            withAnimation(reduceMotion ? LiftMotion.reducedCrossfade : LiftMotion.surface) {
              draft.plans.move(fromOffsets: source, toOffset: destination)
            }
          }

          Button {
            showsExercisePicker = true
          } label: {
            Label("ADD EXERCISE", systemImage: "plus")
              .font(.receipt(12, weight: .black))
              .frame(maxWidth: .infinity, minHeight: 44)
          }
          .accessibilityHint("Opens the contextual exercise picker")
        }
      }
      .scrollContentBackground(.hidden)
      .background(LiftTheme.paper)
      .navigationTitle(draft.id == nil ? "CREATE ROUTINE" : "EDIT ROUTINE")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          EditButton()
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save", action: save)
            .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
    .sheet(isPresented: $showsExercisePicker) {
      NavigationStack {
        ExerciseLibraryView { exercise in
          add(exercise)
          showsExercisePicker = false
        }
        .environmentObject(store)
        .navigationTitle("ADD EXERCISE")
        .navigationBarTitleDisplayMode(.inline)
      }
      .presentationDragIndicator(.visible)
    }
    .sheet(item: editingPlanBinding) { plan in
      RoutinePlanEditor(plan: plan) { edited in
        guard let index = draft.plans.firstIndex(where: { $0.id == edited.id }) else { return }
        draft.plans[index] = edited
      }
    }
  }

  private func editorField(
    _ label: String,
    text: Binding<String>,
    prompt: String,
    axis: Axis = .horizontal
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(label.uppercased())
        .font(.receipt(9, weight: .black))
        .foregroundStyle(LiftTheme.inkSecondary)
      TextField(prompt, text: text, axis: axis)
        .font(.receipt(13, weight: .bold))
        .textInputAutocapitalization(.sentences)
        .frame(minHeight: 44)
    }
  }

  private func planRow(_ plan: RoutinePlanDraft) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "line.3.horizontal")
        .foregroundStyle(LiftTheme.inkSecondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        Text(store.exerciseName(for: plan.exerciseID).uppercased())
          .font(.receipt(12, weight: .black))
          .foregroundStyle(LiftTheme.ink)
        Text("\(plan.sets) × \(plan.reps) / \(plan.rest) / \(plan.targetEffort)".uppercased())
          .font(.receipt(9, weight: .bold))
          .foregroundStyle(LiftTheme.inkSecondary)
      }
      Spacer(minLength: 8)
      Image(systemName: "chevron.right")
        .foregroundStyle(LiftTheme.inkSecondary)
        .accessibilityHidden(true)
    }
    .accessibilityElement(children: .combine)
  }

  private var editingPlanBinding: Binding<RoutinePlanDraft?> {
    Binding(
      get: {
        guard let editingPlanID else { return nil }
        return draft.plans.first { $0.id == editingPlanID }
      },
      set: { editingPlanID = $0?.id }
    )
  }

  private func add(_ exercise: LiftExercise) {
    guard !draft.plans.contains(where: { $0.exerciseID == exercise.id }) else { return }
    withAnimation(reduceMotion ? LiftMotion.reducedCrossfade : LiftMotion.surface) {
      draft.plans.append(RoutinePlanDraft(exerciseID: exercise.id))
    }
  }

  private func save() {
    let plans = draft.plans.map(\.plan)
    if let id = draft.id {
      store.updateRoutine(
        LiftRoutine(
          id: id,
          name: draft.name,
          notes: draft.notes,
          trainingMode: draft.trainingMode,
          exerciseIDs: plans.map(\.exerciseID),
          exercisePlans: plans
        )
      )
    } else {
      store.createRoutine(
        name: draft.name,
        notes: draft.notes,
        trainingMode: draft.trainingMode,
        plans: plans
      )
    }
    dismiss()
  }
}

private struct RoutineDraft: Equatable {
  var id: UUID?
  var name: String
  var notes: String
  var trainingMode: TrainingMode
  var plans: [RoutinePlanDraft]

  init(routine: LiftRoutine?) {
    id = routine?.id
    name = routine?.name ?? ""
    notes = routine?.notes ?? ""
    trainingMode = routine?.trainingMode ?? .hypertrophy
    if let storedPlans = routine?.exercisePlans {
      plans = storedPlans.map(RoutinePlanDraft.init)
    } else {
      var seen = Set<UUID>()
      plans = (routine?.exerciseIDs ?? []).compactMap { exerciseID in
        guard seen.insert(exerciseID).inserted else { return nil }
        return RoutinePlanDraft(exerciseID: exerciseID)
      }
    }
  }
}

private struct RoutinePlanDraft: Identifiable, Equatable {
  var id: UUID
  var exerciseID: UUID
  var sets: String
  var reps: String
  var rest: String
  var targetEffort: String
  var notes: String

  init(exerciseID: UUID) {
    id = UUID()
    self.exerciseID = exerciseID
    sets = "3"
    reps = "8-12"
    rest = "90 s"
    targetEffort = "2 RIR"
    notes = ""
  }

  init(_ plan: LiftRoutineExercisePlan) {
    id = plan.id
    exerciseID = plan.exerciseID
    sets = plan.sets
    reps = plan.reps
    rest = plan.rest
    targetEffort = plan.targetEffort
    notes = plan.notes
  }

  var plan: LiftRoutineExercisePlan {
    LiftRoutineExercisePlan(
      id: id, exerciseID: exerciseID, sets: sets, reps: reps, rest: rest,
      targetEffort: targetEffort, notes: notes
    )
  }
}

private struct RoutinePlanEditor: View {
  @Environment(\.dismiss) private var dismiss
  @State private var draft: RoutinePlanDraft
  let onSave: (RoutinePlanDraft) -> Void

  init(plan: RoutinePlanDraft, onSave: @escaping (RoutinePlanDraft) -> Void) {
    _draft = State(initialValue: plan)
    self.onSave = onSave
  }

  var body: some View {
    NavigationStack {
      Form {
        TextField("Sets", text: $draft.sets)
        TextField("Reps", text: $draft.reps)
        TextField("Rest", text: $draft.rest)
        TextField("Target effort", text: $draft.targetEffort)
        TextField("Notes", text: $draft.notes, axis: .vertical)
      }
      .font(.receipt(13, weight: .bold))
      .navigationTitle("PLAN DETAILS")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            onSave(draft)
            dismiss()
          }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }
}
