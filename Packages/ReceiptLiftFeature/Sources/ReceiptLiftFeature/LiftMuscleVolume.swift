import Foundation

/// Working sets per muscle group over the calendar week, for the SETS PER MUSCLE card.
enum LiftMuscleGroup: String, CaseIterable, Sendable {
  case chest, back, shoulders, triceps, biceps, quads, hamstrings, glutes, core

  var title: String {
    switch self {
    case .chest: String(localized: "Chest")
    case .back: String(localized: "Back")
    case .shoulders: String(localized: "Shoulders")
    case .triceps: String(localized: "Triceps")
    case .biceps: String(localized: "Biceps")
    case .quads: String(localized: "Quads")
    case .hamstrings: String(localized: "Hamstrings")
    case .glutes: String(localized: "Glutes")
    case .core: String(localized: "Core")
    }
  }

  /// The group a catalog muscle token belongs to; nil for the muscles the card does not chart (calves, forearms...).
  static func group(forToken token: String) -> LiftMuscleGroup? {
    switch token.lowercased().trimmingCharacters(in: .whitespaces) {
    case "pectorals", "chest", "upper chest": .chest
    case "lats", "upper back", "traps", "trapezius", "rhomboids", "back", "latissimus dorsi", "lower back", "spine",
      "levator scapulae": .back
    case "delts", "shoulders", "deltoids", "rear deltoids": .shoulders
    case "triceps": .triceps
    case "biceps", "brachialis": .biceps
    case "quads", "quadriceps": .quads
    case "hamstrings": .hamstrings
    case "glutes": .glutes
    case "abs", "core", "abdominals", "obliques", "lower abs", "serratus anterior": .core
    default: nil
    }
  }
}

struct LiftMuscleVolume: Equatable, Sendable {
  struct Row: Equatable, Sendable, Identifiable {
    let group: LiftMuscleGroup
    let sets: Double
    var id: LiftMuscleGroup { group }
    var displaySets: Int { Int(sets.rounded(.toNearestOrAwayFromZero)) }
    var isInsideBand: Bool { LiftMuscleVolume.band.contains(sets) }
  }

  /// A common growth range, drawn as the shaded band. A guide, never a target.
  static let band: ClosedRange<Double> = 10...20
  /// The bars' track runs 0...24 sets.
  static let trackMaximum = 24.0
  static let directCredit = 1.0
  static let assistingCredit = 0.5

  let rows: [Row]

  /// `muscles` maps an exercise to its primary muscle token and its assisting ones. Warm-ups earn no credit.
  nonisolated static func make(
    sessions: [LiftSession],
    in interval: DateInterval,
    muscles: (UUID) -> (primary: String?, secondary: [String])
  ) -> LiftMuscleVolume {
    var totals: [LiftMuscleGroup: Double] = [:]
    var cache: [UUID: (primary: String?, secondary: [String])] = [:]
    for session in sessions where session.endedAt != nil
      && session.startedAt >= interval.start && session.startedAt < interval.end {
      for set in session.sets where !set.isWarmup {
        let found = cache[set.exerciseID] ?? muscles(set.exerciseID)
        cache[set.exerciseID] = found
        var credited = Set<LiftMuscleGroup>()
        if let primary = found.primary, let group = LiftMuscleGroup.group(forToken: primary) {
          totals[group, default: 0] += directCredit
          credited.insert(group)
        }
        for token in found.secondary {
          guard let group = LiftMuscleGroup.group(forToken: token), !credited.contains(group) else { continue }
          totals[group, default: 0] += assistingCredit
          credited.insert(group)
        }
      }
    }
    return LiftMuscleVolume(rows: LiftMuscleGroup.allCases.map { Row(group: $0, sets: totals[$0] ?? 0) })
  }
}

extension LiftMuscleVolume {
  /// The routine's main muscle groups by direct sets planned, most first, for the "chest, shoulders, triceps" line.
  nonisolated static func topMuscles(
    plans: [(exerciseID: UUID, sets: Int)],
    limit: Int,
    muscles: (UUID) -> (primary: String?, secondary: [String])
  ) -> [LiftMuscleGroup] {
    var totals: [LiftMuscleGroup: Int] = [:]
    var firstSeen: [LiftMuscleGroup: Int] = [:]
    for (index, plan) in plans.enumerated() {
      guard let primary = muscles(plan.exerciseID).primary, let group = LiftMuscleGroup.group(forToken: primary) else { continue }
      totals[group, default: 0] += plan.sets
      if firstSeen[group] == nil { firstSeen[group] = index }
    }
    return totals.keys
      .sorted { lhs, rhs in
        if totals[lhs] != totals[rhs] { return (totals[lhs] ?? 0) > (totals[rhs] ?? 0) }
        return (firstSeen[lhs] ?? 0) < (firstSeen[rhs] ?? 0)
      }
      .prefix(limit).map { $0 }
  }
}
