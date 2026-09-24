import Foundation

struct LiftDataEnvelope: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 2
  static let currentStarterBankVersion = 1

  var schemaVersion: Int
  var starterBankVersion: Int
  var userExercises: [LiftExercise]
  var routines: [LiftRoutine]
  var scheduledWorkouts: [ScheduledWorkout]
  var sessions: [LiftSession]
  var activeSession: LiftSession?
  var restTimerEndDate: Date?
  var workoutRestOverrideSeconds: TimeInterval?
  var completedExerciseIDs: Set<UUID>
  var activeExerciseIDsOverride: [UUID]?
  var activePlanOverrides: [UUID: LiftRoutineExercisePlan]
  var activeSupersetGroups: [UUID: Int]
  var settings: LiftSettings

  init(
    schemaVersion: Int,
    starterBankVersion: Int,
    userExercises: [LiftExercise],
    routines: [LiftRoutine],
    scheduledWorkouts: [ScheduledWorkout],
    sessions: [LiftSession],
    activeSession: LiftSession?,
    restTimerEndDate: Date?,
    workoutRestOverrideSeconds: TimeInterval?,
    completedExerciseIDs: Set<UUID>,
    activeExerciseIDsOverride: [UUID]?,
    activePlanOverrides: [UUID: LiftRoutineExercisePlan],
    activeSupersetGroups: [UUID: Int],
    settings: LiftSettings
  ) {
    self.schemaVersion = schemaVersion
    self.starterBankVersion = starterBankVersion
    self.userExercises = userExercises
    self.routines = routines
    self.scheduledWorkouts = scheduledWorkouts
    self.sessions = sessions
    self.activeSession = activeSession
    self.restTimerEndDate = restTimerEndDate
    self.workoutRestOverrideSeconds = workoutRestOverrideSeconds
    self.completedExerciseIDs = completedExerciseIDs
    self.activeExerciseIDsOverride = activeExerciseIDsOverride
    self.activePlanOverrides = activePlanOverrides
    self.activeSupersetGroups = activeSupersetGroups
    self.settings = settings
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case starterBankVersion
    case userExercises
    case routines
    case scheduledWorkouts
    case sessions
    case activeSession
    case restTimerEndDate
    case workoutRestOverrideSeconds
    case completedExerciseIDs
    case activeExerciseIDsOverride
    case activePlanOverrides
    case activeSupersetGroups
    case settings
  }

  private enum LegacySettingsCodingKeys: String, CodingKey {
    case defaultRestSeconds
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    starterBankVersion = try container.decodeIfPresent(Int.self, forKey: .starterBankVersion) ?? 0
    userExercises = try container.decode([LiftExercise].self, forKey: .userExercises)
    routines = try container.decode([LiftRoutine].self, forKey: .routines)
    scheduledWorkouts = try container.decodeIfPresent([ScheduledWorkout].self, forKey: .scheduledWorkouts) ?? []
    sessions = try container.decode([LiftSession].self, forKey: .sessions)
    activeSession = try container.decodeIfPresent(LiftSession.self, forKey: .activeSession)
    restTimerEndDate = try container.decodeIfPresent(Date.self, forKey: .restTimerEndDate)
    workoutRestOverrideSeconds = try container.decodeIfPresent(
      TimeInterval.self,
      forKey: .workoutRestOverrideSeconds
    )
    completedExerciseIDs = try container.decodeIfPresent(
      Set<UUID>.self,
      forKey: .completedExerciseIDs
    ) ?? []
    activeExerciseIDsOverride = try container.decodeIfPresent(
      [UUID].self,
      forKey: .activeExerciseIDsOverride
    )
    activePlanOverrides = try container.decodeIfPresent(
      [UUID: LiftRoutineExercisePlan].self,
      forKey: .activePlanOverrides
    ) ?? [:]
    activeSupersetGroups = try container.decodeIfPresent(
      [UUID: Int].self,
      forKey: .activeSupersetGroups
    ) ?? [:]

    if let decodedSettings = try container.decodeIfPresent(LiftSettings.self, forKey: .settings) {
      settings = decodedSettings
    } else {
      let legacyContainer = try decoder.container(keyedBy: LegacySettingsCodingKeys.self)
      settings = LiftSettings(
        defaultRestSeconds: try legacyContainer.decodeIfPresent(
          TimeInterval.self,
          forKey: .defaultRestSeconds
        ) ?? 90
      )
    }
  }
}

struct LiftLegacyData: Codable, Equatable, Sendable {
  var exercises: [LiftExercise]
  var routines: [LiftRoutine]
  var sessions: [LiftSession]
  var activeSession: LiftSession?
  var restTimerEndDate: Date?
  var workoutRestOverrideSeconds: TimeInterval?
  var completedExerciseIDs: Set<UUID>
  var activeExerciseIDsOverride: [UUID]?
  var activePlanOverrides: [UUID: LiftRoutineExercisePlan]
  var activeSupersetGroups: [UUID: Int]
  var defaultRestSeconds: TimeInterval

  private enum CodingKeys: String, CodingKey {
    case exercises
    case routines
    case sessions
    case activeSession
    case restTimerEndDate
    case workoutRestOverrideSeconds
    case completedExerciseIDs
    case activeExerciseIDsOverride
    case activePlanOverrides
    case activeSupersetGroups
    case defaultRestSeconds
  }

  init(
    exercises: [LiftExercise],
    routines: [LiftRoutine],
    sessions: [LiftSession],
    activeSession: LiftSession?,
    restTimerEndDate: Date?,
    workoutRestOverrideSeconds: TimeInterval?,
    completedExerciseIDs: Set<UUID>,
    activeExerciseIDsOverride: [UUID]?,
    activePlanOverrides: [UUID: LiftRoutineExercisePlan],
    activeSupersetGroups: [UUID: Int],
    defaultRestSeconds: TimeInterval
  ) {
    self.exercises = exercises
    self.routines = routines
    self.sessions = sessions
    self.activeSession = activeSession
    self.restTimerEndDate = restTimerEndDate
    self.workoutRestOverrideSeconds = workoutRestOverrideSeconds
    self.completedExerciseIDs = completedExerciseIDs
    self.activeExerciseIDsOverride = activeExerciseIDsOverride
    self.activePlanOverrides = activePlanOverrides
    self.activeSupersetGroups = activeSupersetGroups
    self.defaultRestSeconds = defaultRestSeconds
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    exercises = try container.decode([LiftExercise].self, forKey: .exercises)
    routines = try container.decode([LiftRoutine].self, forKey: .routines)
    sessions = try container.decode([LiftSession].self, forKey: .sessions)
    activeSession = try container.decodeIfPresent(LiftSession.self, forKey: .activeSession)
    restTimerEndDate = try container.decodeIfPresent(Date.self, forKey: .restTimerEndDate)
    workoutRestOverrideSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .workoutRestOverrideSeconds)
    completedExerciseIDs = try container.decodeIfPresent(Set<UUID>.self, forKey: .completedExerciseIDs) ?? []
    activeExerciseIDsOverride = try container.decodeIfPresent([UUID].self, forKey: .activeExerciseIDsOverride)
    activePlanOverrides = try container.decodeIfPresent([UUID: LiftRoutineExercisePlan].self, forKey: .activePlanOverrides) ?? [:]
    activeSupersetGroups = try container.decodeIfPresent([UUID: Int].self, forKey: .activeSupersetGroups) ?? [:]
    defaultRestSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .defaultRestSeconds) ?? 90
  }
}

enum LiftPersistenceLoadResult: Sendable {
  case fresh
  case loaded(LiftDataEnvelope)
  case migrated(LiftDataEnvelope)
}

private struct LiftSchemaVersionProbe: Decodable {
  let schemaVersion: Int
}

enum LiftPersistenceError: Error, LocalizedError, Sendable {
  case invalidData
  case unsupportedSchema(Int)
  case backupCreationFailed

  var errorDescription: String? {
    switch self {
    case .invalidData:
      "The Lift data file is not valid version 2 or legacy data."
    case let .unsupportedSchema(version):
      "Unsupported schema version \(version)."
    case .backupCreationFailed:
      "The legacy backup could not be created."
    }
  }
}

/// SAFETY: The queue writes `error` before signaling; the waiting caller reads it only after the
/// semaphore establishes the happens-before relationship.
private final class LiftSynchronousWriteResult: @unchecked Sendable {
  var error: Error?
}

/// SAFETY: All mutable diagnostics and every file operation are confined to `queue`.
/// `dataURL` and `backupURL` are immutable. Remove `@unchecked Sendable` when the deployment
/// baseline provides a checked synchronous primitive or the store flush API becomes async.
final class LiftPersistenceIO: @unchecked Sendable {
  let dataURL: URL
  let backupURL: URL

  private let queue = DispatchQueue(label: "com.eastonplace.lift.persistence", qos: .userInitiated)
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  private var writeCountStorage = 0
  private var lastCodingWasOnMainThreadStorage: Bool?
  private var newestScheduledGeneration = 0
  private var committedGeneration = 0
  private var commitWaiters: [(generation: Int, continuation: CheckedContinuation<Void, Never>)] = []

  init(dataURL: URL) {
    self.dataURL = dataURL
    backupURL = dataURL.deletingLastPathComponent().appendingPathComponent("lift-data.v1.backup.json")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    self.encoder = encoder
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    self.decoder = decoder
  }

  func load() async throws -> LiftPersistenceLoadResult {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        continuation.resume(with: Result { try loadLocked() })
      }
    }
  }

  func scheduleWrite(
    _ envelope: LiftDataEnvelope,
    generation: Int,
    delay: TimeInterval,
    completion: @escaping @Sendable (String?) -> Void
  ) {
    queue.async { [self] in
      newestScheduledGeneration = max(newestScheduledGeneration, generation)
      let deadline = DispatchTime.now() + max(delay, 0)
      queue.asyncAfter(deadline: deadline) { [self] in
        guard generation == newestScheduledGeneration else { return }
        completeWrite(envelope, generation: generation, completion: completion)
      }
    }
  }

  func writeSynchronously(_ envelope: LiftDataEnvelope, generation: Int) throws {
    let semaphore = DispatchSemaphore(value: 0)
    let result = LiftSynchronousWriteResult()
    queue.async { [self] in
      newestScheduledGeneration = max(newestScheduledGeneration, generation)
      do {
        try writeLocked(envelope)
      } catch {
        result.error = error
      }
      markCommitted(generation)
      semaphore.signal()
    }
    semaphore.wait()
    if let error = result.error { throw error }
  }

  func waitUntilCommitted(_ generation: Int) async {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        guard committedGeneration < generation else {
          continuation.resume()
          return
        }
        commitWaiters.append((generation, continuation))
      }
    }
  }

  func waitForScheduledWrites() async {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        let generation = newestScheduledGeneration
        guard committedGeneration < generation else {
          continuation.resume()
          return
        }
        commitWaiters.append((generation, continuation))
      }
    }
  }

  var writeCount: Int {
    queue.sync { writeCountStorage }
  }

  var lastCodingWasOnMainThread: Bool? {
    queue.sync { lastCodingWasOnMainThreadStorage }
  }

  private func loadLocked() throws -> LiftPersistenceLoadResult {
    guard FileManager.default.fileExists(atPath: dataURL.path) else {
      return .fresh
    }

    let data = try Data(contentsOf: dataURL)
    lastCodingWasOnMainThreadStorage = Thread.isMainThread

    if let probe = try? decoder.decode(LiftSchemaVersionProbe.self, from: data),
       probe.schemaVersion != LiftDataEnvelope.currentSchemaVersion {
      throw LiftPersistenceError.unsupportedSchema(probe.schemaVersion)
    }

    if let envelope = try? decoder.decode(LiftDataEnvelope.self, from: data) {
      return .loaded(envelope)
    }

    guard let legacy = try? decoder.decode(LiftLegacyData.self, from: data) else {
      throw LiftPersistenceError.invalidData
    }

    let oldStarterNames: Set<String> = ["Push Day", "Pull Day", "Leg Day"]
    let envelope = LiftDataEnvelope(
      schemaVersion: LiftDataEnvelope.currentSchemaVersion,
      starterBankVersion: LiftDataEnvelope.currentStarterBankVersion,
      userExercises: legacy.exercises.filter { !LiftExerciseCatalog.catalogExerciseIDs.contains($0.id) },
      routines: legacy.routines.filter { !oldStarterNames.contains($0.name) },
      scheduledWorkouts: [],
      sessions: legacy.sessions,
      activeSession: legacy.activeSession,
      restTimerEndDate: legacy.restTimerEndDate,
      workoutRestOverrideSeconds: legacy.workoutRestOverrideSeconds,
      completedExerciseIDs: legacy.completedExerciseIDs,
      activeExerciseIDsOverride: legacy.activeExerciseIDsOverride,
      activePlanOverrides: legacy.activePlanOverrides,
      activeSupersetGroups: legacy.activeSupersetGroups,
      settings: LiftSettings(defaultRestSeconds: legacy.defaultRestSeconds)
    )

    try createBackupIfNeeded(data)
    try writeLocked(envelope)
    return .migrated(envelope)
  }

  private func createBackupIfNeeded(_ data: Data) throws {
    guard !FileManager.default.fileExists(atPath: backupURL.path) else { return }
    try FileManager.default.createDirectory(
      at: backupURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    guard FileManager.default.createFile(atPath: backupURL.path, contents: data) else {
      throw LiftPersistenceError.backupCreationFailed
    }
  }

  private func writeLocked(_ envelope: LiftDataEnvelope) throws {
    lastCodingWasOnMainThreadStorage = Thread.isMainThread
    try FileManager.default.createDirectory(
      at: dataURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let data = try encoder.encode(envelope)
    try data.write(to: dataURL, options: [.atomic])
    writeCountStorage += 1
  }

  private func completeWrite(
    _ envelope: LiftDataEnvelope,
    generation: Int,
    completion: @escaping @Sendable (String?) -> Void
  ) {
    do {
      try writeLocked(envelope)
      markCommitted(generation)
      completion(nil)
    } catch {
      markCommitted(generation)
      completion(error.localizedDescription)
    }
  }

  private func markCommitted(_ generation: Int) {
    committedGeneration = max(committedGeneration, generation)
    let ready = commitWaiters.filter { $0.generation <= committedGeneration }
    commitWaiters.removeAll { $0.generation <= committedGeneration }
    ready.forEach { $0.continuation.resume() }
  }

}
