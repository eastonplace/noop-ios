#if DEBUG
import Foundation

/// DEBUG-only demo Lift data for the simulator QA harness. Everything is generated relative to "now", so the
/// history always ends yesterday and the schedule always starts tomorrow, however far the simulator's clock has
/// moved. Production builds do not contain this file.
///
/// Launch arguments (read by the host app and by the views' QA scene hooks):
/// - `--noop-lift-demo <variant>` replaces what the coordinator loads with one of the variants below.
///   `full` (routines, fourteen weeks of history, a schedule), `empty` (no routines, no history),
///   `session` (a lift in flight: three sets logged, rest timer idle), `session-rest` (the same with the
///   rest timer running), `session-barbell` (a barbell routine with nothing logged yet), `session-open` (an open lift with no exercises) and `fresh` (the starter routines and no history).
/// - `--noop-lift-scene <scene>` opens a deeper screen straight away; see `LiftQAScene`.
public enum ReceiptLiftDemo {
  public static var requestedVariant: String? {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: "--noop-lift-demo"), arguments.indices.contains(index + 1) else {
      return nil
    }
    return arguments[index + 1].lowercased()
  }

  /// The encoded envelope a coordinator can load, or nil for an unknown variant.
  public static func stateData(variant: String, now: Date = Date(), calendar: Calendar = .current) -> Data? {
    guard let envelope = LiftDemoFixture.envelope(variant: variant, now: now, calendar: calendar) else { return nil }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try? encoder.encode(envelope)
  }
}

enum LiftDemoFixture {
  /// Catalog exercises used by the hand-made "Barbell Basics" routine (the starter bank carries the rest).
  private static let barbellIDs = ["0043", "0025", "0027", "0085", "0031"]

  static func envelope(variant: String, now: Date, calendar: Calendar) -> LiftDataEnvelope? {
    switch variant {
    case "empty":
      return base(routines: [], userExercises: [], sessions: [], scheduled: [], active: nil)
    case "fresh":
      let bank = starter()
      return base(routines: bank.routines, userExercises: bank.exercises, sessions: [], scheduled: [], active: nil)
    case "full", "session", "session-rest", "session-barbell", "session-open":
      let bank = starter()
      let basics = barbellBasics()
      let routines = bank.routines + [basics]
      let bodyweight = Set((bank.exercises + barbellExercises()).filter(liftUsesBodyweightLoad).map(\.id))
      let sessions = history(routines: routines, bodyweightIDs: bodyweight, now: now, calendar: calendar)
      let scheduled = schedule(routines: routines, now: now, calendar: calendar)
      guard variant != "full" else {
        return base(routines: routines, userExercises: bank.exercises, sessions: sessions, scheduled: scheduled,
                    active: nil)
      }
      if variant == "session-open" {
        var open = base(routines: routines, userExercises: bank.exercises, sessions: sessions, scheduled: scheduled,
                        active: LiftSession(id: UUID(), routineID: nil, title: "Open Lift",
                                            startedAt: now.addingTimeInterval(-4 * 60), endedAt: nil, sets: []))
        open.activeExerciseIDsOverride = []
        return open
      }
      let barbell = variant == "session-barbell"
      guard let routine = routines.first(where: { $0.name == (barbell ? "Barbell Basics" : "Upper A") }) else { return nil }
      var envelope = base(routines: routines, userExercises: bank.exercises, sessions: sessions,
                          scheduled: scheduled, active: activeSession(routine: routine, now: now, logsSets: !barbell))
      envelope.activeExerciseIDsOverride = routine.exerciseIDs
      envelope.activePlanOverrides = (routine.exercisePlans ?? []).reduce(into: [:]) { $0[$1.exerciseID] = $1 }
      if variant == "session-rest" { envelope.restTimerEndDate = now.addingTimeInterval(1_500) }
      return envelope
    default:
      return nil
    }
  }

  private static func base(
    routines: [LiftRoutine],
    userExercises: [LiftExercise],
    sessions: [LiftSession],
    scheduled: [ScheduledWorkout],
    active: LiftSession?
  ) -> LiftDataEnvelope {
    LiftDataEnvelope(
      schemaVersion: LiftDataEnvelope.currentSchemaVersion,
      starterBankVersion: LiftDataEnvelope.currentStarterBankVersion,
      userExercises: userExercises,
      routines: routines,
      scheduledWorkouts: scheduled,
      sessions: sessions,
      activeSession: active,
      restTimerEndDate: nil,
      workoutRestOverrideSeconds: nil,
      completedExerciseIDs: [],
      activeExerciseIDsOverride: nil,
      activePlanOverrides: [:],
      activeSupersetGroups: [:],
      settings: LiftSettings()
    )
  }

  // MARK: Routines

  private static func starter() -> (exercises: [LiftExercise], routines: [LiftRoutine]) {
    let bank = LiftRoutineBank.make()
    let byName = Dictionary(bank.exercises.map { (LiftExerciseCatalog.normalizedName($0.name), $0) },
                            uniquingKeysWith: { first, _ in first })
    let routines = bank.routineTemplates.map { template -> LiftRoutine in
      let plans = template.plans.compactMap { plan -> LiftRoutineExercisePlan? in
        guard let exercise = byName[LiftExerciseCatalog.normalizedName(plan.exerciseName)] else { return nil }
        return LiftRoutineExercisePlan(id: UUID(), exerciseID: exercise.id, sets: plan.sets, reps: plan.reps,
                                       rest: plan.rest, targetEffort: plan.targetEffort, notes: plan.notes)
      }
      return LiftRoutine(id: UUID(), name: template.name, notes: template.notes, trainingMode: template.trainingMode,
                         exerciseIDs: plans.map(\.exerciseID), exercisePlans: plans)
    }
    return (bank.exercises, routines)
  }

  private static func barbellExercises() -> [LiftExercise] {
    let records = LiftExerciseCatalog.records
    return barbellIDs.compactMap { id in records.first { $0.id == id }?.liftExercise }
  }

  private static func barbellBasics() -> LiftRoutine {
    let exercises = barbellExercises()
    let prescriptions: [(sets: String, reps: String, rest: String)] = [
      ("4", "5", "3 min"), ("4", "5", "3 min"), ("3", "8", "2 min"), ("3", "8", "2 min"), ("2", "10", "90 s"),
    ]
    let plans = zip(exercises, prescriptions).map { exercise, rx in
      LiftRoutineExercisePlan(id: UUID(), exerciseID: exercise.id, sets: rx.sets, reps: rx.reps, rest: rx.rest,
                              targetEffort: "2 RIR", notes: "")
    }
    return LiftRoutine(id: UUID(), name: "Barbell Basics", notes: "Squat, press, pull. Add 5 lb when every set lands.",
                       trainingMode: .strength, exerciseIDs: plans.map(\.exerciseID), exercisePlans: plans)
  }

  // MARK: History

  /// Three sessions a week for fourteen weeks, the last one finished yesterday, with loads that climb a little
  /// each week so the progress charts have a shape and the newest set can be a record.
  private static func history(
    routines: [LiftRoutine],
    bodyweightIDs: Set<UUID>,
    now: Date,
    calendar: Calendar
  ) -> [LiftSession] {
    let rotation = ["Upper A", "Lower A", "Pull + Posture", "Barbell Basics", "Push + Delts"]
    let byName = Dictionary(routines.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    let today = calendar.startOfDay(for: now)
    var sessions: [LiftSession] = []
    var ordinal = 0
    for week in stride(from: 13, through: 0, by: -1) {
      for back in [5, 3, 1] {
        guard let day = calendar.date(byAdding: .day, value: -(week * 7 + back), to: today) else { continue }
        let name = rotation[ordinal % rotation.count]
        ordinal += 1
        guard let routine = byName[name],
              let start = calendar.date(bySettingHour: 17, minute: 40, second: 0, of: day), start < now else { continue }
        sessions.append(makeSession(routine: routine, bodyweightIDs: bodyweightIDs, start: start, step: 13 - week))
      }
    }
    return sessions.sorted { $0.startedAt < $1.startedAt }
  }

  private static func makeSession(
    routine: LiftRoutine,
    bodyweightIDs: Set<UUID>,
    start: Date,
    step: Int
  ) -> LiftSession {
    let starting: [Double] = [135, 95, 115, 75, 55, 45, 85, 35]
    var sets: [LiftSet] = []
    var clock = start.addingTimeInterval(240)
    for (position, plan) in (routine.exercisePlans ?? []).enumerated() {
      let count = min(LiftStore.setCount(from: plan.sets) ?? 3, 4)
      let reps = topReps(plan.reps)
      let load = bodyweightIDs.contains(plan.exerciseID)
        ? 0
        : ((starting[position % starting.count] + Double(step) * 2.5) / 5).rounded() * 5
      for number in 1...count {
        clock = clock.addingTimeInterval(number == 1 ? 150 : 105)
        sets.append(LiftSet(
          id: UUID(), exerciseID: plan.exerciseID, setNumber: number, weight: load,
          reps: max(reps - (number > 2 ? 1 : 0), 1), rpe: number == count ? 9 : 8, isWarmup: false,
          completedAt: clock, notes: ""))
      }
    }
    return LiftSession(id: UUID(), routineID: routine.id, title: routine.name, startedAt: start,
                       endedAt: clock.addingTimeInterval(180), sets: sets)
  }

  /// "8-10" becomes 8, "5" stays 5, "30-45 s" and friends fall back to 8.
  static func topReps(_ text: String) -> Int {
    let digits = text.split(whereSeparator: { !$0.isNumber })
    guard let first = digits.first, let value = Int(first), value <= 30 else { return 8 }
    return value
  }

  private static func schedule(routines: [LiftRoutine], now: Date, calendar: Calendar) -> [ScheduledWorkout] {
    let today = calendar.startOfDay(for: now)
    let plan: [(String, Int, String)] = [
      ("Lower A", 1, "Heavy legs"), ("Pull + Posture", 3, ""), ("Barbell Basics", 5, "Test 5 lb jumps"),
    ]
    return plan.compactMap { name, days, note in
      guard let routine = routines.first(where: { $0.name == name }),
            let date = calendar.date(byAdding: .day, value: days, to: today),
            let at = calendar.date(bySettingHour: 17, minute: 30, second: 0, of: date) else { return nil }
      return ScheduledWorkout(id: UUID(), routineID: routine.id, plannedAt: at, note: note, completedSessionID: nil)
    }
  }

  private static func activeSession(routine: LiftRoutine, now: Date, logsSets: Bool) -> LiftSession {
    let start = now.addingTimeInterval(logsSets ? -22 * 60 : -3 * 60)
    var sets: [LiftSet] = []
    let plans = routine.exercisePlans ?? []
    guard logsSets else {
      return LiftSession(id: UUID(), routineID: routine.id, title: routine.name, startedAt: start, endedAt: nil, sets: [])
    }
    if let first = plans.first {
      for number in 1...2 {
        sets.append(LiftSet(id: UUID(), exerciseID: first.exerciseID, setNumber: number, weight: 130, reps: 8,
                            rpe: 8, isWarmup: false, completedAt: start.addingTimeInterval(Double(number) * 300),
                            notes: ""))
      }
    }
    if plans.count > 1 {
      sets.append(LiftSet(id: UUID(), exerciseID: plans[1].exerciseID, setNumber: 1, weight: 0, reps: 6, rpe: 8,
                          isWarmup: false, completedAt: start.addingTimeInterval(1_020), notes: ""))
    }
    return LiftSession(id: UUID(), routineID: routine.id, title: routine.name, startedAt: start, endedAt: nil,
                       sets: sets)
  }
}
#endif
