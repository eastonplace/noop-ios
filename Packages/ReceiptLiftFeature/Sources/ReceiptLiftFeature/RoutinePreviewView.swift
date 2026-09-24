import SwiftUI
import StrandDesign

struct RoutinePreviewView: View {
  @EnvironmentObject private var store: LiftStore

  let routine: LiftRoutine
  let onBegin: () -> Void
  let onCancel: () -> Void

  @State private var didRequestBegin = false

  init(
    routine: LiftRoutine,
    onBegin: @escaping () -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.routine = routine
    self.onBegin = onBegin
    self.onCancel = onCancel
  }

  private var rows: [RoutinePreviewRow] {
    RoutinePreviewRow.rows(for: routine, exercises: store.exercises)
  }

  var body: some View {
    RoutinePreviewContent(
      routine: routine,
      rows: rows,
      estimatedMinutes: store.estimatedMinutes(for: routine),
      onBegin: {
        guard !didRequestBegin else { return }
        didRequestBegin = true
        onBegin()
      },
      onCancel: onCancel
    )
  }
}

private struct RoutinePreviewContent: View {
  let routine: LiftRoutine
  let rows: [RoutinePreviewRow]
  let estimatedMinutes: Int
  let onBegin: () -> Void
  let onCancel: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
        VStack(alignment: .leading, spacing: 8) {
          Label("Strength training", systemImage: "dumbbell.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(StrandPalette.accent)
          Text(routine.name)
            .font(.largeTitle.weight(.bold))
            .foregroundStyle(StrandPalette.textPrimary)
          if !routine.notes.isEmpty {
            Text(routine.notes)
              .font(.subheadline)
              .foregroundStyle(StrandPalette.textSecondary)
          }
        }

        NoopCard {
          HStack(spacing: 24) {
            summaryMetric("Exercises", value: "\(rows.count)", symbol: "square.stack.3d.up")
            Divider().overlay(StrandPalette.cardBorder)
            summaryMetric("Estimated time", value: estimatedMinutes > 0 ? "\(estimatedMinutes) min" : "—", symbol: "clock")
          }
          .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text("Workout plan").font(.headline)
            Spacer()
            Text("\(rows.count) exercises").font(.subheadline).foregroundStyle(StrandPalette.textSecondary)
          }
          if rows.isEmpty {
            NoopCard {
              Text("Add exercises during your workout.")
                .font(.body).foregroundStyle(StrandPalette.textSecondary)
            }
          } else {
            ForEach(rows) { row in
              NavigationLink {
                if let exercise = row.exercise {
                  ExerciseProgressView(exerciseID: exercise.id, showsInformation: true)
                }
              } label: {
                NoopCard {
                  HStack(alignment: .top, spacing: 14) {
                    if let exercise = row.exercise {
                      LiftExerciseThumb(exercise: exercise, size: 64, showsBorder: false)
                        .clipShape(.rect(cornerRadius: 10))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                      Text(row.title.capitalized)
                        .font(.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                      if let exercise = row.exercise {
                        Text("\(exercise.muscleGroup.capitalized) · \(exercise.equipment.capitalized)")
                          .font(.subheadline).foregroundStyle(StrandPalette.textSecondary)
                      }
                      if let plan = row.plan {
                        Text("\(plan.sets) sets × \(plan.reps) reps")
                          .font(.subheadline.weight(.semibold)).foregroundStyle(StrandPalette.accent)
                        Text(row.detail)
                          .font(.caption).foregroundStyle(StrandPalette.textSecondary)
                      }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                      .font(.caption.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary)
                      .padding(.top, 4)
                  }
                }
              }
              .buttonStyle(.plain)
              .disabled(row.exercise == nil)
              .accessibilityLabel(row.accessibilityLabel)
              .accessibilityHint("Opens exercise photo, muscles, instructions, and progress")
            }
          }
        }
      }
      .padding(NoopMetrics.screenPadding)
    }
    .scrollIndicators(.hidden)
    .navigationBarBackButtonHidden(true)
    .toolbar(.visible, for: .navigationBar)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button(action: onCancel) { Label("Back", systemImage: "chevron.left") }
          .tint(StrandPalette.textSecondary)
      }
    }
    .safeAreaInset(edge: .bottom) {
      Button(action: onBegin) {
        Label("Start workout", systemImage: "play.fill")
          .font(.headline)
          .frame(maxWidth: .infinity, minHeight: 52)
          .foregroundStyle(LiftTheme.onAccent)
          .background(StrandPalette.accent, in: .rect(cornerRadius: NoopMetrics.cardRadius))
      }
      .buttonStyle(.plain)
      .padding(.horizontal, NoopMetrics.screenPadding)
      .padding(.vertical, 12)
      .background(StrandPalette.appCanvas)
    }
    .background(StrandPalette.appCanvas.ignoresSafeArea())
  }

  private func summaryMetric(_ label: String, value: String, symbol: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(label, systemImage: symbol)
        .font(.caption).foregroundStyle(StrandPalette.textSecondary)
      Text(value).font(.title2.weight(.semibold)).monospacedDigit()
        .foregroundStyle(StrandPalette.textPrimary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

}

private struct RoutinePreviewRow: Identifiable {
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

  var title: String {
    exercise?.name ?? "Exercise unavailable"
  }

  var prescription: String {
    plan?.prescription ?? "—"
  }

  var detail: String {
    guard let plan else {
      return "Prescription unavailable · rest uses workout default"
    }
    return "Rest \(plan.rest) · effort \(plan.targetEffort)"
  }

  var accessibilityLabel: String {
    let prefix = "Exercise \(index), \(title)"
    guard let plan else {
      return "\(prefix), prescription unavailable, rest uses workout default"
    }
    return "\(prefix), \(plan.prescription), rest \(plan.rest), effort \(plan.targetEffort)"
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
      onBegin: {},
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
