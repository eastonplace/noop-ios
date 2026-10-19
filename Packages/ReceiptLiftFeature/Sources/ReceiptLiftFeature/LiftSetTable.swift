import Foundation

/// One row of the live set table: a logged set, the draft (the row that is the editor) or a planned set still to come.
struct LiftSetTableRow: Identifiable, Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case logged(LiftSet)
    case draft
    case planned
  }

  let id: String
  /// "W" for a warm-up, otherwise the working set's number.
  let label: String
  let isWarmup: Bool
  /// The same set last time, for the PREVIOUS column.
  let previous: LiftSet?
  let kind: Kind
}

enum LiftSetTable {
  /// `logged` is this exercise's sets in the live session, in the order they were logged; `previousSession` is the
  /// same exercise's sets in the most recent finished lift. `plannedAhead` is how many greyed rows follow the draft.
  nonisolated static func rows(
    logged: [LiftSet],
    previousSession: [LiftSet],
    target: Int?,
    draftIsWarmup: Bool,
    plannedAhead: Int = 1
  ) -> [LiftSetTableRow] {
    let previousWarmups = previousSession.filter(\.isWarmup)
    let previousWorking = previousSession.filter { !$0.isWarmup }
    var rows: [LiftSetTableRow] = []
    var warmupCount = 0
    var workingCount = 0
    for set in logged {
      if set.isWarmup {
        warmupCount += 1
        rows.append(LiftSetTableRow(
          id: set.id.uuidString, label: "W", isWarmup: true,
          previous: previousWarmups.indices.contains(warmupCount - 1) ? previousWarmups[warmupCount - 1] : nil,
          kind: .logged(set)))
      } else {
        workingCount += 1
        rows.append(LiftSetTableRow(
          id: set.id.uuidString, label: String(workingCount), isWarmup: false,
          previous: previousWorking.indices.contains(workingCount - 1) ? previousWorking[workingCount - 1] : nil,
          kind: .logged(set)))
      }
    }
    let draftNumber = draftIsWarmup ? warmupCount + 1 : workingCount + 1
    let draftPrevious = draftIsWarmup ? previousWarmups : previousWorking
    rows.append(LiftSetTableRow(
      id: "draft", label: draftIsWarmup ? "W" : String(draftNumber), isWarmup: draftIsWarmup,
      previous: draftPrevious.indices.contains(draftNumber - 1) ? draftPrevious[draftNumber - 1] : nil, kind: .draft))
    if !draftIsWarmup, let target {
      var next = draftNumber + 1
      var added = 0
      while next <= target, added < plannedAhead {
        rows.append(LiftSetTableRow(
          id: "planned-\(next)", label: String(next), isWarmup: false,
          previous: previousWorking.indices.contains(next - 1) ? previousWorking[next - 1] : nil, kind: .planned))
        next += 1
        added += 1
      }
    }
    return rows
  }

  /// The best one-rep-max estimate among the working sets logged today, and whether it beats everything before today.
  nonisolated static func bestEstimate(logged: [LiftSet], previousBest: Double) -> (value: Double, isNewBest: Bool)? {
    let best = logged.filter { !$0.isWarmup }.map(\.estimatedOneRepMax).max() ?? 0
    guard best > 0 else { return nil }
    return (best, previousBest > 0 && best > previousBest)
  }
}

enum LiftExerciseSubtitle {
  /// "Barbell · chest, with triceps and shoulders": the equipment, the main muscle and up to two that help.
  static func make(_ exercise: LiftExercise) -> String {
    let metadata = LiftExerciseCatalog.metadata(for: exercise)
    let primaryToken = metadata?.target ?? exercise.muscleGroup
    let primary = muscleWord(primaryToken)
    var seen: Set<String> = [primary]
    var helpers: [String] = []
    for token in metadata?.secondaryMuscles ?? [] {
      let word = muscleWord(token)
      guard !word.isEmpty, seen.insert(word).inserted else { continue }
      helpers.append(word)
      if helpers.count == 2 { break }
    }
    var muscles = primary
    if !helpers.isEmpty {
      let list = helpers.formatted(.list(type: .and, width: .standard))
      muscles = primary.isEmpty ? list : String(localized: "\(primary), with \(list)")
    }
    return [equipmentWord(exercise.equipment), muscles].filter { !$0.isEmpty }.joined(separator: " · ")
  }

  static func equipmentWord(_ equipment: String) -> String {
    let lowered = equipment.lowercased().trimmingCharacters(in: .whitespaces)
    guard !lowered.isEmpty else { return "" }
    if lowered == "body weight" || lowered == "bodyweight" { return String(localized: "Bodyweight") }
    return lowered.prefix(1).uppercased() + lowered.dropFirst()
  }

  private static func muscleWord(_ token: String) -> String {
    let lowered = token.lowercased().trimmingCharacters(in: .whitespaces)
    if let group = LiftMuscleGroup.group(forToken: lowered) { return group.title.lowercased() }
    return lowered
  }
}

/// The most recent finished session's sets of one exercise, for the PREVIOUS column.
enum LiftPreviousSets {
  nonisolated static func lastSession(for exerciseID: UUID, in sessions: [LiftSession]) -> [LiftSet] {
    let candidates = sessions
      .filter { $0.endedAt != nil && $0.sets.contains { $0.exerciseID == exerciseID } }
      .sorted { $0.startedAt > $1.startedAt }
    return candidates.first?.sets.filter { $0.exerciseID == exerciseID }.sorted { $0.completedAt < $1.completedAt } ?? []
  }
}
