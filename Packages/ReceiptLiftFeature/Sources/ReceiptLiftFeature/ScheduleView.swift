import StrandDesign
import SwiftUI

struct ScheduleView: View {
  @EnvironmentObject private var store: LiftStore
  @Environment(\.liftHostChrome) private var host
  let onStartRoutine: (LiftRoutine) -> Void
  @State private var showsLibrary = false
  @State private var editorRoute: RoutineEditorRoute?
  @State private var scheduleRoute: ScheduleEditorRoute?
  @State private var pendingRoutineDeletion: LiftRoutine?
  @State private var selectedDay = Date()

  var body: some View {
    LiftScreen(
      title: "Schedule",
      subtitle: "Upcoming lifts and routines",
      backAction: host.onBack,
      trailing: {
        LiftHeaderTrailing {
          NoopIconButton("books.vertical", accessibilityLabel: "Exercise library") { showsLibrary = true }
          NoopIconButton("plus", accessibilityLabel: "Schedule workout") {
            scheduleRoute = .create(prefill: store.nextSuggestedRoutine?.id)
          }
        }
      }
    ) {
      ScheduleWeekStrip(
        sessions: store.sessions,
        selectedDay: $selectedDay
      )
      upcomingSection
      recentlyCompletedSection
      routineSection
      NoopButton("Create routine", systemImage: "plus", kind: .primary, fullWidth: true) {
        editorRoute = .create
      }
    }
    .liftQAScene("routine-editor") { editorRoute = .create }
    .liftQAScene("routine-edit") { editorRoute = store.routines.first.map { .edit($0) } }
    .liftQAScene("schedule-editor") { scheduleRoute = .create(prefill: store.nextSuggestedRoutine?.id) }
    .liftQAScene("library") { showsLibrary = true }
    .sheet(isPresented: $showsLibrary) {
      NavigationStack { ExerciseLibraryView() }
        .environmentObject(store)
        .presentationDragIndicator(.visible)
    }
    .sheet(item: $editorRoute) { route in
      RoutineEditorView(routine: route.routine)
        .environmentObject(store)
    }
    .sheet(item: $scheduleRoute) { route in
      ScheduleWorkoutEditor(route: route)
        .environmentObject(store)
    }
    .alert(
      "Delete \(pendingRoutineDeletion?.name ?? "Routine")?",
      isPresented: deletionPresentation
    ) {
      Button("Delete Routine", role: .destructive) {
        if let pendingRoutineDeletion {
          store.deleteRoutine(id: pendingRoutineDeletion.id)
        }
        pendingRoutineDeletion = nil
      }
      Button("Cancel", role: .cancel) { pendingRoutineDeletion = nil }
    } message: {
      Text("Incomplete scheduled workouts today or later will be removed. Printed history stays.")
    }
  }

  private var upcomingSection: some View {
    let upcoming = LiftScheduleWeek.upcoming(
      store.upcomingWorkouts,
      on: selectedDay,
      calendar: .current
    )
    return LiftSection(title: "Upcoming") {
      if upcoming.isEmpty {
        LiftEmptyNote(text: "Nothing scheduled for \(dayPhrase(selectedDay)). Pick a routine and schedule a date.")
      } else {
        ForEach(Array(upcoming.enumerated()), id: \.element.id) { index, workout in
          upcomingRow(workout, index: index)
        }
      }
    }
  }

  @ViewBuilder
  private var recentlyCompletedSection: some View {
    let recent = store.recentCompletedWorkouts
    if !recent.isEmpty {
      LiftSection(title: "Recently completed") {
        ForEach(Array(recent.enumerated()), id: \.element.id) { index, workout in
          let routine = store.routines.first { $0.id == workout.routineID }
          LiftRow(
            title: routine?.name ?? completedSessionTitle(for: workout) ?? "Unavailable routine",
            detail: dayLabel(workout.plannedAt),
            leading: { LiftRowIndex(index: index + 1) },
            trailing: {
              Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StrandPalette.success)
                .accessibilityHidden(true)
            }
          )
          .accessibilityElement(children: .combine)
          .accessibilityLabel("Completed \(routine?.name ?? "workout") on \(dayLabel(workout.plannedAt))")
        }
      }
    }
  }

  private var routineSection: some View {
    LiftSection(title: "Routines") {
      if store.routines.isEmpty {
        LiftEmptyNote(text: "No routines yet. Create one to start.")
      } else {
        ForEach(Array(store.routines.enumerated()), id: \.element.id) { index, routine in
          Button { editorRoute = .edit(routine) } label: {
            LiftRow(
              title: routine.name,
              detail: "\(routine.exerciseIDs.count) exercises · \(routine.trainingMode.title)",
              showsChevron: true
            ) {
              LiftRowIndex(index: index + 1)
            }
          }
          .buttonStyle(.plain)
          .accessibilityHint("Edits this routine")
          .contextMenu {
            Button("Duplicate", systemImage: "plus.square.on.square") {
              _ = store.duplicateRoutine(id: routine.id)
            }
            Button("Schedule", systemImage: "calendar.badge.plus") {
              scheduleRoute = .create(prefill: routine.id)
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
              pendingRoutineDeletion = routine
            }
          }
        }
      }
    }
  }

  private func upcomingRow(_ workout: ScheduledWorkout, index: Int) -> some View {
    let routine = store.routines.first { $0.id == workout.routineID }
    return Button {
      guard let routine else { return }
      onStartRoutine(routine)
    } label: {
      LiftRow(
        title: routine?.name ?? "Unavailable routine",
        detail: upcomingDetail(workout, routine: routine),
        value: routine == nil ? "—" : nil,
        showsChevron: routine != nil
      ) {
        LiftRowIndex(index: index + 1)
      }
    }
    .buttonStyle(.plain)
    .disabled(routine == nil)
    .accessibilityHint(routine == nil ? "The linked routine no longer exists" : "Opens routine preview without starting")
    .swipeActions(edge: .trailing) {
      Button("Delete", role: .destructive) { store.deleteScheduledWorkout(id: workout.id) }
      Button("Reschedule") { scheduleRoute = .edit(workout) }
        .tint(.gray)
    }
  }

  private func upcomingDetail(_ workout: ScheduledWorkout, routine: LiftRoutine?) -> String {
    var parts = [dayLabel(workout.plannedAt)]
    if let routine {
      let estimate = store.estimatedMinutes(for: routine)
      parts.append("\(routine.exerciseIDs.count) exercises")
      if estimate > 0 { parts.append("~\(estimate) min") }
    }
    if !workout.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      parts.append(workout.note)
    }
    return parts.joined(separator: " · ")
  }

  /// Lowercase form of `dayLabel` for use mid-sentence ("today", "tomorrow", "Thu, Oct 8").
  private func dayPhrase(_ date: Date) -> String {
    let label = dayLabel(date)
    return Calendar.current.isDateInToday(date) || Calendar.current.isDateInTomorrow(date) ? label.lowercased() : label
  }

  private func dayLabel(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInTomorrow(date) { return "Tomorrow" }
    return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
  }

  private func completedSessionTitle(for workout: ScheduledWorkout) -> String? {
    guard let sessionID = workout.completedSessionID else { return nil }
    return store.sessions.first { $0.id == sessionID }?.title
  }

  private var deletionPresentation: Binding<Bool> {
    Binding(
      get: { pendingRoutineDeletion != nil },
      set: { if !$0 { pendingRoutineDeletion = nil } }
    )
  }
}

private enum RoutineEditorRoute: Identifiable {
  case create
  case edit(LiftRoutine)

  var id: String {
    switch self {
    case .create: "create"
    case .edit(let routine): "edit-\(routine.id)"
    }
  }

  var routine: LiftRoutine? {
    switch self {
    case .create: nil
    case .edit(let routine): routine
    }
  }
}

private enum ScheduleEditorRoute: Identifiable {
  case create(prefill: UUID?)
  case edit(ScheduledWorkout)

  var id: String {
    switch self {
    case .create: "create"
    case .edit(let workout): "edit-\(workout.id)"
    }
  }
}

private struct ScheduleWorkoutEditor: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var store: LiftStore
  let route: ScheduleEditorRoute
  @State private var routineID: UUID?
  @State private var plannedAt: Date
  @State private var note: String

  init(route: ScheduleEditorRoute) {
    self.route = route
    switch route {
    case .create(let prefill):
      _routineID = State(initialValue: prefill)
      _plannedAt = State(initialValue: Date())
      _note = State(initialValue: "")
    case .edit(let workout):
      _routineID = State(initialValue: workout.routineID)
      _plannedAt = State(initialValue: workout.plannedAt)
      _note = State(initialValue: workout.note)
    }
  }

  var body: some View {
    NavigationStack {
      Form {
        Picker("Routine", selection: $routineID) {
          Text("Select routine").tag(UUID?.none)
          ForEach(store.routines) { routine in
            Text(routine.name).tag(Optional(routine.id))
          }
        }
        .listRowBackground(StrandPalette.card)
        DatePicker("Date", selection: $plannedAt)
          .listRowBackground(StrandPalette.card)
        TextField("Optional note", text: $note, axis: .vertical)
          .listRowBackground(StrandPalette.card)
      }
      .font(StrandFont.body)
      .scrollContentBackground(.hidden)
      .background(StrandPalette.appCanvas)
      .navigationTitle(isEditing ? "Reschedule" : "Schedule workout")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save", action: save)
            .disabled(!canSave)
        }
      }
    }
    .presentationDetents([.medium, .large])
  }

  private var isEditing: Bool {
    if case .edit = route { return true }
    return false
  }

  private var canSave: Bool {
    guard let routineID, store.routines.contains(where: { $0.id == routineID }) else { return false }
    return isEditing || plannedAt >= Calendar.current.startOfDay(for: Date())
  }

  private func save() {
    guard let routineID else { return }
    switch route {
    case .create:
      store.scheduleWorkout(routineID: routineID, at: plannedAt, note: note)
    case .edit(let workout):
      var updated = workout
      updated.routineID = routineID
      updated.plannedAt = plannedAt
      updated.note = note
      store.updateScheduledWorkout(updated)
    }
    dismiss()
  }
}
