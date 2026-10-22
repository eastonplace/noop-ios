import SwiftUI
import StrandDesign

struct RoutinePreviewView: View {
  @EnvironmentObject private var store: LiftStore

  let routine: LiftRoutine
  let onBegin: (LiftRoutine, LiftProgressionReview?) -> Bool
  let onCancel: () -> Void

  @State private var didRequestBegin = false
  @State private var progression: LiftProgressionReview?
  @State private var startError: String?

  init(
    routine: LiftRoutine,
    onBegin: @escaping (LiftRoutine, LiftProgressionReview?) -> Bool,
    onCancel: @escaping () -> Void
  ) {
    self.routine = routine
    self.onBegin = onBegin
    self.onCancel = onCancel
  }

  private var currentRoutine: LiftRoutine {
    store.routines.first { $0.id == routine.id } ?? routine
  }

  private var rows: [RoutinePreviewRow] {
    RoutinePreviewRow.rows(for: currentRoutine, exercises: store.exercises)
  }

  var body: some View {
    RoutinePreviewContent(
      routine: currentRoutine,
      rows: rows,
      estimatedMinutes: store.estimatedMinutes(for: currentRoutine),
      progression: progression,
      suggestionsCurrent: progression.map { store.progressionReviewIsCurrent($0) } ?? false,
      startError: startError,
      onRefreshSuggestions: refreshSuggestions,
      onBegin: { applySuggestions in
        guard !didRequestBegin else { return }
        if onBegin(currentRoutine, applySuggestions ? progression : nil) {
          didRequestBegin = true
        } else {
          startError = store.status
        }
      },
      onCancel: onCancel
    )
    .task(id: routine.id) {
      await store.loadAndWait()
      refreshSuggestions()
    }
  }

  private func refreshSuggestions() {
    progression = store.progressionReview(for: currentRoutine)
    startError = nil
  }
}

private struct RoutinePreviewContent: View {
  let routine: LiftRoutine
  let rows: [RoutinePreviewRow]
  let estimatedMinutes: Int
  let progression: LiftProgressionReview?
  let suggestionsCurrent: Bool
  let startError: String?
  let onRefreshSuggestions: () -> Void
  let onBegin: (Bool) -> Void
  let onCancel: () -> Void

  @Environment(\.liftFormat) private var format

  var body: some View {
    LiftPage(
      title: LocalizedStringKey(userText: routine.name),
      context: routine.trainingMode.title,
      backAction: onCancel,
      lazy: true,
      bottomPadding: NoopMetrics.space4
    ) {
      overview
      FlatSectionSeparator()
      if let progression, !progression.rows.isEmpty {
        LiftProgressionReviewSection(
          review: progression, isCurrent: suggestionsCurrent, onRefresh: onRefreshSuggestions
        )
        FlatSectionSeparator()
      }
      planSection
    }
    .navigationBarBackButtonHidden(true)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: NoopMetrics.space2) {
        if let startError {
          Text(startError)
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("lift.progression.startError")
        }
        if progression?.hasTargets == true {
          Button { onBegin(true) } label: {
            Label("Apply suggestions & start", systemImage: "play.fill").liftPillLabel()
          }
          .buttonStyle(PrimaryPillButtonStyle())
          .disabled(!suggestionsCurrent)
          .accessibilityIdentifier("lift.progression.applyAndStart")
          Button { onBegin(false) } label: { Text("Start as planned").liftPillLabel() }
            .buttonStyle(SecondaryPillButtonStyle())
            .accessibilityIdentifier("lift.progression.startAsPlanned")
        } else {
          Button { onBegin(false) } label: {
            Label("Start as planned", systemImage: "play.fill").liftPillLabel()
          }
          .buttonStyle(PrimaryPillButtonStyle())
          .accessibilityIdentifier("lift.progression.startAsPlanned")
        }
      }
      .liftFooterBar()
    }
  }

  private var overview: some View {
    LiftFlatSection("Overview", systemImage: "list.bullet.rectangle") {
      VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
        if !routine.notes.isEmpty {
          Text(verbatim: routine.notes)
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        FactStrip(facts: [
          .init("Exercises", value: rows.count.formatted()),
          .init("Sets", value: totalSets > 0 ? totalSets.formatted() : LiftFormat.missing),
          .init(
            "Estimated time", value: estimatedMinutes > 0 ? format.minutes(estimatedMinutes) : LiftFormat.missing,
            spokenValue: estimatedMinutes > 0 ? format.spokenDuration(TimeInterval(estimatedMinutes * 60)) : nil),
        ])
      }
    }
  }

  private var totalSets: Int {
    rows.reduce(0) { $0 + (LiftStore.setCount(from: $1.plan?.sets ?? "") ?? 0) }
  }

  private var planSection: some View {
    LiftFlatSection("Workout plan", trailing: .text(LiftFormat.exerciseCount(rows.count)), contentSpacing: 0) {
      if rows.isEmpty {
        LiftNote(text: "Add exercises during your workout.")
          .padding(.vertical, NoopMetrics.space2)
      } else {
        LiftRowList(items: rows, separatorInset: 52 + NoopMetrics.space3) { row, _ in
          NavigationLink {
            if let exercise = row.exercise {
              ExerciseProgressView(exerciseID: exercise.id, showsInformation: true)
            }
          } label: {
            planRow(row)
          }
          .buttonStyle(FlatRowPressStyle())
          .disabled(row.exercise == nil)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(row.accessibilityLabel)
          .accessibilityHint("Opens exercise photo, muscles, instructions, and progress")
        }
      }
    }
  }

  private func planRow(_ row: RoutinePreviewRow) -> some View {
    LiftListRow(
      title: row.title,
      highlight: row.plan.map { String(localized: "\($0.sets) × \($0.reps)") },
      details: [row.exercise.map { LiftFormat.facts([$0.muscleGroup.capitalized, $0.equipment.capitalized]) } ?? "", row.detail]
        .filter { !$0.isEmpty },
      showsChevron: row.exercise != nil,
      leading: { LiftExerciseThumb(exercise: row.exercise, size: 52) }
    )
  }
}

struct RoutinePreviewRow: Identifiable {
  let id: String
  let index: Int
  let exercise: LiftExercise?
  let plan: LiftRoutineExercisePlan?
  let isLast: Bool

  static func rows(
    for routine: LiftRoutine,
    exercises: [LiftExercise]
  ) -> [RoutinePreviewRow] {
    var exercisesByID: [UUID: LiftExercise] = [:]
    for exercise in exercises {
      exercisesByID[exercise.id] = exercise
    }

    var plansByExerciseID: [UUID: LiftRoutineExercisePlan] = [:]
    for plan in routine.exercisePlans ?? [] {
      plansByExerciseID[plan.exerciseID] = plan
    }

    return routine.exerciseIDs.enumerated().map { index, exerciseID in
      RoutinePreviewRow(
        id: "\(exerciseID.uuidString)-\(index)",
        index: index + 1,
        exercise: exercisesByID[exerciseID],
        plan: plansByExerciseID[exerciseID],
        isLast: index == routine.exerciseIDs.count - 1
      )
    }
  }

  /// The bundled catalog stores lowercase names, so the title (and what VoiceOver reads) goes through `liftDisplayName`
  /// like every other Lift list.
  var title: String {
    exercise?.name.liftDisplayName ?? String(localized: "Exercise unavailable")
  }

  var prescription: String {
    plan?.prescription ?? "—"
  }

  var detail: String {
    guard let plan else {
      return String(localized: "Prescription unavailable · rest uses workout default")
    }
    return String(localized: "Rest \(plan.rest) · effort \(plan.targetEffort)")
  }

  var accessibilityLabel: String {
    let prefix = String(localized: "Exercise \(index), \(title)")
    guard let plan else {
      return String(localized: "\(prefix), prescription unavailable, rest uses workout default")
    }
    return String(localized: "\(prefix), \(plan.prescription), rest \(plan.rest), effort \(plan.targetEffort)")
  }
}

#if DEBUG
private enum RoutinePreviewFixtures {
  static let pressID = UUID(uuidString: "00400000-0000-0000-0000-000000000001")!
  static let rowID = UUID(uuidString: "00400000-0000-0000-0000-000000000002")!
  static let missingID = UUID(uuidString: "00400000-0000-0000-0000-000000000003")!

  static let exercises = [
    LiftExercise(
      id: pressID,
      name: "Incline Dumbbell Press",
      muscleGroup: "Chest",
      equipment: "Dumbbell",
      instructions: "Press with control."
    ),
    LiftExercise(
      id: rowID,
      name: "Chest Supported Row",
      muscleGroup: "Back",
      equipment: "Dumbbell",
      instructions: "Row toward the ribs."
    )
  ]

  static let routine = LiftRoutine(
    id: UUID(uuidString: "00400000-0000-0000-0000-000000000010")!,
    name: "Upper Strength",
    notes: "",
    trainingMode: .strength,
    exerciseIDs: [pressID, rowID],
    exercisePlans: [
      LiftRoutineExercisePlan(
        id: UUID(uuidString: "00400000-0000-0000-0000-000000000011")!,
        exerciseID: pressID,
        sets: "4",
        reps: "6-8",
        rest: "2 min",
        targetEffort: "RPE 8",
        notes: ""
      ),
      LiftRoutineExercisePlan(
        id: UUID(uuidString: "00400000-0000-0000-0000-000000000012")!,
        exerciseID: rowID,
        sets: "3",
        reps: "8-10",
        rest: "90 sec",
        targetEffort: "RPE 8",
        notes: ""
      )
    ]
  )

  static let emptyRoutine = LiftRoutine(
    id: UUID(uuidString: "00400000-0000-0000-0000-000000000020")!,
    name: "Empty Routine",
    notes: "",
    trainingMode: .hypertrophy,
    exerciseIDs: [],
    exercisePlans: []
  )

  static let missingRoutine = LiftRoutine(
    id: UUID(uuidString: "00400000-0000-0000-0000-000000000030")!,
    name: "Recovery Day",
    notes: "",
    trainingMode: .endurance,
    exerciseIDs: [missingID],
    exercisePlans: [
      LiftRoutineExercisePlan(
        id: UUID(uuidString: "00400000-0000-0000-0000-000000000031")!,
        exerciseID: missingID,
        sets: "2",
        reps: "12",
        rest: "60 sec",
        targetEffort: "RPE 6",
        notes: ""
      )
    ]
  )

  @MainActor static func content(
    routine: LiftRoutine,
    exercises: [LiftExercise]
  ) -> some View {
    RoutinePreviewContent(
      routine: routine,
      rows: RoutinePreviewRow.rows(for: routine, exercises: exercises),
      estimatedMinutes: LiftStore.estimatedMinutes(
        plans: routine.exercisePlans ?? [],
        defaultRestSeconds: 90
      ),
      progression: LiftProgressionReview.make(
        storeID: UUID(), routine: routine, exercises: exercises, sessions: [], unit: .pounds, now: Date()
      ),
      suggestionsCurrent: true,
      startError: nil,
      onRefreshSuggestions: {},
      onBegin: { _ in },
      onCancel: {}
    )
  }
}

#Preview("Routine Preview — Default") {
  RoutinePreviewFixtures.content(
    routine: RoutinePreviewFixtures.routine,
    exercises: RoutinePreviewFixtures.exercises
  )
}

#Preview("Routine Preview — Empty") {
  RoutinePreviewFixtures.content(
    routine: RoutinePreviewFixtures.emptyRoutine,
    exercises: RoutinePreviewFixtures.exercises
  )
}

#Preview("Routine Preview — Missing Exercise") {
  RoutinePreviewFixtures.content(
    routine: RoutinePreviewFixtures.missingRoutine,
    exercises: RoutinePreviewFixtures.exercises
  )
}

#Preview("Routine Preview — XL") {
  RoutinePreviewFixtures.content(
    routine: RoutinePreviewFixtures.routine,
    exercises: RoutinePreviewFixtures.exercises
  )
  .environment(\.dynamicTypeSize, .accessibility2)
}
#endif
