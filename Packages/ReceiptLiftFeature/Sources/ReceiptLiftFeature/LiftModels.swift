import Foundation

enum TrainingMode: String, CaseIterable, Codable, Identifiable, Sendable {
  case strength
  case hypertrophy
  case endurance

  var id: String { rawValue }

  var title: String {
    switch self {
    case .strength: String(localized: "Strength")
    case .hypertrophy: String(localized: "Hypertrophy")
    case .endurance: String(localized: "Endurance")
    }
  }

  var target: String {
    switch self {
    case .strength: "3-6 reps"
    case .hypertrophy: "8-12 reps"
    case .endurance: "12-20 reps"
    }
  }
}

struct LiftExercise: Identifiable, Codable, Equatable, Hashable, Sendable {
  var id: UUID
  var name: String
  var muscleGroup: String
  var equipment: String
  var instructions: String
}

struct LiftRoutine: Identifiable, Codable, Equatable, Hashable, Sendable {
  var id: UUID
  var name: String
  var notes: String
  var trainingMode: TrainingMode
  var exerciseIDs: [UUID]
  var exercisePlans: [LiftRoutineExercisePlan]? = nil
}

struct LiftRoutineExercisePlan: Identifiable, Codable, Equatable, Hashable, Sendable {
  var id: UUID
  var exerciseID: UUID
  var sets: String
  var reps: String
  var rest: String
  var targetEffort: String
  var notes: String
  /// A reviewed load for this session's plan snapshot. Nil is omitted, keeping existing saved plans byte-identical.
  var targetWeightPounds: Double? = nil

  var prescription: String {
    "\(sets)x\(reps)"
  }
}

struct LiftSet: Identifiable, Codable, Equatable, Hashable, Sendable {
  var id: UUID
  var exerciseID: UUID
  var setNumber: Int
  var weight: Double
  var reps: Int
  var rpe: Double
  var isWarmup: Bool
  var completedAt: Date
  var notes: String
  /// True when the person picked an RPE for this set. Nil on sets saved before the RPE cell, which encode exactly as
  /// they always did; the engine still reads `rpe` for every set (8 when untouched), so Strain math is unchanged.
  var effortRated: Bool? = nil

  var volume: Double {
    guard weight.isFinite, weight > 0, reps > 0 else { return 0 }
    let result = weight * Double(reps)
    return result.isFinite ? result : 0
  }

  var estimatedOneRepMax: Double {
    guard weight.isFinite, weight > 0, reps > 0 else { return 0 }
    let result = weight * (1 + Double(reps) / 30)
    return result.isFinite ? result : 0
  }
}

struct LiftSession: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var routineID: UUID?
  var title: String
  var startedAt: Date
  var endedAt: Date?
  var sets: [LiftSet]

  var isActive: Bool {
    endedAt == nil
  }

  var workingSets: [LiftSet] {
    sets.filter { !$0.isWarmup }
  }

  var totalVolume: Double {
    sets.reduce(0) { $0 + $1.volume }
  }

  var bestEstimatedOneRepMax: Double {
    workingSets.map(\.estimatedOneRepMax).max() ?? 0
  }
}

enum ExportPaperStyle: String, Codable, Equatable, Sendable {
  case white
  case cream
}

struct ScheduledWorkout: Identifiable, Codable, Equatable, Hashable, Sendable {
  var id: UUID
  var routineID: UUID
  var plannedAt: Date
  var note: String
  var completedSessionID: UUID?
  /// Nil on legacy/date-only plans. Only a saved time selection authorizes a reminder.
  var notificationTimeExplicit: Bool? = nil
  var notificationRevision: Int? = nil
}

struct LiftSettings: Codable, Equatable, Sendable {
  var defaultRestSeconds: TimeInterval
  var hapticsEnabled: Bool
  var exportPaperStyle: ExportPaperStyle

  init(
    defaultRestSeconds: TimeInterval = 90,
    hapticsEnabled: Bool = true,
    exportPaperStyle: ExportPaperStyle = .white
  ) {
    self.defaultRestSeconds = defaultRestSeconds
    self.hapticsEnabled = hapticsEnabled
    self.exportPaperStyle = exportPaperStyle
  }

  private enum CodingKeys: String, CodingKey {
    case defaultRestSeconds
    case hapticsEnabled
    case exportPaperStyle
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    defaultRestSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .defaultRestSeconds) ?? 90
    hapticsEnabled = try container.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? true
    exportPaperStyle = try container.decodeIfPresent(ExportPaperStyle.self, forKey: .exportPaperStyle) ?? .white
  }
}

struct VolumePoint: Identifiable, Equatable, Sendable {
  var id: Date { date }
  var date: Date
  var volume: Double
  var bestEstimatedOneRepMax: Double
  var bestReps: Int = 0
}

struct LiftSetProgress: Equatable {
  var completed: Int
  var target: Int?

  var current: Int {
    guard let target else { return completed + 1 }
    return min(completed + 1, max(target, 1))
  }

  var label: String {
    guard let target else { return "\(completed)" }
    return "\(min(completed, target))/\(target)"
  }

  var nextLabel: String {
    guard let target else { return "\(completed + 1)" }
    return "\(current)/\(target)"
  }

  var isComplete: Bool {
    guard let target else { return false }
    return completed >= target
  }
}

struct LiftRoutineProgress: Equatable {
  var completedSets: Int
  var targetSets: Int
  var currentExerciseIndex: Int
  var exerciseCount: Int

  var setLabel: String {
    "\(completedSets)/\(targetSets)"
  }

  var moveLabel: String {
    "\(currentExerciseIndex)/\(exerciseCount)"
  }
}

struct LiftWarmupPlan: Equatable {
  var title: String
  var reason: String
  var sets: [LiftWarmupSet]

  var hasSets: Bool {
    !sets.isEmpty
  }
}

struct LiftWarmupSet: Identifiable, Equatable {
  var id: Int { sequence }
  var sequence: Int
  var percent: Double?
  var weight: Double
  var reps: Int
  var note: String
}
