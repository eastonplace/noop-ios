import StrandDesign
import SwiftUI

struct ScheduleView: View {
  @EnvironmentObject private var store: LiftStore
  @Environment(\.liftFormat) private var format
  let onStartRoutine: (LiftRoutine) -> Void
  /// Opens the routine editor on a new routine as the page appears: "Create routine" from the home page.
  var createsRoutine = false
  @State private var showsLibrary = false
  @State private var editorRoute: RoutineEditorRoute?
  @State private var scheduleRoute: ScheduleEditorRoute?
  @State private var pendingRoutineDeletion: LiftRoutine?
  @State private var selectedDay = Date()
  @State private var didOpenCreator = false

  var body: some View {
    LiftPage(
      title: "Schedule",
      trailing: {
        HeaderChipButton("books.vertical", accessibilityLabel: "Exercise library") { showsLibrary = true }
        HeaderChipButton("plus", accessibilityLabel: "Schedule workout") {
          scheduleRoute = .create(prefill: store.nextSuggestedRoutine?.id)
        }
      }
    ) {
      upcomingSection
      recentlyCompletedSection
      FlatSectionSeparator()
      routineSection
    }
    .task {
      guard createsRoutine, !didOpenCreator else { return }
      didOpenCreator = true
      editorRoute = .create
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
      "Delete \(pendingRoutineDeletion?.name ?? String(localized: "Routine"))?",
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

  // MARK: Upcoming

  private var upcomingSection: some View {
    let upcoming = LiftScheduleWeek.upcoming(
      store.upcomingWorkouts,
      on: selectedDay,
      calendar: .current
    )
    return LiftFlatSection("Upcoming", systemImage: "calendar", contentSpacing: NoopMetrics.space3) {
      ScheduleWeekStrip(sessions: store.sessions, selectedDay: $selectedDay)
      if upcoming.isEmpty {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
          emptyDayNote
          ChipRow {
            WidgetChipButton(
              title: "Schedule workout", systemImage: "calendar.badge.plus",
              accessibilityLabel: "Schedule workout"
            ) { scheduleRoute = .create(prefill: store.nextSuggestedRoutine?.id) }
          }
        }
      } else {
        LiftRowList(items: upcoming, leadsWithGlyphDisc: true) { workout, _ in
          upcomingRow(workout)
        }
      }
    }
  }

  @ViewBuilder private var emptyDayNote: some View {
    let calendar = Calendar.current
    if calendar.isDateInToday(selectedDay) {
      LiftNote(text: "Nothing scheduled for today.")
    } else if calendar.isDateInTomorrow(selectedDay) {
      LiftNote(text: "Nothing scheduled for tomorrow.")
    } else {
      LiftNote(text: "Nothing scheduled for \(format.weekdayDay(selectedDay)).")
    }
  }

  private func upcomingRow(_ workout: ScheduledWorkout) -> some View {
    let routine = store.routines.first { $0.id == workout.routineID }
    return HStack(spacing: 0) {
      Button {
        guard let routine else { return }
        onStartRoutine(routine)
      } label: {
        LiftListRow(
          title: routine?.name ?? String(localized: "Unavailable routine"),
          details: [upcomingDetail(workout, routine: routine)],
          value: routine == nil ? LiftFormat.missing : nil,
          leading: { GlyphDisc("calendar") }
        )
      }
      .buttonStyle(FlatRowPressStyle())
      .disabled(routine == nil)
      .accessibilityElement(children: .combine)
      .accessibilityHint(routine == nil ? Text("The linked routine no longer exists") : Text("Opens routine preview without starting"))
      LiftRowMenu(label: "Scheduled workout actions") {
        Button("Reschedule", systemImage: "calendar") { scheduleRoute = .edit(workout) }
        Button("Remove", systemImage: "trash", role: .destructive) { store.deleteScheduledWorkout(id: workout.id) }
      }
    }
  }

  private func upcomingDetail(_ workout: ScheduledWorkout, routine: LiftRoutine?) -> String {
    var parts = [format.relativeDay(workout.plannedAt)]
    if let routine {
      parts.append(LiftFormat.exerciseCount(routine.exerciseIDs.count))
      let estimate = store.estimatedMinutes(for: routine)
      if estimate > 0 { parts.append(format.minutes(estimate)) }
    }
    let note = workout.note.trimmingCharacters(in: .whitespacesAndNewlines)
    if !note.isEmpty { parts.append(note) }
    return LiftFormat.facts(parts)
  }

  // MARK: Recently completed

  @ViewBuilder
  private var recentlyCompletedSection: some View {
    let recent = store.recentCompletedWorkouts
    if !recent.isEmpty {
      FlatSectionSeparator()
      LiftFlatSection("Recently completed", systemImage: "checkmark.circle", contentSpacing: 0) {
        LiftRowList(items: recent, leadsWithGlyphDisc: true) { workout, _ in
          let routine = store.routines.first { $0.id == workout.routineID }
          let name = routine?.name ?? completedSessionTitle(for: workout) ?? String(localized: "Unavailable routine")
          LiftListRow(
            title: name,
            details: [format.relativeDay(workout.plannedAt)],
            leading: { GlyphDisc("checkmark", tint: .custom(StrandPalette.success)) }
          )
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Completed \(name) on \(format.weekdayDay(workout.plannedAt))")
        }
      }
    }
  }

  // MARK: Routines

  private var routineSection: some View {
    LiftFlatSection("Routines", systemImage: "list.bullet.rectangle", contentSpacing: 0) {
      if store.routines.isEmpty {
        LiftNote(text: "No routines yet. Create one to start.")
          .padding(.vertical, NoopMetrics.space2)
      } else {
        LiftRowList(items: store.routines, leadsWithGlyphDisc: true) { routine, _ in
          routineRow(routine)
        }
      }
      Button { editorRoute = .create } label: { Label("Create routine", systemImage: "plus") }
        .buttonStyle(PrimaryPillButtonStyle())
        .padding(.top, NoopMetrics.space3)
    }
  }

  private func routineRow(_ routine: LiftRoutine) -> some View {
    HStack(spacing: 0) {
      Button { onStartRoutine(routine) } label: {
        LiftListRow(
          title: routine.name,
          details: [LiftFormat.facts([LiftFormat.exerciseCount(routine.exerciseIDs.count), routine.trainingMode.title])],
          leading: { GlyphDisc("dumbbell.fill") }
        )
      }
      .buttonStyle(FlatRowPressStyle())
      .accessibilityElement(children: .combine)
      .accessibilityHint("Opens routine preview without starting")
      LiftRowMenu(label: "Routine actions") {
        Button("Edit", systemImage: "pencil") { editorRoute = .edit(routine) }
        Button("Schedule", systemImage: "calendar.badge.plus") { scheduleRoute = .create(prefill: routine.id) }
        Button("Duplicate", systemImage: "plus.square.on.square") { _ = store.duplicateRoutine(id: routine.id) }
        Button("Delete", systemImage: "trash", role: .destructive) { pendingRoutineDeletion = routine }
      }
    }
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
    LiftSheetPage(
      title: isEditing ? "Reschedule" : "Schedule workout",
      onClose: { dismiss() },
      content: {
        LiftFlatSection("Routine", contentSpacing: 0) {
          LiftRowList(items: store.routines, leadsWithGlyphDisc: true) { routine, _ in
            LiftChoiceRow(
              title: routine.name,
              detail: LiftFormat.facts([LiftFormat.exerciseCount(routine.exerciseIDs.count), routine.trainingMode.title]),
              isSelected: routineID == routine.id
            ) { routineID = routine.id }
          }
        }
        FlatSectionSeparator()
        LiftFlatSection("Date", systemImage: "calendar") {
          DatePicker("Date", selection: $plannedAt)
            .labelsHidden()
            .datePickerStyle(.compact)
            .tint(StrandPalette.accent)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        FlatSectionSeparator()
        LiftFlatSection("Note", systemImage: "text.alignleft") {
          LiftField(
            title: "Note", text: $note, placeholder: "Optional note", axis: .vertical, capitalization: .sentences,
            hidesTitle: true)
        }
      },
      footer: {
        Button(action: save) { Text("Save").liftPillLabel() }
          .buttonStyle(PrimaryPillButtonStyle())
          .disabled(!canSave)
      }
    )
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
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
