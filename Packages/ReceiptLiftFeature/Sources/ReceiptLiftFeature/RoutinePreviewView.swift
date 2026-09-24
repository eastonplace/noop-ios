import SwiftUI

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

  private var receiptNumber: String {
    String(format: "#%05d", store.sessions.count + 1)
  }

  private var rows: [RoutinePreviewRow] {
    RoutinePreviewRow.rows(for: routine, exercises: store.exercises)
  }

  var body: some View {
    RoutinePreviewContent(
      routine: routine,
      receiptNumber: receiptNumber,
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
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  let routine: LiftRoutine
  let receiptNumber: String
  let rows: [RoutinePreviewRow]
  let estimatedMinutes: Int
  let onBegin: () -> Void
  let onCancel: () -> Void

  var body: some View {
    ScrollView {
      ReceiptSheet {
        ReceiptHeader(
          title: routine.name,
          subtitle: "Routine preview",
          trailing: receiptNumber
        )

        ReceiptDashedRule()
        ReceiptSectionLabel(title: "Workout Plan")

        if rows.isEmpty {
          ReceiptLine(
            index: nil,
            title: "No exercises planned",
            detail: "This routine will begin with an empty receipt.",
            value: "—"
          )
        } else {
          ForEach(rows) { row in
            ReceiptLine(
              index: row.index,
              title: row.title,
              detail: row.detail,
              value: row.prescription,
              thumb: row.exercise
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.accessibilityLabel)

            if !row.isLast {
              ReceiptDashedRule()
            }
          }
        }

        ReceiptTotals(rows: [
          ("Estimated", estimatedMinutes > 0 ? "~\(estimatedMinutes) min" : "—")
        ])

        actions
      }
      .padding(.bottom, 24)
    }
    .scrollIndicators(.hidden)
    .navigationBarBackButtonHidden(true)
    .liftScreenBackground()
  }

  @ViewBuilder
  private var actions: some View {
    if dynamicTypeSize.isAccessibilitySize {
      VStack(spacing: 10) {
        beginButton
        cancelButton
      }
    } else {
      HStack(spacing: 10) {
        cancelButton
        beginButton
      }
    }
  }

  private var cancelButton: some View {
    ReceiptSecondaryButton(
      title: "Cancel",
      systemImage: "xmark",
      tint: LiftTheme.ink,
      fillsWidth: true,
      action: onCancel
    )
  }

  private var beginButton: some View {
    ReceiptPrimaryButton(
      title: "Begin Workout",
      systemImage: "play.fill",
      action: onBegin
    )
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
      receiptNumber: "#00042",
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
