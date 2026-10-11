import StrandDesign
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

  private var canSave: Bool { !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  var body: some View {
    LiftSheetPage(
      title: draft.id == nil ? "Create routine" : "Edit routine",
      onClose: { dismiss() },
      content: {
        routineSection
        FlatSectionSeparator()
        exercisesSection
      },
      footer: {
        Button(action: save) { Text("Save").liftPillLabel() }
          .buttonStyle(PrimaryPillButtonStyle())
          .disabled(!canSave)
      }
    )
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
    .sheet(isPresented: $showsExercisePicker) {
      NavigationStack {
        ExerciseLibraryView { exercise in
          add(exercise)
          showsExercisePicker = false
        }
        .environmentObject(store)
      }
      .presentationDragIndicator(.visible)
    }
    .sheet(item: editingPlanBinding) { plan in
      RoutinePlanEditor(plan: plan, exerciseName: store.exerciseName(for: plan.exerciseID).liftDisplayName) { edited in
        guard let index = draft.plans.firstIndex(where: { $0.id == edited.id }) else { return }
        draft.plans[index] = edited
      }
    }
  }

  // MARK: Routine

  private var routineSection: some View {
    LiftFlatSection("Routine", systemImage: "list.bullet.rectangle") {
      VStack(alignment: .leading, spacing: NoopMetrics.space4) {
        LiftField(title: "Name", text: $draft.name, placeholder: "Upper A", capitalization: .words)
        LiftField(
          title: "Notes", text: $draft.notes, placeholder: "Training notes", axis: .vertical,
          capitalization: .sentences)
        VStack(alignment: .leading, spacing: 6) {
          Text("Training mode")
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
          SegmentedPillControl(TrainingMode.allCases, selection: $draft.trainingMode) { $0.title }
        }
      }
    }
  }

  // MARK: Exercises

  private var exercisesSection: some View {
    LiftFlatSection(
      "Exercises", trailing: draft.plans.isEmpty ? .none : .text(LiftFormat.exerciseCount(draft.plans.count)),
      contentSpacing: 0
    ) {
      if draft.plans.isEmpty {
        LiftNote(text: "No exercises yet").padding(.vertical, NoopMetrics.space2)
      } else {
        LiftRowList(items: draft.plans, separatorInset: 44 + NoopMetrics.space3) { plan, index in
          planRow(plan, index: index)
        }
      }
      ChipRow {
        WidgetChipButton(
          title: "Add exercise", systemImage: "plus", accessibilityLabel: "Add exercise",
          accessibilityHint: "Opens the contextual exercise picker"
        ) { showsExercisePicker = true }
      }
      .padding(.top, NoopMetrics.space3)
    }
  }

  private func planRow(_ plan: RoutinePlanDraft, index: Int) -> some View {
    let name = store.exerciseName(for: plan.exerciseID).liftDisplayName
    let prescription = LiftFormat.facts([
      String(localized: "\(plan.sets) × \(plan.reps)"), plan.rest, plan.targetEffort,
    ])
    return HStack(spacing: 0) {
      Button { editingPlanID = plan.id } label: {
        LiftListRow(
          title: name,
          details: [prescription],
          leading: { LiftExerciseThumb(exercise: store.exercise(for: plan.exerciseID), size: 44) }
        )
      }
      .buttonStyle(FlatRowPressStyle())
      .accessibilityElement(children: .combine)
      .accessibilityHint("Edits sets, reps, rest, effort, and notes")
      LiftRowMenu(label: "Exercise actions") {
        Button("Edit details", systemImage: "slider.horizontal.3") { editingPlanID = plan.id }
        Button("Move up", systemImage: "arrow.up") { move(plan.id, by: -1) }
          .disabled(index == 0)
        Button("Move down", systemImage: "arrow.down") { move(plan.id, by: 1) }
          .disabled(index == draft.plans.count - 1)
        Button("Remove", systemImage: "trash", role: .destructive) { remove(plan.id) }
      }
    }
    .draggable(plan.id.uuidString)
    .dropDestination(for: String.self) { items, _ in
      guard let raw = items.first, let dragged = UUID(uuidString: raw) else { return false }
      move(dragged, before: plan.id)
      return true
    }
    .accessibilityAction(named: Text("Move up")) { move(plan.id, by: -1) }
    .accessibilityAction(named: Text("Move down")) { move(plan.id, by: 1) }
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

  private var reorderAnimation: Animation {
    reduceMotion ? LiftMotion.reducedCrossfade : LiftMotion.surface
  }

  private func add(_ exercise: LiftExercise) {
    guard !draft.plans.contains(where: { $0.exerciseID == exercise.id }) else { return }
    withAnimation(reorderAnimation) {
      draft.plans.append(RoutinePlanDraft(exerciseID: exercise.id))
    }
  }

  private func remove(_ id: UUID) {
    withAnimation(reorderAnimation) { draft.plans.removeAll { $0.id == id } }
  }

  private func move(_ id: UUID, by offset: Int) {
    guard let index = draft.plans.firstIndex(where: { $0.id == id }) else { return }
    let target = index + offset
    guard draft.plans.indices.contains(target) else { return }
    withAnimation(reorderAnimation) {
      draft.plans.move(fromOffsets: [index], toOffset: offset > 0 ? target + 1 : target)
    }
  }

  /// Drops a dragged exercise where another sits: it takes that exercise's place and the rest make room.
  private func move(_ id: UUID, before targetID: UUID) {
    guard id != targetID,
      let from = draft.plans.firstIndex(where: { $0.id == id }),
      let to = draft.plans.firstIndex(where: { $0.id == targetID })
    else { return }
    withAnimation(reorderAnimation) {
      draft.plans.move(fromOffsets: [from], toOffset: from < to ? to + 1 : to)
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
  let exerciseName: String
  let onSave: (RoutinePlanDraft) -> Void

  init(plan: RoutinePlanDraft, exerciseName: String, onSave: @escaping (RoutinePlanDraft) -> Void) {
    _draft = State(initialValue: plan)
    self.exerciseName = exerciseName
    self.onSave = onSave
  }

  var body: some View {
    LiftSheetPage(
      title: "Plan details",
      onClose: { dismiss() },
      content: {
        LiftFlatSection("Prescription", systemImage: "slider.horizontal.3") {
          VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            Text(verbatim: exerciseName)
              .font(StrandFont.body.weight(.semibold))
              .foregroundStyle(StrandPalette.textPrimary)
              .fixedSize(horizontal: false, vertical: true)
            LiftField(title: "Sets", text: $draft.sets, placeholder: "3", capitalization: .never)
            LiftField(title: "Reps", text: $draft.reps, placeholder: "8-12", capitalization: .never)
            LiftField(title: "Rest", text: $draft.rest, placeholder: "90 s", capitalization: .never)
            LiftField(title: "Target effort", text: $draft.targetEffort, placeholder: "2 RIR", capitalization: .characters)
            LiftField(title: "Notes", text: $draft.notes, placeholder: "Notes", axis: .vertical, capitalization: .sentences)
          }
        }
      },
      footer: {
        Button {
          onSave(draft)
          dismiss()
        } label: {
          Text("Save").liftPillLabel()
        }
        .buttonStyle(PrimaryPillButtonStyle())
      }
    )
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
  }
}
