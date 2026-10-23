import Foundation

/// The complete source values travel with the review. Applying compares values, never a count or a lossy digest.
struct LiftProgressionReview: Equatable, Sendable {
  let storeID: UUID
  let createdAt: Date
  let routine: LiftRoutine
  let exercises: [LiftExercise]
  let sessions: [LiftSession]
  let unit: LiftWeightUnit
  let rows: [LiftProgressionReviewRow]

  var hasTargets: Bool { rows.contains { $0.decision.target != nil } }

  static func make(
    storeID: UUID,
    routine: LiftRoutine,
    exercises: [LiftExercise],
    sessions: [LiftSession],
    unit: LiftWeightUnit,
    now: Date
  ) -> LiftProgressionReview {
    let ids = Set(routine.exerciseIDs)
    let sourceExercises = exercises.filter { ids.contains($0.id) }
    let sourceSessions = sessions.filter { $0.routineID == routine.id }
    let uniqueExerciseIDs = ids.count == routine.exerciseIDs.count
    let rows = routine.exerciseIDs.enumerated().map { index, id in
      let exercise = sourceExercises.first { $0.id == id }
      let plans = (routine.exercisePlans ?? []).filter { $0.exerciseID == id }
      let plan = plans.count == 1 ? plans.first : nil
      let equipment = exercise.map(LiftProgressionEquipment.forExercise) ?? .unknown
      let decision: LiftProgressionDecision
      if uniqueExerciseIDs, exercise != nil, let plan {
        decision = LiftProgressionEngine.recommendation(
          plan: LiftProgressionPlan(sets: plan.sets, reps: plan.reps, targetEffort: plan.targetEffort),
          equipment: equipment,
          unit: unit.progressionUnit,
          history: sourceSessions.map { session in
            LiftProgressionSession(
              id: session.id, startedAt: session.startedAt, endedAt: session.endedAt,
              sets: session.sets.filter { $0.exerciseID == id }.map { set in
                LiftProgressionWorkSet(
                  id: set.id, weightPounds: set.weight, reps: set.reps, rpe: set.rpe,
                  effortRated: set.effortRated, isWarmup: set.isWarmup, completedAt: set.completedAt
                )
              }
            )
          },
          now: now
        )
      } else {
        decision = LiftProgressionDecision(
          reason: .unsupportedPrescription, target: nil, sourceSessionID: nil, sourceEndedAt: nil, evidence: nil
        )
      }
      return LiftProgressionReviewRow(
        id: "\(id.uuidString)-\(index)", exerciseID: id, exercise: exercise, plan: plan,
        equipment: equipment, decision: decision
      )
    }
    return LiftProgressionReview(
      storeID: storeID, createdAt: now, routine: routine, exercises: sourceExercises,
      sessions: sourceSessions, unit: unit, rows: rows
    )
  }

  func isCurrent(comparedWith current: LiftProgressionReview) -> Bool {
    let age = current.createdAt.timeIntervalSince(createdAt)
    return age.isFinite && (0...900).contains(age)
      && storeID == current.storeID && routine == current.routine
      && exercises == current.exercises && sessions == current.sessions
      && unit == current.unit && rows == current.rows
  }
}

struct LiftProgressionReviewRow: Identifiable, Equatable, Sendable {
  let id: String
  let exerciseID: UUID
  let exercise: LiftExercise?
  let plan: LiftRoutineExercisePlan?
  let equipment: LiftProgressionEquipment
  let decision: LiftProgressionDecision
}

extension LiftWeightUnit {
  var progressionUnit: LiftProgressionUnit { self == .pounds ? .pounds : .kilograms }
}

extension LiftProgressionEquipment {
  static func forExercise(_ exercise: LiftExercise) -> LiftProgressionEquipment {
    if liftUsesBodyweightLoad(exercise) { return .bodyweight }
    let label = exercise.equipment.lowercased()
    let isBarbell = label.contains("barbell") || label.contains("smith")
    let isDumbbell = label.contains("dumbbell")
    if isBarbell && !isDumbbell { return .barbell }
    if isDumbbell && !isBarbell { return .dumbbell }
    return .unknown
  }
}
