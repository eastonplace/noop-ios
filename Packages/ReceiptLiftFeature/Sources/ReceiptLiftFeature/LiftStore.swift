import Foundation

struct LiftPersonalRecord: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case estimatedOneRepMax
    case reps
  }

  let kind: Kind
  let value: Double
  let previousBest: Double
}

struct LiftSetOutcome: Equatable, Sendable {
  let set: LiftSet
  let personalRecord: LiftPersonalRecord?
}

struct LiftProgressCacheKey: Equatable, Sendable {
  let range: LiftProgressRange
  let referenceNowBits: UInt64
  let calendarIdentifier: String
  let timeZoneIdentifier: String
  let timeZoneOffset: Int
  let firstWeekday: Int
  let minimumDaysInFirstWeek: Int
  let sessionSignature: UInt64
  let exerciseNameSignature: UInt64

  init(
    range: LiftProgressRange,
    now: Date,
    calendar: Calendar,
    sessions: [LiftSession],
    exerciseNames: [UUID: String]
  ) {
    self.range = range
    referenceNowBits = now.timeIntervalSinceReferenceDate.bitPattern
    calendarIdentifier = String(describing: calendar.identifier)
    timeZoneIdentifier = calendar.timeZone.identifier
    timeZoneOffset = calendar.timeZone.secondsFromGMT(for: now)
    firstWeekday = calendar.firstWeekday
    minimumDaysInFirstWeek = calendar.minimumDaysInFirstWeek

    let window = LiftProgressMath.window(
      for: range,
      sessions: sessions,
      now: now,
      calendar: calendar
    )
    let eligibleSessions = sessions
      .filter {
        $0.endedAt != nil
          && $0.startedAt >= window.startInclusive
          && $0.startedAt <= now
      }
      .sorted { left, right in
        if left.startedAt != right.startedAt { return left.startedAt < right.startedAt }
        if left.endedAt != right.endedAt {
          return (left.endedAt ?? left.startedAt) < (right.endedAt ?? right.startedAt)
        }
        return left.id.uuidString < right.id.uuidString
      }

    var sessionDigest = LiftStableDigest()
    sessionDigest.append(eligibleSessions.count)
    for session in eligibleSessions {
      sessionDigest.append(session.id)
      sessionDigest.append(session.startedAt)
      sessionDigest.append(session.endedAt ?? session.startedAt)
      sessionDigest.append(session.sets.count)
      for set in session.sets {
        sessionDigest.append(set.id)
        sessionDigest.append(set.exerciseID)
        sessionDigest.append(set.weight.bitPattern)
        sessionDigest.append(set.reps)
        sessionDigest.append(set.isWarmup)
        sessionDigest.append(set.completedAt)
      }
    }
    sessionSignature = sessionDigest.value

    var nameDigest = LiftStableDigest()
    let sortedNames = exerciseNames.sorted { $0.key.uuidString < $1.key.uuidString }
    nameDigest.append(sortedNames.count)
    for (id, name) in sortedNames {
      nameDigest.append(id)
      nameDigest.append(name)
    }
    exerciseNameSignature = nameDigest.value
  }
}

private struct LiftStableDigest {
  private(set) var value: UInt64 = 14_695_981_039_346_656_037

  mutating func append(_ byte: UInt8) {
    value ^= UInt64(byte)
    value &*= 1_099_511_628_211
  }

  mutating func append(_ value: Bool) {
    append(value ? 1 : 0)
  }

  mutating func append(_ value: Int) {
    append(UInt64(bitPattern: Int64(value)))
  }

  mutating func append(_ value: UInt64) {
    for shift in stride(from: 56, through: 0, by: -8) {
      append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
    }
  }

  mutating func append(_ value: Date) {
    append(value.timeIntervalSinceReferenceDate.bitPattern)
  }

  mutating func append(_ value: UUID) {
    withUnsafeBytes(of: value.uuid) { bytes in
      for byte in bytes { append(byte) }
    }
  }

  mutating func append(_ value: String) {
    let bytes = Array(value.utf8)
    append(bytes.count)
    for byte in bytes { append(byte) }
  }
}

@MainActor
final class LiftStore: ObservableObject {
  static let prDetectionEnabled = true

  @Published private(set) var exercises: [LiftExercise] = []
  @Published private(set) var routines: [LiftRoutine] = []
  @Published private(set) var scheduledWorkouts: [ScheduledWorkout] = []
  @Published private(set) var sessions: [LiftSession] = []
  @Published private(set) var activeSession: LiftSession?
  @Published private(set) var restTimerEndDate: Date?
  @Published private(set) var workoutRestOverrideSeconds: TimeInterval?
  @Published private(set) var completedExerciseIDs: Set<UUID> = []
  @Published private(set) var activeExerciseIDsOverride: [UUID]?
  @Published private(set) var activePlanOverrides: [UUID: LiftRoutineExercisePlan] = [:]
  @Published private(set) var activeSupersetGroups: [UUID: Int] = [:]
  @Published private(set) var settings = LiftSettings()
  @Published var defaultRestSeconds: TimeInterval = 90
  @Published var status = "Ready"

  private var userExercises: [LiftExercise] = []
  private var starterBankVersion = LiftDataEnvelope.currentStarterBankVersion
  private var didLoad = false
  private var didFinishLoad = false
  private var loadTask: Task<Void, Never>?
  @Published private(set) var databaseSaveError: String?
  @Published private(set) var isFinishing = false
  private let database: ReceiptLiftDatabase?
  private let canStartSession: @MainActor () -> Bool
  private var databaseTask: Task<Void, Error>?
  private var databaseInvalidated = false
  private var finishDate: Date?
  private let persistence: LiftPersistenceIO
  private let saveDebounceInterval: TimeInterval
  private var saveGeneration = 0
  private var progressSnapshotCache: (key: LiftProgressCacheKey, value: LiftProgressSnapshot)?
  private(set) var progressSnapshotComputationCount = 0

  init(
    dataURL: URL? = nil,
    saveDebounceInterval: TimeInterval = 0.5,
    database: ReceiptLiftDatabase? = nil,
    canStart: @escaping @MainActor () -> Bool = { true }
  ) {
    self.database = database
    self.canStartSession = canStart
    let resolvedDataURL = dataURL ?? FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Lift", isDirectory: true)
      .appendingPathComponent("lift-data.json")
    persistence = LiftPersistenceIO(dataURL: resolvedDataURL)
    self.saveDebounceInterval = max(saveDebounceInterval, 0)
  }

  var activeExercises: [LiftExercise] {
    guard let activeSession else { return [] }
    if let activeExerciseIDsOverride {
      return activeExerciseIDsOverride.compactMap { id in
        exercises.first { $0.id == id }
      }
    }
    if let routineID = activeSession.routineID,
       let routine = routines.first(where: { $0.id == routineID }) {
      return routine.exerciseIDs.compactMap { id in
        exercises.first { $0.id == id }
      }
    }
    return displayExercises
  }

  var displayExercises: [LiftExercise] {
    var seen = Set<UUID>()
    let planned = routines
      .flatMap(\.exerciseIDs)
      .compactMap { id -> LiftExercise? in
        guard !seen.contains(id),
              let exercise = exercises.first(where: { $0.id == id })
        else { return nil }
        seen.insert(id)
        return exercise
      }
    let remaining = exercises.filter { !seen.contains($0.id) }
    return planned + remaining
  }

  var lastCompletedSession: LiftSession? {
    sessions
      .filter { $0.endedAt != nil }
      .sorted { ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) }
      .first
  }

  var sevenDayVolume: Double {
    let start = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    return sessions
      .filter { $0.startedAt >= start }
      .reduce(0) { $0 + $1.totalVolume }
  }

  var sevenDaySetCount: Int {
    let start = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    return sessions
      .filter { $0.startedAt >= start }
      .flatMap(\.workingSets)
      .count
  }

  var sevenDayWorkoutCount: Int {
    Self.sevenDayWorkoutCount(in: sessions, asOf: Date())
  }

  var nextSuggestedRoutine: LiftRoutine? {
    Self.suggestedRoutine(
      routines: routines,
      scheduledWorkouts: scheduledWorkouts,
      sessions: sessions,
      on: Date()
    )
  }

  var upcomingWorkouts: [ScheduledWorkout] {
    Self.upcomingWorkouts(in: scheduledWorkouts, now: Date(), calendar: .current)
  }

  var recentCompletedWorkouts: [ScheduledWorkout] {
    Self.recentCompletedWorkouts(in: scheduledWorkouts, now: Date(), calendar: .current)
  }

  nonisolated static func sevenDayWorkoutCount(in sessions: [LiftSession], asOf date: Date) -> Int {
    let start = Calendar.current.date(byAdding: .day, value: -7, to: date) ?? date
    return sessions.filter { session in
      session.endedAt != nil && session.startedAt >= start && session.startedAt <= date
    }.count
  }

  nonisolated static func suggestedRoutine(
    routines: [LiftRoutine],
    scheduledWorkouts: [ScheduledWorkout],
    sessions: [LiftSession],
    on date: Date
  ) -> LiftRoutine? {
    let calendar = Calendar.current
    for scheduled in upcomingWorkouts(in: scheduledWorkouts, now: date, calendar: calendar) {
      if let routine = routines.first(where: { $0.id == scheduled.routineID }) {
        return routine
      }
    }

    let week = calendar.dateInterval(of: .weekOfYear, for: date)
    let completedRoutineIDs = Set(sessions.compactMap { session -> UUID? in
      guard session.endedAt != nil,
            let routineID = session.routineID,
            week?.contains(session.startedAt) ?? false
      else { return nil }
      return routineID
    })
    return routines.first { !completedRoutineIDs.contains($0.id) } ?? routines.first
  }

  nonisolated static func upcomingWorkouts(
    in workouts: [ScheduledWorkout],
    now: Date,
    calendar: Calendar
  ) -> [ScheduledWorkout] {
    let lowerBound = calendar.startOfDay(for: now)
    return workouts
      .filter { $0.completedSessionID == nil && $0.plannedAt >= lowerBound }
      .sorted(by: scheduledAscending)
  }

  nonisolated static func recentCompletedWorkouts(
    in workouts: [ScheduledWorkout],
    now: Date,
    calendar: Calendar
  ) -> [ScheduledWorkout] {
    let today = calendar.startOfDay(for: now)
    let lowerBound = calendar.date(byAdding: .day, value: -6, to: today) ?? today
    let upperBound = calendar.date(byAdding: .day, value: 1, to: today) ?? now
    return workouts
      .filter {
        $0.completedSessionID != nil
          && $0.plannedAt >= lowerBound
          && $0.plannedAt < upperBound
      }
      .sorted { lhs, rhs in
        if lhs.plannedAt != rhs.plannedAt { return lhs.plannedAt > rhs.plannedAt }
        return lhs.id.uuidString < rhs.id.uuidString
      }
  }

  private nonisolated static func scheduledAscending(
    _ lhs: ScheduledWorkout,
    _ rhs: ScheduledWorkout
  ) -> Bool {
    if lhs.plannedAt != rhs.plannedAt { return lhs.plannedAt < rhs.plannedAt }
    return lhs.id.uuidString < rhs.id.uuidString
  }

  var preferredExerciseID: UUID? {
    routines.first?.exercisePlans?.first?.exerciseID
      ?? routines.first?.exerciseIDs.first
      ?? exercises.first?.id
  }

  func progressSnapshot(
    for range: LiftProgressRange,
    now: Date,
    calendar: Calendar
  ) -> LiftProgressSnapshot {
    let exerciseNames = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0.name) })
    let key = LiftProgressCacheKey(
      range: range,
      now: now,
      calendar: calendar,
      sessions: sessions,
      exerciseNames: exerciseNames
    )
    if let progressSnapshotCache, progressSnapshotCache.key == key {
      return progressSnapshotCache.value
    }

    let snapshot = LiftProgressMath.snapshot(
      sessions: sessions,
      range: range,
      now: now,
      calendar: calendar,
      exerciseNames: exerciseNames
    )
    progressSnapshotCache = (key, snapshot)
    progressSnapshotComputationCount += 1
    return snapshot
  }

  var isLoaded: Bool { didFinishLoad }

  func load() {
    guard !didLoad else { return }
    didLoad = true
    loadTask = Task { [weak self] in
      await self?.performLoad()
    }
  }

  func loadAndWait() async {
    load()
    await loadTask?.value
  }

  func startRoutine(_ routine: LiftRoutine?) {
    guard canStartSession(), !databaseInvalidated else { status = "Finish your current NOOP workout before starting Lift."; return }
    activeSession = LiftSession(
      id: UUID(),
      routineID: routine?.id,
      title: routine?.name ?? "Open Lift",
      startedAt: Date(),
      endedAt: nil,
      sets: []
    )
    restTimerEndDate = nil
    workoutRestOverrideSeconds = nil
    completedExerciseIDs = []
    activeExerciseIDsOverride = routine?.exerciseIDs ?? []
    activePlanOverrides = (routine?.exercisePlans ?? []).reduce(into: [:]) { snapshot, plan in
      snapshot[plan.exerciseID] = plan
    }
    activeSupersetGroups = [:]
    status = "Started \(activeSession?.title ?? "lift")"
    save()
    syncLiveActivity()
  }

  @discardableResult
  func createRoutine(
    name: String,
    notes: String,
    trainingMode: TrainingMode
  ) -> LiftRoutine {
    createRoutine(name: name, notes: notes, trainingMode: trainingMode, plans: [])
  }

  @discardableResult
  func createRoutine(
    name: String,
    notes: String,
    trainingMode: TrainingMode,
    plans: [LiftRoutineExercisePlan]
  ) -> LiftRoutine {
    let routine = canonicalRoutine(
      LiftRoutine(
        id: UUID(),
        name: canonicalRoutineName(name),
        notes: notes,
        trainingMode: trainingMode,
        exerciseIDs: plans.map(\.exerciseID),
        exercisePlans: plans
      )
    )
    routines.append(routine)
    status = "Created \(routine.name)"
    save()
    return routine
  }

  func updateRoutine(_ routine: LiftRoutine) {
    guard let index = routines.firstIndex(where: { $0.id == routine.id }) else { return }
    let updated = canonicalRoutine(routine)
    routines[index] = updated
    status = "Updated \(updated.name)"
    save()
  }

  func deleteRoutine(id: UUID) {
    deleteRoutine(id: id, now: Date(), calendar: .current)
  }

  func deleteRoutine(id: UUID, now: Date, calendar: Calendar) {
    guard routines.contains(where: { $0.id == id }) else { return }
    routines.removeAll { $0.id == id }
    let today = calendar.startOfDay(for: now)
    scheduledWorkouts.removeAll {
      $0.routineID == id && $0.completedSessionID == nil && $0.plannedAt >= today
    }
    status = "Deleted routine"
    save()
  }

  @discardableResult
  func duplicateRoutine(id: UUID) -> LiftRoutine? {
    guard let source = routines.first(where: { $0.id == id }) else { return nil }
    let sourcePlans = materializedPlans(for: source)
    let copy = createRoutine(
      name: "\(source.name) Copy",
      notes: source.notes,
      trainingMode: source.trainingMode,
      plans: sourcePlans.map {
        LiftRoutineExercisePlan(
          id: UUID(),
          exerciseID: $0.exerciseID,
          sets: $0.sets,
          reps: $0.reps,
          rest: $0.rest,
          targetEffort: $0.targetEffort,
          notes: $0.notes
        )
      }
    )
    return copy
  }

  func moveRoutinePlan(routineID: UUID, from source: IndexSet, to destination: Int) {
    guard let routineIndex = routines.firstIndex(where: { $0.id == routineID }) else { return }
    var routine = routines[routineIndex]
    var plans = materializedPlans(for: routine)
    let movedPlans = Self.moving(plans, from: source, to: destination)
    guard movedPlans != plans else { return }
    plans = movedPlans
    routine.exercisePlans = plans
    routine.exerciseIDs = plans.map(\.exerciseID)
    routines[routineIndex] = canonicalRoutine(routine)
    status = "Reordered \(routine.name)"
    save()
  }

  @discardableResult
  func scheduleWorkout(routineID: UUID, at date: Date, note: String) -> ScheduledWorkout {
    let workout = ScheduledWorkout(
      id: UUID(), routineID: routineID, plannedAt: date, note: note, completedSessionID: nil
    )
    scheduledWorkouts.append(workout)
    status = "Scheduled workout"
    save()
    return workout
  }

  func updateScheduledWorkout(_ workout: ScheduledWorkout) {
    guard let index = scheduledWorkouts.firstIndex(where: { $0.id == workout.id }) else { return }
    scheduledWorkouts[index] = workout
    status = "Updated schedule"
    save()
  }

  func deleteScheduledWorkout(id: UUID) {
    guard scheduledWorkouts.contains(where: { $0.id == id }) else { return }
    scheduledWorkouts.removeAll { $0.id == id }
    status = "Removed scheduled workout"
    save()
  }

  func finishActiveSession() -> LiftSession? {
    guard var session = activeSession else { return nil }
    session.endedAt = finishDate ?? Date()
    linkEarliestScheduledWorkout(to: session)
    let progress = activeRoutineProgress()
    LiftLiveActivityManager.shared.finish(
      session: session,
      progress: progress,
      currentMove: liveActivityMoveName(for: progress),
      restTimerEndDate: nil
    )
    sessions.insert(session, at: 0)
    activeSession = nil
    restTimerEndDate = nil
    workoutRestOverrideSeconds = nil
    completedExerciseIDs = []
    activeExerciseIDsOverride = nil
    activePlanOverrides = [:]
    activeSupersetGroups = [:]
    status = "Saved \(session.workingSets.count) working sets"
    flushPendingSave()
    return session
  }

  private func linkEarliestScheduledWorkout(
    to session: LiftSession,
    calendar: Calendar = .current
  ) {
    guard let routineID = session.routineID else { return }
    let candidates = scheduledWorkouts.indices
      .filter { index in
        let workout = scheduledWorkouts[index]
        return workout.routineID == routineID
          && workout.completedSessionID == nil
          && calendar.isDate(workout.plannedAt, inSameDayAs: session.startedAt)
      }
      .sorted { lhs, rhs in
        Self.scheduledAscending(scheduledWorkouts[lhs], scheduledWorkouts[rhs])
      }
    guard let index = candidates.first else { return }
    scheduledWorkouts[index].completedSessionID = session.id
  }

  func discardActiveSession() {
    let discardedSessionID = activeSession?.id
    activeSession = nil
    restTimerEndDate = nil
    workoutRestOverrideSeconds = nil
    completedExerciseIDs = []
    activeExerciseIDsOverride = nil
    activePlanOverrides = [:]
    activeSupersetGroups = [:]
    status = "Discarded active lift"
    save()
    LiftLiveActivityManager.shared.discard(sessionID: discardedSessionID)
  }

  @discardableResult
  func logSet(
    exercise: LiftExercise,
    weight: Double,
    reps: Int,
    rpe: Double,
    isWarmup: Bool,
    notes: String = "",
    restSeconds: TimeInterval? = nil
  ) -> LiftSetOutcome? {
    guard var session = activeSession else { return nil }
    let nextSetNumber = session.sets.filter { $0.exerciseID == exercise.id }.count + 1
    let set = LiftSet(
      id: UUID(),
      exerciseID: exercise.id,
      setNumber: nextSetNumber,
      weight: weight,
      reps: max(reps, 1),
      rpe: rpe,
      isWarmup: isWarmup,
      completedAt: Date(),
      notes: notes
    )
    let personalRecord = personalRecord(for: set, exerciseID: exercise.id)
    session.sets.append(set)
    activeSession = session
    let now = Date()
    // A newly logged set always starts a new recovery window, even when the
    // previous set's timer is still running.
    restTimerEndDate = now.addingTimeInterval(max(restSeconds ?? defaultRestSeconds, 0))
    status = "Logged \(exercise.name) \(set.setNumber): \(liftLoad(weight, for: exercise)) x \(set.reps)"
    save()
    syncLiveActivity()
    return LiftSetOutcome(set: set, personalRecord: personalRecord)
  }

  func addExercise(name: String, muscleGroup: String, equipment: String, instructions: String) {
    let exercise = LiftExercise(
      id: UUID(),
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      muscleGroup: muscleGroup.trimmingCharacters(in: .whitespacesAndNewlines),
      equipment: equipment.trimmingCharacters(in: .whitespacesAndNewlines),
      instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    guard !exercise.name.isEmpty else { return }
    userExercises.append(exercise)
    rebuildRuntimeExercises()
    status = "Added \(exercise.name)"
    save()
  }

  func startRestTimer(seconds: TimeInterval) {
    restTimerEndDate = Date().addingTimeInterval(max(seconds, 0))
    save()
    syncLiveActivity()
  }

  func setDefaultRestSeconds(_ seconds: TimeInterval) {
    defaultRestSeconds = min(max(seconds, 15), 600)
    settings.defaultRestSeconds = defaultRestSeconds
    status = "Default rest \(Int(defaultRestSeconds))s"
    save()
  }

  func updateSettings(_ settings: LiftSettings) {
    var validated = settings
    validated.defaultRestSeconds = min(max(settings.defaultRestSeconds, 15), 600)
    self.settings = validated
    defaultRestSeconds = validated.defaultRestSeconds
    status = "Settings updated"
    save()
  }

  func setWorkoutRestOverride(seconds: TimeInterval?) {
    workoutRestOverrideSeconds = seconds.map { min(max($0, 15), 600) }
    if let workoutRestOverrideSeconds {
      status = "Workout rest \(Int(workoutRestOverrideSeconds))s"
    } else {
      status = "Using planned rest"
    }
    save()
    syncLiveActivity()
  }

  func adjustRestTimer(by seconds: TimeInterval) {
    let base = restTimerEndDate ?? Date()
    restTimerEndDate = max(base.addingTimeInterval(seconds), Date())
    save()
    syncLiveActivity()
  }

  func skipRestTimer() {
    restTimerEndDate = nil
    save()
    syncLiveActivity()
  }

  func isExerciseDone(_ exerciseID: UUID) -> Bool {
    completedExerciseIDs.contains(exerciseID)
  }

  func setExerciseDone(_ exerciseID: UUID, isDone: Bool) {
    if isDone {
      completedExerciseIDs.insert(exerciseID)
      status = "Finished \(exerciseName(for: exerciseID))"
    } else {
      completedExerciseIDs.remove(exerciseID)
      status = "Reopened \(exerciseName(for: exerciseID))"
    }
    save()
    syncLiveActivity()
  }

  func addActiveExercise(_ exerciseID: UUID) {
    guard activeSession != nil, exercise(for: exerciseID) != nil else { return }
    var ids = activeExerciseIDsOverride ?? activeExercises.map(\.id)
    guard !ids.contains(exerciseID) else { return }
    ids.append(exerciseID)
    activeExerciseIDsOverride = ids
    status = "Added \(exerciseName(for: exerciseID)) to this lift"
    save()
    syncLiveActivity()
  }

  func replaceActiveExercise(_ oldExerciseID: UUID, with newExerciseID: UUID) {
    guard activeSession != nil,
          oldExerciseID != newExerciseID,
          let newExercise = exercise(for: newExerciseID)
    else { return }

    var ids = activeExerciseIDsOverride ?? activeExercises.map(\.id)
    if let oldIndex = ids.firstIndex(of: oldExerciseID) {
      if let duplicateIndex = ids.firstIndex(of: newExerciseID), duplicateIndex != oldIndex {
        ids.remove(at: oldIndex)
      } else {
        ids[oldIndex] = newExerciseID
      }
    } else if !ids.contains(newExerciseID) {
      ids.append(newExerciseID)
    }

    if let oldPlan = activePlan(for: oldExerciseID) {
      activePlanOverrides[newExerciseID] = LiftRoutineExercisePlan(
        id: oldPlan.id,
        exerciseID: newExerciseID,
        sets: oldPlan.sets,
        reps: oldPlan.reps,
        rest: oldPlan.rest,
        targetEffort: oldPlan.targetEffort,
        notes: "Swapped from \(exerciseName(for: oldExerciseID)). \(oldPlan.notes)"
      )
      activePlanOverrides[oldExerciseID] = nil
    }

    activeExerciseIDsOverride = ids
    if let group = activeSupersetGroups[oldExerciseID] {
      activeSupersetGroups[newExerciseID] = group
      activeSupersetGroups[oldExerciseID] = nil
    }
    completedExerciseIDs.remove(oldExerciseID)
    completedExerciseIDs.remove(newExerciseID)
    status = "Swapped to \(newExercise.name)"
    save()
    syncLiveActivity()
  }

  func supersetLabel(for exerciseID: UUID) -> String? {
    guard let group = activeSupersetGroups[exerciseID] else { return nil }
    return "SS \(Self.supersetName(for: group))"
  }

  func supersetPartners(for exerciseID: UUID) -> [LiftExercise] {
    guard let group = activeSupersetGroups[exerciseID] else { return [] }
    return activeExercises.filter { $0.id != exerciseID && activeSupersetGroups[$0.id] == group }
  }

  func setSuperset(_ exerciseID: UUID, with partnerID: UUID) {
    guard activeSession != nil,
          exerciseID != partnerID,
          activeExercises.contains(where: { $0.id == exerciseID }),
          activeExercises.contains(where: { $0.id == partnerID })
    else { return }

    let group = activeSupersetGroups[exerciseID]
      ?? activeSupersetGroups[partnerID]
      ?? ((activeSupersetGroups.values.max() ?? 0) + 1)
    activeSupersetGroups[exerciseID] = group
    activeSupersetGroups[partnerID] = group
    status = "\(exerciseName(for: exerciseID)) superset with \(exerciseName(for: partnerID))"
    save()
  }

  func clearSuperset(for exerciseID: UUID) {
    guard let group = activeSupersetGroups[exerciseID] else { return }
    activeSupersetGroups[exerciseID] = nil
    let remaining = activeSupersetGroups.filter { $0.value == group }.map(\.key)
    if remaining.count < 2 {
      for id in remaining {
        activeSupersetGroups[id] = nil
      }
    }
    status = "Cleared superset for \(exerciseName(for: exerciseID))"
    save()
  }

  func restRemaining(at date: Date = Date()) -> TimeInterval {
    guard let restTimerEndDate else { return 0 }
    return max(restTimerEndDate.timeIntervalSince(date), 0)
  }

  private func syncLiveActivity() {
    guard let activeSession else {
      LiftLiveActivityManager.shared.discard(sessionID: nil)
      return
    }
    let progress = activeRoutineProgress()
    LiftLiveActivityManager.shared.sync(
      session: activeSession,
      progress: progress,
      currentMove: liveActivityMoveName(for: progress),
      restTimerEndDate: restTimerEndDate
    )
  }

  private func liveActivityMoveName(for progress: LiftRoutineProgress?) -> String {
    guard !activeExercises.isEmpty else { return "Open lift" }
    let index = min(max((progress?.currentExerciseIndex ?? 1) - 1, 0), activeExercises.count - 1)
    return activeExercises[index].name
  }

  func sets(for exerciseID: UUID, includeActive: Bool = false) -> [LiftSet] {
    let saved = sessions.flatMap(\.sets).filter { $0.exerciseID == exerciseID }
    let active = includeActive ? (activeSession?.sets.filter { $0.exerciseID == exerciseID } ?? []) : []
    return (saved + active).sorted { $0.completedAt > $1.completedAt }
  }

  func suggestedWeight(for exerciseID: UUID) -> Double {
    sets(for: exerciseID, includeActive: true).first?.weight ?? defaultWeight(for: exerciseID)
  }

  func suggestedReps(for exerciseID: UUID) -> Int {
    sets(for: exerciseID, includeActive: true).first?.reps ?? 8
  }

  func previousBestEstimatedOneRepMax(for exerciseID: UUID) -> Double {
    sessions
      .flatMap(\.sets)
      .filter { $0.exerciseID == exerciseID && !$0.isWarmup }
      .map(\.estimatedOneRepMax)
      .max() ?? 0
  }

  func personalRecord(for candidate: LiftSet, exerciseID: UUID) -> LiftPersonalRecord? {
    guard !candidate.isWarmup, candidate.exerciseID == exerciseID else { return nil }

    let completedSets = sessions
      .filter { $0.endedAt != nil }
      .flatMap(\.sets)
    let activeSets = activeSession?.sets ?? []
    let history = (completedSets + activeSets).filter {
      $0.exerciseID == exerciseID && !$0.isWarmup && $0.id != candidate.id
    }
    guard !history.isEmpty else { return nil }

    let previousBestEstimatedOneRepMax = history
      .map(\.estimatedOneRepMax)
      .max() ?? 0
    if candidate.weight > 0,
       candidate.estimatedOneRepMax > previousBestEstimatedOneRepMax {
      return LiftPersonalRecord(
        kind: .estimatedOneRepMax,
        value: candidate.estimatedOneRepMax,
        previousBest: previousBestEstimatedOneRepMax
      )
    }

    let previousBestReps = history
      .filter { $0.weight >= candidate.weight }
      .map(\.reps)
      .max()
    guard let previousBestReps, candidate.reps > previousBestReps else { return nil }
    return LiftPersonalRecord(
      kind: .reps,
      value: Double(candidate.reps),
      previousBest: Double(previousBestReps)
    )
  }

  func volumePoints(for exerciseID: UUID) -> [VolumePoint] {
    let grouped = Dictionary(grouping: sets(for: exerciseID)) { set in
      Calendar.current.startOfDay(for: set.completedAt)
    }
    return grouped.map { date, sets in
      VolumePoint(
        date: date,
        volume: sets.reduce(0) { $0 + $1.volume },
        bestEstimatedOneRepMax: sets.map(\.estimatedOneRepMax).max() ?? 0
      )
    }
    .sorted { $0.date < $1.date }
  }

  func exerciseName(for id: UUID) -> String {
    exercises.first { $0.id == id }?.name ?? "Exercise"
  }

  func exercise(for id: UUID) -> LiftExercise? {
    exercises.first { $0.id == id }
  }

  func activePlan(for exerciseID: UUID) -> LiftRoutineExercisePlan? {
    if activeExerciseIDsOverride != nil {
      return activePlanOverrides[exerciseID]
    }
    guard let routineID = activeSession?.routineID,
          let routine = routines.first(where: { $0.id == routineID })
    else { return nil }
    return routine.exercisePlans?.first { $0.exerciseID == exerciseID }
  }

  func nextUnfinishedExerciseID(after exerciseID: UUID?) -> UUID? {
    let ids = activeExercises.map(\.id)
    guard !ids.isEmpty else { return nil }

    let orderedCandidates: [UUID]
    if let exerciseID, let index = ids.firstIndex(of: exerciseID) {
      orderedCandidates = Array(ids[(index + 1)...]) + Array(ids[..<index])
    } else {
      orderedCandidates = ids
    }

    return orderedCandidates.first { id in
      !completedExerciseIDs.contains(id) && !setProgress(for: id).isComplete
    }
  }

  func plannedRestSeconds(for exerciseID: UUID) -> TimeInterval? {
    guard let plan = activePlan(for: exerciseID) else { return nil }
    return Self.restSeconds(from: plan.rest)
  }

  func estimatedMinutes(for routine: LiftRoutine) -> Int {
    Self.estimatedMinutes(
      plans: routine.exercisePlans ?? [],
      defaultRestSeconds: defaultRestSeconds
    )
  }

  nonisolated static func estimatedMinutes(
    plans: [LiftRoutineExercisePlan],
    defaultRestSeconds: TimeInterval
  ) -> Int {
    var contributorCount = 0
    let seconds = plans.reduce(0.0) { total, plan in
      guard let sets = setCount(from: plan.sets), sets > 0 else { return total }
      contributorCount += 1
      let rest = restSeconds(from: plan.rest) ?? defaultRestSeconds
      return total + Double(sets) * (45 + max(rest, 0))
    }
    guard contributorCount > 0 else { return 0 }
    let rounded = ((seconds / 60) / 5).rounded(.toNearestOrAwayFromZero) * 5
    return max(5, Int(rounded))
  }

  func restSecondsForNextSet(for exerciseID: UUID) -> TimeInterval {
    workoutRestOverrideSeconds ?? plannedRestSeconds(for: exerciseID) ?? defaultRestSeconds
  }

  func setProgress(for exerciseID: UUID, includeActive _: Bool = true) -> LiftSetProgress {
    let completed = activeSession?.sets.filter {
      $0.exerciseID == exerciseID && !$0.isWarmup
    }.count ?? 0
    let target = activePlan(for: exerciseID).flatMap { Self.setCount(from: $0.sets) }
    return LiftSetProgress(completed: completed, target: target)
  }

  func activeRoutineProgress() -> LiftRoutineProgress? {
    let exercises = activeExercises
    guard !exercises.isEmpty else { return nil }
    let progress = exercises.map { setProgress(for: $0.id) }
    let targetSets = progress.reduce(0) { total, item in
      total + (item.target ?? max(item.completed, 1))
    }
    let completedSets = progress.enumerated().reduce(0) { total, pair in
      let item = pair.element
      return total + min(item.completed, item.target ?? item.completed)
    }
    let currentIndex = exercises.enumerated().first { pair in
      !completedExerciseIDs.contains(pair.element.id) && !progress[pair.offset].isComplete
    }.map { $0.offset + 1 } ?? exercises.count
    return LiftRoutineProgress(
      completedSets: completedSets,
      targetSets: max(targetSets, completedSets),
      currentExerciseIndex: currentIndex,
      exerciseCount: exercises.count
    )
  }

  func warmupPlan(for exercise: LiftExercise, workingWeight: Double, workingReps: Int) -> LiftWarmupPlan {
    let progress = setProgress(for: exercise.id)
    if progress.completed >= 2 {
      return LiftWarmupPlan(
        title: "Probably Skip",
        reason: "You already have \(progress.completed) work sets logged here. Keep the next set clean unless the weight jumps hard.",
        sets: []
      )
    }

    if progress.completed == 1 {
      return LiftWarmupPlan(
        title: "Optional Primer",
        reason: "You have a work set in. Only add this if the next load feels like a big jump.",
        sets: [
          LiftWarmupSet(sequence: 1, percent: 0.55, weight: Self.roundedWarmupWeight(workingWeight * 0.55), reps: min(max(workingReps, 5), 8), note: "easy groove")
        ]
      )
    }

    if liftUsesBodyweightLoad(exercise) {
      return LiftWarmupPlan(
        title: "Movement Prep",
        reason: "Bodyweight work does not need a loaded ramp. Use one easy technical set if the first work set will be hard.",
        sets: [
          LiftWarmupSet(sequence: 1, percent: nil, weight: 0, reps: min(max(workingReps, 5), 8), note: "easy tempo")
        ]
      )
    }

    if workingWeight <= 0 {
      return LiftWarmupPlan(
        title: "Set Load First",
        reason: "Add the working weight to calculate a real ramp. Until then, use one easy technique set on the machine.",
        sets: [
          LiftWarmupSet(sequence: 1, percent: nil, weight: 0, reps: min(max(workingReps, 5), 8), note: "easy setup")
        ]
      )
    }

    let ramp: [(Double, Int, String)]
    switch workingWeight {
    case ..<45:
      ramp = [(0.50, min(max(workingReps, 6), 10), "easy feeler")]
    case ..<95:
      ramp = [(0.50, 8, "easy feeler"), (0.75, 3, "fast reps")]
    case ..<185:
      ramp = [(0.40, 8, "easy feeler"), (0.60, 5, "smooth"), (0.80, 2, "primer")]
    default:
      ramp = [(0.35, 8, "easy feeler"), (0.55, 5, "smooth"), (0.70, 3, "build"), (0.85, 1, "primer")]
    }

    let sets = ramp.enumerated().map { index, item in
      LiftWarmupSet(
        sequence: index + 1,
        percent: item.0,
        weight: Self.roundedWarmupWeight(workingWeight * item.0),
        reps: item.1,
        note: item.2
      )
    }

    return LiftWarmupPlan(
      title: "\(sets.count) Ramp \(sets.count == 1 ? "Set" : "Sets")",
      reason: "Conservative ramp from your current working weight so the warm-up primes the lift without adding junk fatigue.",
      sets: sets
    )
  }

  nonisolated static func restSeconds(from rest: String) -> TimeInterval? {
    let normalized = rest
      .lowercased()
      .replacingOccurrences(of: "–", with: "-")
      .replacingOccurrences(of: "—", with: "-")
    let multiplier: Double = normalized.contains("min") ? 60 : 1
    let parts = normalized.split { character in
      !(character.isNumber || character == ".")
    }
    let numbers = parts.compactMap { Double($0) }
    guard let upperBound = numbers.max() else { return nil }
    return upperBound * multiplier
  }

  nonisolated static func setCount(from sets: String) -> Int? {
    let numbers = sets.split { !$0.isNumber }.compactMap { Int($0) }
    return numbers.max()
  }

  nonisolated static func roundedWarmupWeight(_ weight: Double) -> Double {
    guard weight > 0 else { return 0 }
    return max(5, (weight / 5).rounded() * 5)
  }

  nonisolated static func supersetName(for group: Int) -> String {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    guard group > 0 else { return "A" }
    if group <= alphabet.count {
      return String(alphabet[group - 1])
    }
    return "\(group)"
  }

  private func performLoad() async {
    do {
      _ = await Task.detached(priority: .utility) { LiftExerciseCatalog.catalogExercises() }.value
      let result: LiftPersistenceLoadResult
      if let database {
        if let envelope = try await database.load() { result = .loaded(envelope) }
        else { result = .fresh }
      } else { result = try await persistence.load() }
      switch result {
      case .fresh:
        seed()
        status = "Seeded report-based routine bank"
        flushPendingSave()
      case let .loaded(envelope):
        apply(envelope)
        status = "Loaded \(sessions.count) sessions"
      case let .migrated(envelope):
        apply(envelope)
        status = "Migrated \(sessions.count) sessions"
      }
      didFinishLoad = true
      syncLiveActivity()
    } catch let LiftPersistenceError.unsupportedSchema(version) {
      didLoad = false
      databaseSaveError = "Unsupported schema version \(version)"
      status = databaseSaveError ?? "Load failed"
    } catch {
      didLoad = false
      databaseSaveError = error.localizedDescription
      status = "Load failed: \(error.localizedDescription)"
    }
  }

  private func apply(_ envelope: LiftDataEnvelope) {
    starterBankVersion = envelope.starterBankVersion
    userExercises = envelope.userExercises
    rebuildRuntimeExercises()
    routines = envelope.routines
    scheduledWorkouts = envelope.scheduledWorkouts
    sessions = envelope.sessions
    activeSession = envelope.activeSession
    restTimerEndDate = envelope.restTimerEndDate
    workoutRestOverrideSeconds = envelope.workoutRestOverrideSeconds
    completedExerciseIDs = envelope.completedExerciseIDs
    activeExerciseIDsOverride = envelope.activeExerciseIDsOverride
    activePlanOverrides = envelope.activePlanOverrides
    activeSupersetGroups = envelope.activeSupersetGroups
    settings = envelope.settings
    defaultRestSeconds = envelope.settings.defaultRestSeconds
    applyStarterBankUpdatesIfNeeded()
  }

  private func rebuildRuntimeExercises() {
    var seenNames = Set<String>()
    var runtimeExercises: [LiftExercise] = []

    for exercise in userExercises {
      let key = LiftExerciseCatalog.normalizedName(exercise.name)
      guard !seenNames.contains(key) else { continue }
      runtimeExercises.append(exercise)
      seenNames.insert(key)
    }

    for exercise in LiftExerciseCatalog.catalogExercises() {
      let key = LiftExerciseCatalog.normalizedName(exercise.name)
      guard !seenNames.contains(key) else { continue }
      runtimeExercises.append(exercise)
      seenNames.insert(key)
    }

    exercises = runtimeExercises.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  private func seed() {
    let bank = LiftRoutineBank.make()
    userExercises = bank.exercises
    rebuildRuntimeExercises()
    routines = bank.routineTemplates.map { makeStarterRoutine(from: $0, name: $0.name) }
    sessions = []
    activeSession = nil
    restTimerEndDate = nil
    workoutRestOverrideSeconds = nil
    completedExerciseIDs = []
    activeExerciseIDsOverride = nil
    activePlanOverrides = [:]
    activeSupersetGroups = [:]
    defaultRestSeconds = 90
    settings = LiftSettings()
    scheduledWorkouts = []
    starterBankVersion = LiftDataEnvelope.currentStarterBankVersion
  }

  func restoreStarterRoutine(named name: String) {
    let bank = LiftRoutineBank.make()
    guard let template = bank.routineTemplates.first(where: { $0.name == name }) else { return }
    ensureStarterExercises(bank.exercises)
    let restoredName = uniqueStarterName(for: template.name)
    routines.append(makeStarterRoutine(from: template, name: restoredName))
    status = "Restored \(restoredName)"
    save()
  }

  private func applyStarterBankUpdatesIfNeeded() {
    guard starterBankVersion < LiftDataEnvelope.currentStarterBankVersion else { return }
    let bank = LiftRoutineBank.make()
    ensureStarterExercises(bank.exercises)
    var routineNames = Set(routines.map { LiftExerciseCatalog.normalizedName($0.name) })
    for template in bank.routineTemplates {
      let key = LiftExerciseCatalog.normalizedName(template.name)
      guard !routineNames.contains(key) else { continue }
      routines.append(makeStarterRoutine(from: template, name: template.name))
      routineNames.insert(key)
    }
    starterBankVersion = LiftDataEnvelope.currentStarterBankVersion
    save()
  }

  private func ensureStarterExercises(_ starterExercises: [LiftExercise]) {
    var seenNames = Set(userExercises.map { LiftExerciseCatalog.normalizedName($0.name) })
    for exercise in starterExercises {
      let key = LiftExerciseCatalog.normalizedName(exercise.name)
      guard !seenNames.contains(key) else { continue }
      userExercises.append(exercise)
      seenNames.insert(key)
    }
    rebuildRuntimeExercises()
  }

  private func makeStarterRoutine(
    from template: LiftRoutineBank.RoutineTemplate,
    name: String
  ) -> LiftRoutine {
    let exerciseByName = exercises.reduce(into: [String: LiftExercise]()) { result, exercise in
      let key = LiftExerciseCatalog.normalizedName(exercise.name)
      result[key] = result[key] ?? exercise
    }
    let plans = template.plans.compactMap { plan -> LiftRoutineExercisePlan? in
      guard let exercise = exerciseByName[LiftExerciseCatalog.normalizedName(plan.exerciseName)] else { return nil }
      return LiftRoutineExercisePlan(
        id: UUID(),
        exerciseID: exercise.id,
        sets: plan.sets,
        reps: plan.reps,
        rest: plan.rest,
        targetEffort: plan.targetEffort,
        notes: plan.notes
      )
    }
    return LiftRoutine(
      id: UUID(),
      name: name,
      notes: template.notes,
      trainingMode: template.trainingMode,
      exerciseIDs: plans.map(\.exerciseID),
      exercisePlans: plans
    )
  }

  private func uniqueStarterName(for baseName: String) -> String {
    let existing = Set(routines.map { LiftExerciseCatalog.normalizedName($0.name) })
    let first = "\(baseName) (Starter)"
    guard existing.contains(LiftExerciseCatalog.normalizedName(first)) else { return first }
    var suffix = 2
    while existing.contains(LiftExerciseCatalog.normalizedName("\(baseName) (Starter \(suffix))")) {
      suffix += 1
    }
    return "\(baseName) (Starter \(suffix))"
  }

  func materializedPlans(for routine: LiftRoutine) -> [LiftRoutineExercisePlan] {
    if let plans = routine.exercisePlans {
      return Self.canonicalPlans(plans)
    }
    var seen = Set<UUID>()
    return routine.exerciseIDs.compactMap { exerciseID in
      guard seen.insert(exerciseID).inserted else { return nil }
      return LiftRoutineExercisePlan(
        id: UUID(), exerciseID: exerciseID, sets: "3", reps: "8-12", rest: "90 s",
        targetEffort: "2 RIR", notes: ""
      )
    }
  }

  private func canonicalRoutine(_ routine: LiftRoutine) -> LiftRoutine {
    let plans = routine.exercisePlans.map(Self.canonicalPlans) ?? materializedPlans(for: routine)
    return LiftRoutine(
      id: routine.id,
      name: canonicalRoutineName(routine.name),
      notes: routine.notes,
      trainingMode: routine.trainingMode,
      exerciseIDs: plans.map(\.exerciseID),
      exercisePlans: plans
    )
  }

  private func canonicalRoutineName(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Untitled Routine" : trimmed
  }

  private nonisolated static func canonicalPlans(
    _ plans: [LiftRoutineExercisePlan]
  ) -> [LiftRoutineExercisePlan] {
    var seen = Set<UUID>()
    return plans.filter { seen.insert($0.exerciseID).inserted }
  }

  private nonisolated static func moving<Element>(
    _ elements: [Element],
    from source: IndexSet,
    to destination: Int
  ) -> [Element] {
    let validSource = source.filter { elements.indices.contains($0) }
    guard !validSource.isEmpty else { return elements }
    let movingElements = validSource.map { elements[$0] }
    var remaining = elements.enumerated()
      .filter { !validSource.contains($0.offset) }
      .map(\.element)
    let removedBeforeDestination = validSource.filter { $0 < destination }.count
    let insertion = min(max(destination - removedBeforeDestination, 0), remaining.count)
    remaining.insert(contentsOf: movingElements, at: insertion)
    return remaining
  }

  private func defaultWeight(for exerciseID: UUID) -> Double {
    guard let exercise = exercises.first(where: { $0.id == exerciseID }) else { return 0 }
    switch exercise.name {
    case "Machine Chest Press": return 0
    case "Incline Dumbbell Press": return 70
    case "Machine Shoulder Press": return 0
    case "Hack Squat": return 0
    case "Leg Press": return 0
    case "Romanian Deadlift": return 225
    case "Lat Pulldown": return 160
    case "Chest-Supported Row": return 140
    case "Cable Curl": return 45
    default: return 0
    }
  }

  private func save() {
    if database != nil { scheduleDatabaseSave(debounce: true); return }
    saveGeneration += 1
    let generation = saveGeneration
    let envelope = persistenceEnvelope()
    persistence.scheduleWrite(
      envelope,
      generation: generation,
      delay: saveDebounceInterval
    ) { [weak self] errorMessage in
      guard let errorMessage else { return }
      Task { @MainActor [weak self] in
        self?.status = "Save failed: \(errorMessage)"
      }
    }
  }

  func flushPendingSave() {
    if database != nil { scheduleDatabaseSave(debounce: false); return }
    saveGeneration += 1
    do {
      try persistence.writeSynchronously(persistenceEnvelope(), generation: saveGeneration)
    } catch {
      status = "Save failed: \(error.localizedDescription)"
    }
  }

  func applicationDidEnterBackground() {
    guard !isFinishing, didFinishLoad else { return }
    flushPendingSave()
  }

  func waitForPendingSave() async {
    if let databaseTask { _ = try? await databaseTask.value; return }
    await persistence.waitUntilCommitted(saveGeneration)
  }

  func waitForScheduledWrites() async {
    if let databaseTask { _ = try? await databaseTask.value; return }
    await persistence.waitForScheduledWrites()
  }

  var persistenceWriteCount: Int {
    persistence.writeCount
  }

  var persistenceCodingRanOnMainThread: Bool? {
    persistence.lastCodingWasOnMainThread
  }

  private func scheduleDatabaseSave(debounce: Bool) {
    guard let database, !databaseInvalidated else { return }
    saveGeneration += 1
    let generation = saveGeneration
    let envelope = persistenceEnvelope()
    let delay = debounce ? saveDebounceInterval : 0
    databaseTask = Task { [weak self] in
      if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
      guard let self, !self.databaseInvalidated, generation == self.saveGeneration else { return }
      do {
        try await database.save(envelope, generation: generation)
        if generation == self.saveGeneration { self.databaseSaveError = nil }
      } catch {
        if generation == self.saveGeneration {
          self.databaseSaveError = error.localizedDescription
          self.status = "Save failed: \(error.localizedDescription)"
        }
        throw error
      }
    }
  }

  func finishActiveSessionDurably() async -> LiftSession? {
    guard !isFinishing, var session = activeSession, !databaseInvalidated else { return nil }
    isFinishing = true
    defer { isFinishing = false }
    if let previousFinish = finishDate, session.sets.contains(where: { $0.completedAt > previousFinish }) {
      finishDate = Date()
    } else { finishDate = finishDate ?? Date() }
    guard let database else {
      let retained = persistenceEnvelope()
      let result = finishActiveSession()
      if status.hasPrefix("Save failed:") { apply(retained); return nil }
      finishDate = nil
      return result
    }
    session.endedAt = finishDate
    var completed = persistenceEnvelope()
    completed.sessions.insert(session, at: 0)
    completed.activeSession = nil
    completed.restTimerEndDate = nil
    completed.workoutRestOverrideSeconds = nil
    completed.completedExerciseIDs = []
    completed.activeExerciseIDsOverride = nil
    completed.activePlanOverrides = [:]
    completed.activeSupersetGroups = [:]
    if let routineID = session.routineID,
       let index = completed.scheduledWorkouts.indices.filter({
         let item = completed.scheduledWorkouts[$0]
         return item.routineID == routineID && item.completedSessionID == nil
           && Calendar.current.isDate(item.plannedAt, inSameDayAs: session.startedAt)
       }).min(by: { completed.scheduledWorkouts[$0].plannedAt < completed.scheduledWorkouts[$1].plannedAt }) {
      completed.scheduledWorkouts[index].completedSessionID = session.id
    }
    saveGeneration += 1
    let generation = saveGeneration
    let envelope = completed
    let task = Task { try await database.save(envelope, generation: generation) }
    databaseTask = task
    do {
      try await task.value
      guard !databaseInvalidated else { return nil }
      let progress = activeRoutineProgress()
      LiftLiveActivityManager.shared.finish(session: session, progress: progress,
        currentMove: liveActivityMoveName(for: progress), restTimerEndDate: nil)
      apply(envelope)
      databaseSaveError = nil
      status = "Saved \(session.workingSets.count) working sets"
      finishDate = nil
      return session
    } catch {
      databaseSaveError = error.localizedDescription
      status = "Couldn’t save. Your active session is retained. Retry Finish."
      return nil
    }
  }

  func cancelDatabasePersistence() {
    databaseInvalidated = true
    databaseTask?.cancel()
    activeSession = nil
    restTimerEndDate = nil
    LiftLiveActivityManager.shared.discard(sessionID: nil)
  }

  private func persistenceEnvelope() -> LiftDataEnvelope {
    LiftDataEnvelope(
      schemaVersion: LiftDataEnvelope.currentSchemaVersion,
      starterBankVersion: starterBankVersion,
      userExercises: userExercises,
      routines: routines,
      scheduledWorkouts: scheduledWorkouts,
      sessions: sessions,
      activeSession: activeSession,
      restTimerEndDate: restTimerEndDate,
      workoutRestOverrideSeconds: workoutRestOverrideSeconds,
      completedExerciseIDs: completedExerciseIDs,
      activeExerciseIDsOverride: activeExerciseIDsOverride,
      activePlanOverrides: activePlanOverrides,
      activeSupersetGroups: activeSupersetGroups,
      settings: settings
    )
  }
}

private enum LiftRoutineBank {
  struct RoutineTemplate {
    var name: String
    var notes: String
    var trainingMode: TrainingMode
    var plans: [Plan]
  }

  struct Plan {
    var exerciseName: String
    var sets: String
    var reps: String
    var rest: String
    var targetEffort: String
    var notes: String
  }

  static func make() -> (exercises: [LiftExercise], routineTemplates: [RoutineTemplate]) {
    let exercises = [
      ex("Machine Chest Press", "Chest", "Machine", "Main strength-biased press. Reduce ROM if wrist or shoulder discomfort appears."),
      ex("Pull-Up", "Back", "Bodyweight", "Use assistance or load as needed. Add load when top reps are solid."),
      ex("Incline Dumbbell Press", "Chest", "Dumbbells", "Prefer neutral or semi-neutral wrist if it feels cleaner."),
      ex("Chest-Supported Row", "Back", "Machine", "Posture-friendly row with low spinal fatigue. Pause on the squeeze."),
      ex("Cable Fly or Pec Deck", "Chest", "Cable/Machine", "Stop shy of painful deep stretch if needed."),
      ex("Rope Pushdown", "Triceps", "Cable", "Keep upper arms quiet and control the return."),
      ex("Cable Curl", "Biceps", "Cable", "Controlled eccentric; superset with pushdowns when short on time."),
      ex("Hanging Knee Raise", "Abs", "Bodyweight", "Direct abs priority. Use controlled reps, not swinging."),
      ex("Leg Press", "Quads", "Machine", "Main quad strength lift. Full pain-free ROM."),
      ex("Romanian Deadlift", "Hamstrings", "Barbell", "Posterior-chain anchor. Keep technique crisp and lats tight."),
      ex("Seated Leg Curl", "Hamstrings", "Machine", "Long-length hamstring work with controlled reps."),
      ex("Walking Lunge", "Legs", "Dumbbells", "Running-supportive accessory. Keep it smooth, not sloppy."),
      ex("Leg Extension", "Quads", "Machine", "Pure quad volume without extra systemic fatigue."),
      ex("Calf Raise", "Calves", "Machine", "Pause at the stretch and peak."),
      ex("Side Plank", "Core", "Bodyweight", "Hold clean position until technical failure."),
      ex("T-Bar Row", "Back", "Machine/Barbell", "Heavier back work. Keep torso stable."),
      ex("Lat Pulldown", "Back", "Cable", "Drive elbows down. Use pull-ups instead when shoulders feel great."),
      ex("Machine Row or Cable Row", "Back", "Machine/Cable", "Emphasize scapular control."),
      ex("Straight-Arm Pulldown", "Lats", "Cable", "High-preference lat drill. Keep ribs down."),
      ex("Rear-Delt Fly", "Rear Delts", "Machine/Cable", "High-value for aesthetics and posture."),
      ex("Face Pull", "Rear Delts", "Cable", "Keep elbows slightly below shoulder height."),
      ex("Incline Dumbbell Curl", "Biceps", "Dumbbells", "Long-length biceps work with controlled shoulders."),
      ex("Hammer Curl", "Biceps", "Dumbbells", "Forearm and brachialis support."),
      ex("Dead Hang", "Grip/Posture", "Bar", "Optional decompression, not a max grip test."),
      ex("Machine Shoulder Press", "Shoulders", "Machine", "Use only if shoulder pain stays 0-2."),
      ex("Smith Incline Press", "Chest", "Smith Machine", "Safer pressing slot than barbell bench for this plan."),
      ex("Cable Lateral Raise", "Side Delts", "Cable", "Side-delt priority. Smooth reps."),
      ex("Overhead Cable Extension", "Triceps", "Cable", "Long-head triceps option. Avoid elbow crankiness."),
      ex("Straight-Bar Pushdown", "Triceps", "Cable", "Swap to rope if elbows prefer it."),
      ex("Ab Machine or Cable Crunch", "Abs", "Machine/Cable", "Loaded ab work. Progress like other muscles."),
      ex("Pallof Press or Plank", "Core", "Cable/Bodyweight", "Anti-rotation or anti-extension trunk work."),
      ex("Hack Squat", "Quads", "Machine", "Moderate effort lower day lift. Not a grinder slot."),
      ex("Hip Thrust", "Glutes", "Machine/Barbell", "Glutes and running support."),
      ex("Lying Leg Curl", "Hamstrings", "Machine", "Hamstring volume without crushing recovery."),
      ex("Bulgarian Split Squat", "Legs", "Dumbbells", "Keep modest; do not chase nausea sets."),
      ex("Back Extension", "Posterior Chain", "Machine", "Posterior-chain and posture support."),
      ex("Russian Twist or Hanging Knee Raise", "Core", "Bodyweight", "Optional trunk finisher.")
    ]

    let routines = [
      RoutineTemplate(
        name: "Upper A",
        notes: "Chest, back, arms, abs. Pre-press primer: easy cardio plus pull-aparts, external rotations, face pulls or Y-raises.",
        trainingMode: .hypertrophy,
        plans: [
          plan("Machine Chest Press", "3", "5-8", "2-3 min", "2 RIR", "Main strength-biased press; reduce ROM if wrist/shoulder flare."),
          plan("Pull-Up", "3", "5-8", "2-3 min", "1-2 RIR", "Assisted or loaded as needed."),
          plan("Incline Dumbbell Press", "2-3", "8-10", "2 min", "1-2 RIR", "Neutral or semi-neutral wrist if cleaner."),
          plan("Chest-Supported Row", "3", "8-10", "2 min", "1-2 RIR", "Low spinal fatigue, posture-friendly row."),
          plan("Cable Fly or Pec Deck", "2", "12-15", "75 s", "0-2 RIR", "Avoid painful deep stretch."),
          plan("Rope Pushdown", "2", "10-15", "60-75 s", "0-1 RIR", "Superset with curls if short on time."),
          plan("Cable Curl", "2", "10-15", "60-75 s", "0-1 RIR", "Controlled eccentric."),
          plan("Hanging Knee Raise", "3", "8-15", "60 s", "1-2 RIR", "Direct abs priority.")
        ]
      ),
      RoutineTemplate(
        name: "Lower A",
        notes: "Heavier quads and posterior chain. No run scheduled.",
        trainingMode: .strength,
        plans: [
          plan("Leg Press", "3-4", "6-10", "2-3 min", "1-2 RIR", "Main quad strength lift; full pain-free ROM."),
          plan("Romanian Deadlift", "3", "6-8", "2-3 min", "1-2 RIR", "Posterior-chain anchor; technique crisp."),
          plan("Seated Leg Curl", "2-3", "10-12", "90 s", "0-2 RIR", "Long-length hamstring work."),
          plan("Walking Lunge", "2", "10-12/leg", "90 s", "1-2 RIR", "Running-supportive accessory."),
          plan("Leg Extension", "2", "12-15", "75 s", "0-1 RIR", "Quad volume without systemic fatigue."),
          plan("Calf Raise", "3", "8-12", "60-75 s", "0-2 RIR", "Pause at stretch and peak."),
          plan("Side Plank", "2", "30-45 s/side", "45 s", "Technical", "Trunk stability.")
        ]
      ),
      RoutineTemplate(
        name: "Pull + Posture",
        notes: "Back, rear delts, scapular control, biceps. Easy run can happen later if wanted.",
        trainingMode: .hypertrophy,
        plans: [
          plan("T-Bar Row", "3", "6-10", "2 min", "1-2 RIR", "Heavier back work."),
          plan("Lat Pulldown", "3", "8-12", "90 s", "1-2 RIR", "Use pull-ups if elbows/shoulders feel great."),
          plan("Machine Row or Cable Row", "2", "10-12", "90 s", "1-2 RIR", "Emphasize scapular control."),
          plan("Straight-Arm Pulldown", "2-3", "12-15", "60-75 s", "0-2 RIR", "High-preference lat drill."),
          plan("Rear-Delt Fly", "3", "12-20", "60-75 s", "0-2 RIR", "Aesthetics and posture."),
          plan("Face Pull", "2", "15-20", "60 s", "1-2 RIR", "Elbows slightly below shoulder height."),
          plan("Incline Dumbbell Curl", "2-3", "8-12", "60-75 s", "0-2 RIR", "Long-length biceps work."),
          plan("Hammer Curl", "2", "10-15", "60 s", "0-2 RIR", "Forearm and brachialis support."),
          plan("Dead Hang", "1-2", "20-40 s", "45 s", "Easy-moderate", "Optional decompression.")
        ]
      ),
      RoutineTemplate(
        name: "Push + Delts",
        notes: "Shoulders, chest, triceps, abs. Keep shoulder pain 0-2 on pressing slots.",
        trainingMode: .hypertrophy,
        plans: [
          plan("Machine Shoulder Press", "2-3", "6-10", "2 min", "1-2 RIR", "Only if shoulder pain stays 0-2."),
          plan("Smith Incline Press", "3", "8-10", "2 min", "1-2 RIR", "Safer pressing slot than barbell bench."),
          plan("Cable Fly or Pec Deck", "2", "12-15", "75 s", "0-2 RIR", "Stretch only as tolerated."),
          plan("Cable Lateral Raise", "3", "12-20", "60 s", "0-2 RIR", "Side-delt priority."),
          plan("Rear-Delt Fly", "2", "15-20", "60 s", "0-2 RIR", "Keep shoulders balanced."),
          plan("Overhead Cable Extension", "3", "10-15", "60-75 s", "0-2 RIR", "Long-head triceps option."),
          plan("Straight-Bar Pushdown", "2", "10-15", "60-75 s", "0-2 RIR", "Swap to rope if elbows prefer it."),
          plan("Ab Machine or Cable Crunch", "3", "10-15", "60 s", "0-2 RIR", "Loaded ab work."),
          plan("Pallof Press or Plank", "2", "10-15/side or 30-45 s", "45-60 s", "Controlled", "Anti-rotation or anti-extension.")
        ]
      ),
      RoutineTemplate(
        name: "Lower B",
        notes: "Runner-supportive lower day with calves and trunk. Moderate effort, not a grinder.",
        trainingMode: .hypertrophy,
        plans: [
          plan("Hack Squat", "3", "8-12", "2 min", "1-2 RIR", "Can use leg press instead."),
          plan("Hip Thrust", "3", "8-12", "90-120 s", "1-2 RIR", "Glutes and running support."),
          plan("Lying Leg Curl", "3", "10-15", "75-90 s", "0-2 RIR", "Hamstring volume."),
          plan("Bulgarian Split Squat", "2", "8-10/leg", "90 s", "1-2 RIR", "Or walking lunge; keep modest."),
          plan("Calf Raise", "3", "12-20", "60 s", "0-2 RIR", "Higher-rep calf work."),
          plan("Back Extension", "2", "10-15", "60-75 s", "1-2 RIR", "Posterior-chain and posture support."),
          plan("Russian Twist or Hanging Knee Raise", "2", "12-20 total", "45-60 s", "Controlled", "Optional trunk finisher.")
        ]
      )
    ]

    return (exercises, routines)
  }

  private static func ex(_ name: String, _ muscleGroup: String, _ equipment: String, _ instructions: String) -> LiftExercise {
    LiftExercise(id: UUID(), name: name, muscleGroup: muscleGroup, equipment: equipment, instructions: instructions)
  }

  private static func plan(
    _ exerciseName: String,
    _ sets: String,
    _ reps: String,
    _ rest: String,
    _ targetEffort: String,
    _ notes: String
  ) -> Plan {
    Plan(exerciseName: exerciseName, sets: sets, reps: reps, rest: rest, targetEffort: targetEffort, notes: notes)
  }
}
